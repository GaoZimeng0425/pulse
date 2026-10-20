import Foundation
import PulseCore

// 模块排行·每进程网络数据层(工单 01):每进程网络计数无公有 API,业界做法
// (Stats,MIT)是子进程跑一次 nettop 取每进程累计字节再差分。真机探针钉死
// 输出格式(2026-10-17,-L 1):首行表头 `,bytes_in,bytes_out,`,数据行形如
// `名称.pid,入字节,出字节[,尾随空列]`——名称可含点(有 bundle 前缀的辅助进程),
// pid 取最后一个点之后的段。解析全程容错:空输出 / 缺列 / 非数字 pid /
// 负数字节 / 空段一律跳过该行,不中断不崩。

// MARK: - 薄源协议(子进程边界)

/// Live 源:每趟在专用串行队列上同步跑一次 nettop(调度 tick 是 async,
/// 但子进程等待是阻塞的——排到队列上,不占协作线程池)。超时 5s 看门狗
/// SIGTERM 逼出 EOF,宽限 1s 仍在跑即 SIGKILL(票 A 中6:吞 SIGTERM 的子进程
/// 曾能让队列永久冻结——这是唯一不能自愈的源);失败 / 无输出如实返回
/// nil / 空文本,绝不抛出、绝不崩;收尾方式按状态沿记日志。
/// 命令与时限可注入:测试用 /bin/sh 扮 nettop 验证升级链,不真实起 nettop。
final class LiveNettopCSVSource: NettopCSVSource, @unchecked Sendable {
    static let executablePath = "/usr/bin/nettop"
    /// -P 按进程聚合(行首列 = 名称.pid);-L 1 只取一次采样;-n 不做地址名称
    /// 解析;-k 砍掉用不上的列(stats 同款参数表)。
    static let arguments = [
        "-P", "-L", "1", "-n",
        "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,"
            + "tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch",
    ]
    /// NSUnbufferedIO 让 nettop 立即刷缓冲(不等块缓冲);LC_ALL 锁定英文数字
    /// 格式,解析口径不随用户区域漂移。
    static let extraEnvironment = ["NSUnbufferedIO": "YES", "LC_ALL": "en_US.UTF-8"]
    /// 超时:nettop -L 1 正常亚秒返回;5s 容忍系统高载,超过即 SIGTERM 收尾。
    static let timeout: TimeInterval = 5
    /// SIGTERM 后的宽限:正常进程收到 SIGTERM 毫秒级退出,1s 仍在跑即判定吞信号。
    static let killGrace: TimeInterval = 1

    private let executablePath: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let killGrace: TimeInterval
    private let queue = DispatchQueue(label: "com.gaozimeng.pulse.nettop", qos: .utility)
    /// 状态沿日志:只在专用串行队列上读写(无需另加锁)。
    private var health = NettopHealthLog()

    init(
        executablePath: String = LiveNettopCSVSource.executablePath,
        arguments: [String] = LiveNettopCSVSource.arguments,
        timeout: TimeInterval = LiveNettopCSVSource.timeout,
        killGrace: TimeInterval = LiveNettopCSVSource.killGrace
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeout = timeout
        self.killGrace = killGrace
    }

    func read() async -> String? {
        await run().text
    }

    /// 跑一趟并交付收尾方式(read 的全量版;测试经此观察升级链)。
    func run() async -> NettopRun {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let run = runOnce()
                logTransition(to: run.outcome)
                continuation.resume(returning: run)
            }
        }
    }

    private func logTransition(to outcome: NettopRunOutcome) {
        // @unchecked Sendable 的前提(health 只在专用串行队列上读写),Debug 下可执行检查。
        dispatchPrecondition(condition: .onQueue(queue))
        guard let entry = health.transition(to: outcome) else { return }
        switch entry.level {
        case .info: LogService.info(entry.message, category: "Nettop")
        case .error: LogService.error(entry.message, category: "Nettop")
        }
    }

    /// 单趟子进程执行(专用串行队列上同步跑)。
    private func runOnce() -> NettopRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // 继承环境再覆盖两项:nettop 依赖的框架路径等保持原样。
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in Self.extraEnvironment { environment[key] = value }
        process.environment = environment
        // Pipe 两端不带 CLOEXEC:Process 以 CLOEXEC_DEFAULT 起子进程、run() 后即关
        // 父进程写端,本 App 亦无别处起子进程;将来若别处加 system/popen/fork,
        // 须防其在这几毫秒里继承写端(否则 SIGKILL 了 nettop 也等不到 EOF)。
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // 起不来(路径缺失等):nil = 读失败,消费方保 lastGood。
            return NettopRun(text: nil, outcome: .launchFailed(error.localizedDescription))
        }
        let watchdog = NettopWatchdog(process)
        watchdog.arm(timeout: timeout, killGrace: killGrace)
        // 读端在本(专用串行)队列阻塞到 EOF:管道缓冲有限,必须与子进程
        // 写端并行排空;EOF 由进程退出或看门狗信号逼出。读错误按无输出处理
        // (readToEnd 抛 Swift 错误;旧 readDataToEndOfFile 抛 ObjC 异常接不住)。
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        // waitUntilExit 无超时:子进程先关 stdout 再赖着不走时全靠看门狗兜底——
        // 看门狗不可在 EOF 后取消(代码审查 M3)。
        process.waitUntilExit()
        watchdog.markFinished()
        // 信号收尾的半截输出照常交付:完整行仍是合法累计值,解析器逐行容错。
        // 看门狗没出手时才看退出方式:非零退出 / 被信号终止如实记异常。
        var outcome = watchdog.outcome
        if outcome == .completed,
           process.terminationReason != .exit || process.terminationStatus != 0 {
            outcome = .exitedAbnormally(status: process.terminationStatus)
        }
        return NettopRun(text: String(decoding: data, as: UTF8.self), outcome: outcome)
    }
}

/// 看门狗(票 A 中6):超时 SIGTERM,宽限期后仍在跑即对整个进程组 SIGKILL,
/// 并记下升级到哪一级(先记后发信号:读端在收尾之后读取,必见最终级别)。
/// Process 非 Sendable,但这里只碰 isRunning / terminate / processIdentifier,
/// 读端只碰管道——@unchecked 声明安全。生命周期:定时器闭包强持有看门狗
/// (连同 Process)到最后一级定时器触发,正常收尾时比 runOnce 晚约一个超时
/// 释放,稳态最多多留一个;这份强持有正是 waitUntilExit 的兜底,不可提前取消。
private final class NettopWatchdog: @unchecked Sendable {
    /// SIGKILL 后仍未收尾的观测延迟:不可中断睡眠 / 管道写端被他人持有时,
    /// 读端永久阻塞在已卡住的串行队列上,状态沿日志永远等不到——在全局队列
    /// 上单独记一条(只记日志,不改状态)。
    static let stuckReportDelay: TimeInterval = 2

    private let process: Process
    private let lock = NSLock()
    private var escalation: NettopRunOutcome = .completed
    private var finished = false

    init(_ process: Process) {
        self.process = process
    }

    var outcome: NettopRunOutcome {
        lock.lock()
        defer { lock.unlock() }
        return escalation
    }

    /// 读端收尾(EOF + 进程回收)后调用:之后的卡死观测不再报警。
    func markFinished() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func arm(timeout: TimeInterval, killGrace: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
            guard process.isRunning else { return }
            escalate(to: .terminated)
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) { [self] in
                guard process.isRunning else { return }
                escalate(to: .killed)
                // Process 让子进程自成进程组(pgid == pid):整组 SIGKILL 连继承了管道
                // 写端的孙进程一并收尾;组不存在返回 ESRCH,不误伤。再对 pid 兜底。
                // isRunning 与 kill 之间的窗口极短;pid 被复用需进程号绕满一圈,可忽略。
                let pid = process.processIdentifier
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.stuckReportDelay) { [self] in
                    guard !isFinished else { return }
                    LogService.error(
                        "nettop SIGKILL 后 \(Self.stuckReportDelay)s 仍未收尾,读端可能永久阻塞,网络每进程排行将停更",
                        category: "Nettop"
                    )
                }
            }
        }
    }

    private func escalate(to outcome: NettopRunOutcome) {
        lock.lock()
        defer { lock.unlock() }
        escalation = outcome
    }
}

// MARK: - 网络每进程排行

/// 网络每进程 provider(工单 01,ADR-0004):低频档 5s,仅窗口可见时跑;
/// 子进程成本由门控挡住,读失败交付 lastGood 不白屏。时钟注入:CSV 不带
/// 采样时刻,差分对墙钟的"墙钟"由此来(测试用假时间轴,零真实等待)。
final class ProcessNetworkRateProvider: SensorProvider {
    typealias Reading = [pid_t: ProcessNetworkRates]
    typealias Clock = @Sendable () -> Date

    let cadence: SensorCadence = .every(seconds: 5)

    private let source: any NettopCSVSource
    private let clock: Clock
    private let gate = SensorVisibilityGate()
    private let accumulator = ProcessNetworkRateAccumulator()
    private let slot = SensorLastGoodBox<Reading>()

    var lastGood: Reading? { slot.current }

    init(
        source: any NettopCSVSource = LiveNettopCSVSource(),
        clock: @escaping Clock = { Date() }
    ) {
        self.source = source
        self.clock = clock
    }

    /// 可见性切换(同能耗影响)。
    func setVisible(_ visible: Bool) {
        if gate.setVisible(visible), !visible { accumulator.reset() }
    }

    func snapshot() async -> Reading? {
        guard gate.isVisible else { return nil }
        guard let csv = await source.read() else { return nil }
        let table = NettopCSVParser.parse(csv, takenAt: clock())
        guard let reading = accumulator.record(table) else { return nil }
        slot.store(reading)
        return reading
    }
}
