import Foundation

/// 采样节奏(GLOSSARY:采样):弹窗关闭 5s(省电)/ 打开 1s(流畅)。
struct SamplingCadence: Equatable, Sendable {
    /// 相邻两次采样的间隔,秒。
    let interval: TimeInterval

    /// 弹窗打开:1s。
    static let popoverOpen = SamplingCadence(interval: 1)
    /// 弹窗关闭:5s。
    static let popoverClosed = SamplingCadence(interval: 5)

    static func forPopover(visible: Bool) -> SamplingCadence {
        visible ? .popoverOpen : .popoverClosed
    }
}

/// 采样累计统计(工单 11:诊断报告取数):Sampler 每轮推进一次的纯值账本。
/// 未采一轮时保持"空"(nil / 0)——报告侧据此如实标"暂无",不伪造数字。
struct SamplingStats: Equatable, Sendable {
    /// 首轮采样的时刻(运行时长的起点);未采样为 nil。
    private(set) var startedAt: Date?
    /// 累计采样轮数。
    private(set) var sampleCount = 0
    /// 全部轮次的采样工作耗时总和(不含等待),均值由此折算。
    private(set) var totalRoundDuration: TimeInterval = 0
    /// 见过的最大单轮进程数;未采样为 nil(与 0 区分)。
    private(set) var peakProcessCount: Int?

    /// 平均一轮采样的耗时(秒);未采样为 nil。
    var averageRoundDuration: TimeInterval? {
        sampleCount > 0 ? totalRoundDuration / Double(sampleCount) : nil
    }

    /// 登记一轮采样:运行起点只认首轮,峰值取历史最大。
    mutating func record(startedAt: Date, roundDuration: TimeInterval, processCount: Int) {
        if self.startedAt == nil {
            self.startedAt = startedAt
        }
        sampleCount += 1
        totalRoundDuration += max(0, roundDuration)
        peakProcessCount = max(peakProcessCount ?? 0, processCount)
    }
}

/// 采样调度决策(纯逻辑):记录上次采样时刻,按当前节奏回答"距下次采样还要等多久"。
/// 时间全部由调用方注入,单测用合成时间轴;Sampler actor 只负责计时与执行。
struct SamplingScheduler: Sendable {
    private(set) var cadence: SamplingCadence = .popoverClosed
    private(set) var lastSampleAt: Date?

    /// 弹窗可见性变化 → 切换节奏。打开后若已超过新间隔,下一次 delay 即为 0
    /// (弹窗打开就能尽快拿到新数据)。
    mutating func setPopoverVisible(_ visible: Bool) {
        cadence = SamplingCadence.forPopover(visible: visible)
    }

    /// 登记一次采样完成的时刻,下一轮等待从该时刻重新起算。
    mutating func recordSample(at date: Date) {
        lastSampleAt = date
    }

    /// 距下次应采样的秒数;0 = 立即(含启动首采、已过期)。
    func delay(until now: Date) -> TimeInterval {
        guard let lastSampleAt else { return 0 }
        return max(0, lastSampleAt.addingTimeInterval(cadence.interval).timeIntervalSince(now))
    }
}

/// 一轮采样的完整产出:快照本身 + 它的差分结果(同 takenAt)+ 系统 CPU 负载。
/// 快照是出生登记与归组(工单 05)的输入,差分是组 CPU% 的来源;
/// 系统负载来自每核 tick 差分(评审 S6,与进程差分不同源——进程累加口径
/// 少计 kernel_task / root 时间,不能做系统总数)。
struct SamplingUpdate: Sendable {
    let snapshot: ProcessSnapshot
    let diff: CPUDiffResult
    /// 系统 CPU 负载,0–100%,每核 tick 口径(CoreTickDiffer)。
    var systemCPULoad: Double { cpu.total }
    /// 负载及用户/系统拆分(工单 P0.6-05 总览 CPU 卡)。
    let cpu: CPULoadBreakdown
    /// 系统内存构成(工单 P0.6-05 总览内存卡);读失败为 nil。
    let memory: MemoryBreakdown?
}

/// 采样 actor:以自适应节奏驱动 ProcessSource(进程明细)与 CoreTickSource
/// (每核 tick),产出 CPU 差分与系统负载并交付。
///
/// - 时钟与睡眠可注入:测试用假时间轴确定性跑完整条管线,零真实等待。
/// - 长等待按 `maxSleepSlice` 切片睡眠:节奏切换(弹窗开/关)最多延迟一个
///   切片即被察觉,同时每次醒来只做一次算术,开销可忽略。
/// - sleep 抛错(典型:任务取消)视为停机信号,循环安静退出。
actor Sampler {
    typealias Clock = @Sendable () -> Date
    typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    private let source: any ProcessSource
    private let coreTicks: any CoreTickSource
    private let memoryStats: any MemoryStatsSource
    private let clock: Clock
    private let sleep: Sleeping
    private let maxSleepSlice: TimeInterval

    private var scheduler = SamplingScheduler()
    private var previousSnapshot: ProcessSnapshot?
    private var previousCoreTicks: CoreTickSample?
    /// 采样累计统计(工单 11:诊断报告取数)。
    private var stats = SamplingStats()

    init(
        source: any ProcessSource,
        coreTicks: any CoreTickSource = LiveCoreTickSource(),
        memoryStats: any MemoryStatsSource = LiveMemoryStatsSource(),
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeping = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        maxSleepSlice: TimeInterval = 0.5
    ) {
        self.source = source
        self.coreTicks = coreTicks
        self.memoryStats = memoryStats
        self.clock = clock
        self.sleep = sleep
        self.maxSleepSlice = maxSleepSlice
    }

    /// 弹窗可见性变化:切换 5s/1s 采样节奏。
    func setPopoverVisible(_ visible: Bool) {
        scheduler.setPopoverVisible(visible)
    }

    /// 作废差分基线(工单 03,spec 唤醒处理):系统睡眠唤醒后调用——
    /// 唤醒后的第一轮无前值,进程 CPU 差分与每核 tick 系统负载双双退化为 0
    /// (CPUDiffer/CoreTickDiffer 的首采口径),不产生一根横跨睡眠的巨大尖刺。
    /// 挂唤醒通知的接线在 SystemMonitor.start(UI 粘合层)。
    func invalidateDeltas() {
        previousSnapshot = nil
        previousCoreTicks = nil
    }

    /// 采样累计统计(工单 11:诊断报告在复制时按需取一次)。
    func samplingStats() -> SamplingStats {
        stats
    }

    /// 采样主循环:采样节奏上每到点即采一张快照、差分、连同快照一起交付,
    /// 直至任务取消或 sleep 抛错。deliver 从 actor 上下文同步调用。
    func run(deliver: @escaping @Sendable (SamplingUpdate) -> Void) async {
        while !Task.isCancelled {
            let wait = scheduler.delay(until: clock())
            if wait <= 0 {
                let roundStart = clock()
                let snapshot = source.snapshot()
                let ticks = coreTicks.sample()
                let diff = CPUDiffer.diff(previous: previousSnapshot, current: snapshot)
                let cpu = CoreTickDiffer.breakdown(previous: previousCoreTicks, current: ticks)
                let memory = memoryStats.sample()
                previousSnapshot = snapshot
                previousCoreTicks = ticks
                scheduler.recordSample(at: clock())
                // 轮耗时只计采样工作本身(不含节奏等待),时钟可注入(测试内不走秒)。
                stats.record(
                    startedAt: roundStart,
                    roundDuration: clock().timeIntervalSince(roundStart),
                    processCount: snapshot.processes.count
                )
                deliver(
                    SamplingUpdate(
                        snapshot: snapshot,
                        diff: diff,
                        cpu: cpu,
                        memory: memory
                    )
                )
            } else {
                do {
                    try await sleep(min(wait, maxSleepSlice))
                } catch {
                    return
                }
            }
        }
    }
}
