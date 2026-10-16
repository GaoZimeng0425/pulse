import Foundation
import Darwin

// MARK: - 出生扫描源(评审 S1)

/// 出生扫描源接缝:pid 枚举 + 单个新 pid 的轻量出生信息。
/// 与全量采集(`ProcessSource`)的差别在**量**:它绝不整轮采明细,
/// 只对调用方筛出的新 pid 逐个取出生字段(ppid / 路径 / argv / cwd,
/// 与采集层同一批 Darwin 调用)——每 ~2s 一轮 = 一次 pid 枚举 +
/// 少数几个新 pid 各几次查询,不占采样预算。
/// 单测注入脚本化假源;真实现 `LiveBirthScanSource`。
protocol BirthScanSource: Sendable {
    /// 当前全部 pid(一次 proc_listallpids)。
    func pids() -> [pid_t]
    /// 单个 pid 的出生信息;pid 已消失(枚举与查询之间退出)→ nil。
    func birthInfo(for pid: pid_t) -> LineageRegistry.Entry?
}

/// Darwin 薄适配器:复用采集层(LiveProcessSource)的同一批已验证调用——
/// ppid:sysctl KERN_PROC;路径:proc_pidpath;argv:KERN_PROCARGS2;
/// cwd:PROC_PIDVNODEPATHINFO。只用于新 pid,量级为"每轮一撮"。
struct LiveBirthScanSource: BirthScanSource {
    func pids() -> [pid_t] {
        LiveProcessSource.listPIDs()
    }

    func birthInfo(for pid: pid_t) -> LineageRegistry.Entry? {
        // KERN_PROC 查不到 = 进程已退出(与采集层同口径:静默跳过)。
        guard let kinfo = LiveProcessSource.kernelProcessInfo(pid: pid) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: LiveProcessSource.pathBufferSize)
        var argsBuffer = [CChar](repeating: 0, count: LiveProcessSource.procArgsBufferSize)
        return LineageRegistry.Entry(
            parentPID: kinfo.kp_eproc.e_ppid,
            identity: ProcessIdentity(
                executablePath: LiveProcessSource.executablePath(pid: pid, buffer: &pathBuffer),
                cwd: LiveProcessSource.currentWorkingDirectory(pid: pid),
                argv: ProcArgsParser.argv(of: pid, into: &argsBuffer)
            )
        )
    }
}

// MARK: - 出生扫描 actor

/// 出生扫描 actor(评审 S1,spec"每 2s 扫描新出现的 pid,出生时记录父链快照"):
/// 独立于采样节奏(5s 关 / 1s 开)以固定 ~2s 节奏运行——采样间隙出生又退场的
/// 短命父进程也能留下出生快照,断链归组(重挂 launchd 的 rustc 等)不再丢线索。
/// 登记表经 deliver 推给呈现层,与采样轮的 registeringBirths 兜底在
/// GroupingPipeline 里只补缺地汇合(LineageRegistry.merging)。
///
/// 与 Sampler 同形:时钟与睡眠注入,测试用假时间轴零真实等待;
/// sleep 抛错(典型:任务取消)视为停机信号,循环安静退出。
actor BirthScanner {
    typealias Clock = @Sendable () -> Date
    typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    /// 扫描节奏(spec 出生登记):每 2s 一轮。
    static let scanInterval: TimeInterval = 2

    private let source: any BirthScanSource
    private let interval: TimeInterval
    private let clock: Clock
    private let sleep: Sleeping

    private var registry = LineageRegistry()
    /// 任何一轮 pid 枚举里见过的 pid(含查询失败的):同一 pid 不重复探测。
    private var knownPIDs: Set<pid_t> = []
    private(set) var scanCount = 0
    private(set) var lastScanAt: Date?

    init(
        source: any BirthScanSource = LiveBirthScanSource(),
        interval: TimeInterval = BirthScanner.scanInterval,
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeping = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.source = source
        self.interval = interval
        self.clock = clock
        self.sleep = sleep
    }

    /// 扫描主循环:启动即扫一轮,此后每隔 interval 扫一轮、交付最新登记表,
    /// 直至任务取消或 sleep 抛错。deliver 从 actor 上下文同步调用。
    func run(deliver: @escaping @Sendable (LineageRegistry) -> Void) async {
        while !Task.isCancelled {
            scan()
            deliver(registry)
            do {
                try await sleep(interval)
            } catch {
                return
            }
        }
    }

    /// 单轮扫描:枚举 pid → diff 出新面孔 → 逐个取出生信息登记(幂等,首记为准)。
    private func scan() {
        scanCount += 1
        lastScanAt = clock()
        for pid in Self.newlyAppeared(pids: source.pids(), known: knownPIDs) {
            knownPIDs.insert(pid) // 查询失败的 pid 也不重试:采样轮兜底会补登记
            registry.register(pid: pid, entry: source.birthInfo(for: pid))
        }
    }

    /// 新 pid 判定(纯逻辑,评审 S1 单测直测):pid 列表中不在已知集合内者,
    /// 保持出现顺序、去重。
    nonisolated static func newlyAppeared(pids: [pid_t], known: Set<pid_t>) -> [pid_t] {
        var encountered = Set<pid_t>()
        var appeared: [pid_t] = []
        for pid in pids where !known.contains(pid) && encountered.insert(pid).inserted {
            appeared.append(pid)
        }
        return appeared
    }
}
