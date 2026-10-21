import Darwin
import Foundation

// 出生扫描的纯逻辑:扫描源接缝与扫描 actor。Darwin 适配器 LiveBirthScanSource 在 app target(BirthScanner.swift)。

/// 出生扫描源接缝:pid 枚举 + 单个新 pid 的轻量出生信息。
/// 与全量采集(`ProcessSource`)的差别在**量**:它绝不整轮采明细,
/// 只对调用方筛出的新 pid 逐个取出生字段(ppid / 路径 / argv / cwd,
/// 与采集层同一批 Darwin 调用)——每 ~2s 一轮 = 一次 pid 枚举 +
/// 少数几个新 pid 各几次查询,不占采样预算。
/// 单测注入脚本化假源;真实现 `LiveBirthScanSource`。
public protocol BirthScanSource: Sendable {
    /// 当前全部 pid(一次 proc_listallpids)。
    func pids() -> [pid_t]
    /// 单个 pid 的出生信息;pid 已消失(枚举与查询之间退出)→ nil。
    func birthInfo(for pid: pid_t) -> LineageRegistry.Entry?
}

/// 出生扫描 actor(评审 S1,spec"每 2s 扫描新出现的 pid,出生时记录父链快照"):
/// 独立于采样节奏(5s 关 / 1s 开)以固定 ~2s 节奏运行——采样间隙出生又退场的
/// 短命父进程也能留下出生快照,断链归组(重挂 launchd 的 rustc 等)不再丢线索。
/// 登记表经 deliver 推给呈现层,与采样轮的 registeringBirths 兜底在
/// GroupingPipeline 里只补缺地汇合(LineageRegistry.merging)。
///
/// 与 Sampler 同形:时钟与睡眠注入,测试用假时间轴零真实等待;
/// sleep 抛错(典型:任务取消)视为停机信号,循环安静退出。
public actor BirthScanner {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    /// 扫描节奏(spec 出生登记):每 2s 一轮。
    public static let scanInterval: TimeInterval = 2

    private let source: any BirthScanSource
    private let interval: TimeInterval
    private let clock: Clock
    private let sleep: Sleeping

    /// 上一轮枚举到的 pid(含查询失败的):仍在的 pid 不重复探测;消失后又出现 = 被新
    /// 进程复用,重新探测登记。只记上一轮,不终身累计(arch-review-2026-10-18/04)。
    private var knownPIDs: Set<pid_t> = []
    public private(set) var scanCount = 0
    public private(set) var lastScanAt: Date?

    public init(
        source: any BirthScanSource,
        interval: TimeInterval = BirthScanner.scanInterval,
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeping = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.source = source
        self.interval = interval
        self.clock = clock
        self.sleep = sleep
    }

    /// 扫描主循环:启动即扫一轮,此后每隔 interval 扫一轮、交付**本轮新登记的出生**
    /// (增量;此前交付终身累计表,只增不删,4 天涨到近 10 万条,每轮整表并入——
    /// arch-review-2026-10-18/04),直至任务取消或 sleep 抛错。deliver 从 actor
    /// 上下文同步调用。
    public func run(deliver: @escaping @Sendable (LineageRegistry) -> Void) async {
        while !Task.isCancelled {
            deliver(scan())
            do {
                try await sleep(interval)
            } catch {
                return
            }
        }
    }

    /// 单轮扫描:枚举 pid → diff 出新面孔 → 逐个取出生信息登记,返回本轮新登记。
    /// 查询失败的 pid 也记作已知、不逐轮重试(采样轮兜底会补登记)。
    private func scan() -> LineageRegistry {
        scanCount += 1
        lastScanAt = clock()
        let pids = source.pids()
        var births = LineageRegistry()
        for pid in Self.newlyAppeared(pids: pids, known: knownPIDs) {
            births.register(pid: pid, entry: source.birthInfo(for: pid))
        }
        knownPIDs = Set(pids)
        return births
    }

    /// 新 pid 判定(纯逻辑,评审 S1 单测直测):pid 列表中不在已知集合内者,
    /// 保持出现顺序、去重。
    public nonisolated static func newlyAppeared(pids: [pid_t], known: Set<pid_t>) -> [pid_t] {
        var encountered = Set<pid_t>()
        var appeared: [pid_t] = []
        for pid in pids where !known.contains(pid) && encountered.insert(pid).inserted {
            appeared.append(pid)
        }
        return appeared
    }
}
