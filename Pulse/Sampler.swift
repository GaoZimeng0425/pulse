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
    let systemCPULoad: Double
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
    private let clock: Clock
    private let sleep: Sleeping
    private let maxSleepSlice: TimeInterval

    private var scheduler = SamplingScheduler()
    private var previousSnapshot: ProcessSnapshot?
    private var previousCoreTicks: CoreTickSample?

    init(
        source: any ProcessSource,
        coreTicks: any CoreTickSource = LiveCoreTickSource(),
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeping = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        maxSleepSlice: TimeInterval = 0.5
    ) {
        self.source = source
        self.coreTicks = coreTicks
        self.clock = clock
        self.sleep = sleep
        self.maxSleepSlice = maxSleepSlice
    }

    /// 弹窗可见性变化:切换 5s/1s 采样节奏。
    func setPopoverVisible(_ visible: Bool) {
        scheduler.setPopoverVisible(visible)
    }

    /// 采样主循环:采样节奏上每到点即采一张快照、差分、连同快照一起交付,
    /// 直至任务取消或 sleep 抛错。deliver 从 actor 上下文同步调用。
    func run(deliver: @escaping @Sendable (SamplingUpdate) -> Void) async {
        while !Task.isCancelled {
            let wait = scheduler.delay(until: clock())
            if wait <= 0 {
                let snapshot = source.snapshot()
                let ticks = coreTicks.sample()
                let diff = CPUDiffer.diff(previous: previousSnapshot, current: snapshot)
                let systemLoad = CoreTickDiffer.systemCPULoad(
                    previous: previousCoreTicks,
                    current: ticks
                )
                previousSnapshot = snapshot
                previousCoreTicks = ticks
                scheduler.recordSample(at: clock())
                deliver(
                    SamplingUpdate(
                        snapshot: snapshot,
                        diff: diff,
                        systemCPULoad: systemLoad
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
