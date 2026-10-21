import Foundation

/// 采样节奏(GLOSSARY:采样):弹窗关闭 5s(省电)/ 打开 1s(流畅)。
public struct SamplingCadence: Equatable, Sendable {
    /// 相邻两次采样的间隔,秒。
    public let interval: TimeInterval

    /// 弹窗打开:1s。
    public static let popoverOpen = SamplingCadence(interval: 1)
    /// 弹窗关闭:5s。
    public static let popoverClosed = SamplingCadence(interval: 5)

    public static func forPopover(visible: Bool) -> SamplingCadence {
        visible ? .popoverOpen : .popoverClosed
    }

    public init(interval: TimeInterval) {
        self.interval = interval
    }
}

/// 采样累计统计(工单 11:诊断报告取数;resident-cost/01 扩充分阶段账本):Sampler 每轮
/// 推进一次的纯值账本。未采一轮时保持"空"(nil / 0)——报告侧据此如实标"暂无",不伪造数字。
/// 分阶段耗时(resident-cost/01):采样侧阶段由 Sampler 记在本账本上,主线程落地阶段由
/// SystemMonitor 记在它自己的账本上,报告取数时经 `merging` 合一——两侧各在各的执行域,
/// 不跨域加锁。阶段集合覆盖一轮的全部**同步**工作;SwiftUI 属性图 / CA 提交发生在
/// runloop 提交期、不落在任何阶段内,那部分由 `sample` 抓栈与分阶段账核对(票内口径)。
public struct SamplingStats: Equatable, Sendable {
    /// 一轮工作的具名阶段(resident-cost/01)。采样侧四段按执行顺序,主线程落地
    /// 四段以 mainActorLanding 为总、其余三段为其内子项。
    public enum Stage: Hashable, Sendable, CaseIterable {
        /// 采样侧:进程明细采集(逐进程系统调用,身份缓存命中后稳态 3 次/进程)。
        case processSnapshot
        /// 采样侧:每核 tick / 内存构成 / 网络计数三路读取。
        case systemCounters
        /// 采样侧:进程差分 + 系统负载差分 + 网络速率差分。
        case diff
        /// 采样侧:模块排行账本推进(排行门开才记,关着不产生条目)。
        case rankingsLedger
        /// 主线程:apply 整体(状态发布 + 下列三段 + 粘合)。
        case mainActorLanding
        /// 主线程:出生登记并入 → 归组 → 下钻(RoundSpine.advance)。
        case spineAdvance
        /// 主线程:采样历史窗口推进。
        case historyStore
        /// 主线程:功能模块逐个 onRound 派发。
        case featureDispatch
    }

    /// 单阶段累计:总耗时 + 次数,均值相除;次数独立于轮数(排行账本只在门开时记)。
    public struct StageTiming: Equatable, Sendable {
        public let totalDuration: TimeInterval
        public let sampleCount: Int

        public var averageDuration: TimeInterval {
            sampleCount > 0 ? totalDuration / Double(sampleCount) : 0
        }

        public init(totalDuration: TimeInterval = 0, sampleCount: Int = 0) {
            self.totalDuration = totalDuration
            self.sampleCount = sampleCount
        }

        public func merged(duration: TimeInterval) -> StageTiming {
            StageTiming(
                totalDuration: totalDuration + max(0, duration),
                sampleCount: sampleCount + 1
            )
        }
    }

    /// 首轮采样的时刻(运行时长的起点);未采样为 nil。
    public private(set) var startedAt: Date?
    /// 累计采样轮数。
    public private(set) var sampleCount = 0
    /// 全部轮次的采样工作耗时总和(不含等待),均值由此折算。
    public private(set) var totalRoundDuration: TimeInterval = 0
    /// 见过的最大单轮进程数;未采样为 nil(与 0 区分)。
    public private(set) var peakProcessCount: Int?
    /// 分阶段耗时累计(resident-cost/01);空 = 尚无任何阶段记录。
    public private(set) var stageTimings: [Stage: StageTiming] = [:]

    /// 平均一轮采样的耗时(秒);未采样为 nil。
    public var averageRoundDuration: TimeInterval? {
        sampleCount > 0 ? totalRoundDuration / Double(sampleCount) : nil
    }

    /// 登记一轮采样:运行起点只认首轮,峰值取历史最大。
    public mutating func record(startedAt: Date, roundDuration: TimeInterval, processCount: Int) {
        if self.startedAt == nil {
            self.startedAt = startedAt
        }
        sampleCount += 1
        totalRoundDuration += max(0, roundDuration)
        peakProcessCount = max(peakProcessCount ?? 0, processCount)
    }

    /// 登记一个阶段的耗时(时钟由调用方注入,测试可确定性断言)。
    public mutating func record(stage: Stage, duration: TimeInterval) {
        stageTimings[stage] = (stageTimings[stage] ?? StageTiming()).merged(duration: duration)
    }

    /// 合并另一份账本(resident-cost/01:采样侧 + 主线程侧合一,报告取数用):轮数 /
    /// 起点 / 轮耗时 / 峰值以自身(采样侧)为准,阶段表按阶段相加。
    public func merging(_ other: SamplingStats) -> SamplingStats {
        var merged = self
        for (stage, timing) in other.stageTimings {
            let mine = merged.stageTimings[stage] ?? StageTiming()
            merged.stageTimings[stage] = StageTiming(
                totalDuration: mine.totalDuration + timing.totalDuration,
                sampleCount: mine.sampleCount + timing.sampleCount
            )
        }
        return merged
    }

    public init(
        startedAt: Date? = nil,
        totalRoundDuration: TimeInterval = 0,
        peakProcessCount: Int? = nil,
        stageTimings: [Stage: StageTiming] = [:]
    ) {
        self.startedAt = startedAt
        self.totalRoundDuration = totalRoundDuration
        self.peakProcessCount = peakProcessCount
        self.stageTimings = stageTimings
    }
}

/// 采样调度决策(纯逻辑):记录上次采样时刻,按当前节奏回答"距下次采样还要等多久"。
/// 时间全部由调用方注入,单测用合成时间轴;Sampler actor 只负责计时与执行。
public struct SamplingScheduler: Sendable {
    public private(set) var cadence: SamplingCadence = .popoverClosed
    public private(set) var lastSampleAt: Date?

    /// 弹窗可见性变化 → 切换节奏。打开后若已超过新间隔,下一次 delay 即为 0
    /// (弹窗打开就能尽快拿到新数据)。
    public mutating func setPopoverVisible(_ visible: Bool) {
        cadence = SamplingCadence.forPopover(visible: visible)
    }

    /// 登记一次采样完成的时刻,下一轮等待从该时刻重新起算。
    public mutating func recordSample(at date: Date) {
        lastSampleAt = date
    }

    /// 距下次应采样的秒数;0 = 立即(含启动首采、已过期)。
    public func delay(until now: Date) -> TimeInterval {
        guard let lastSampleAt else { return 0 }
        return max(0, lastSampleAt.addingTimeInterval(cadence.interval).timeIntervalSince(now))
    }

    public init(cadence: SamplingCadence = .popoverClosed, lastSampleAt: Date? = nil) {
        self.cadence = cadence
        self.lastSampleAt = lastSampleAt
    }
}

/// 一轮采样的完整产出:快照本身 + 它的差分结果(同 takenAt)+ 系统 CPU 负载。
/// 快照是出生登记与归组(工单 05)的输入,差分是组 CPU% 的来源;
/// 系统负载来自每核 tick 差分(评审 S6,与进程差分不同源——进程累加口径
/// 少计 kernel_task / root 时间,不能做系统总数)。
public struct SamplingUpdate: Sendable {
    public let snapshot: ProcessSnapshot
    public let diff: CPUDiffResult
    /// 系统 CPU 负载,0–100%,每核 tick 口径(CoreTickDiffer)。
    public var systemCPULoad: Double {
        cpu.total
    }

    /// 负载及用户/系统拆分(工单 P0.6-05 总览 CPU 卡)。
    public let cpu: CPULoadBreakdown
    /// 系统内存构成(工单 P0.6-05 总览内存卡);读失败为 nil。
    public let memory: MemoryBreakdown?
    /// 网络心跳轮差分(工单 06):速率 + 记账增量;丢弃轮(首读/重连跳变/
    /// 换口)速率为 0、增量 0 但结果在场。nil = 本轮读缺失(无可用接口 /
    /// sysctl 失败),UI 占位、历史增量为 0,不伪造。
    public let network: NetworkRoundResult?
    /// 模块排行(票 A 高2):两本账本随心跳同轮推进,满窗才出数;排行门关时
    /// 恒为 empty(不推进差分)。
    public let rankings: ProcessRankingRound

    public init(
        snapshot: ProcessSnapshot,
        diff: CPUDiffResult,
        cpu: CPULoadBreakdown,
        memory: MemoryBreakdown? = nil,
        network: NetworkRoundResult? = nil,
        rankings: ProcessRankingRound
    ) {
        self.snapshot = snapshot
        self.diff = diff
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.rankings = rankings
    }
}

/// 采样 actor:以自适应节奏驱动 ProcessSource(进程明细)与 CoreTickSource
/// (每核 tick),产出 CPU 差分与系统负载并交付。
///
/// - 时钟与睡眠可注入:测试用假时间轴确定性跑完整条管线,零真实等待。
/// - 长等待按 `maxSleepSlice` 切片睡眠:节奏切换(弹窗开/关)最多延迟一个
///   切片即被察觉,同时每次醒来只做一次算术,开销可忽略。
/// - sleep 抛错(典型:任务取消)视为停机信号,循环安静退出。
public actor Sampler {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    private let source: any ProcessSource
    private let coreTicks: any CoreTickSource
    private let memoryStats: any MemoryStatsSource
    /// 网络计数源(工单 06,心跳型):每轮一次 sysctl,住采样循环不另起节奏。
    private let networkCounters: any NetworkCountersSource
    /// 心跳中继(票 A 高2):每轮发布快照,磁盘求和回退源按需取表;nil = 无人取。
    private let heartbeatRelay: HeartbeatRusageRelay?
    private let clock: Clock
    private let sleep: Sleeping
    private let maxSleepSlice: TimeInterval

    private var scheduler = SamplingScheduler()
    private var previousSnapshot: ProcessSnapshot?
    private var previousCoreTicks: CoreTickSample?
    /// 网络差分基线(工单 06):无论本轮成败都以本轮计数重立(读缺失保留旧基线
    /// 等下一轮);唤醒清基线走 invalidateDeltas,与进程/tick 同口径。
    private var previousNetworkCounters: NetworkCounters?
    /// 采样累计统计(工单 11:诊断报告取数)。
    private var stats = SamplingStats()
    /// 模块排行两本账本(票 A 高2):吃心跳快照,不另起全进程 rusage 扫描。
    private var rankings = ProcessRankingLedgers()
    /// 排行门控(任一窗口可见):关 = 不推进差分;关的翻转即清账。
    private var rankingsActive = false
    /// 最近生效的门控消息代号:更旧的消息(各走各的 Task,迟到)丢弃。
    private var rankingsGateGeneration: UInt64 = 0

    public init(
        source: any ProcessSource,
        coreTicks: any CoreTickSource,
        memoryStats: any MemoryStatsSource,
        networkCounters: any NetworkCountersSource,
        heartbeatRelay: HeartbeatRusageRelay? = nil,
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeping = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        maxSleepSlice: TimeInterval = 0.5
    ) {
        self.source = source
        self.coreTicks = coreTicks
        self.memoryStats = memoryStats
        self.networkCounters = networkCounters
        self.heartbeatRelay = heartbeatRelay
        self.clock = clock
        self.sleep = sleep
        self.maxSleepSlice = maxSleepSlice
    }

    /// 弹窗可见性变化:切换 5s/1s 采样节奏。
    public func setPopoverVisible(_ visible: Bool) {
        scheduler.setPopoverVisible(visible)
    }

    /// 排行门控(票 A 高2,工单 01 预算口径"任何窗口可见才跑"):开 = 账本随
    /// 心跳推进;翻转为关即清账——重开首轮只记基线,不出横跨隐藏期的巨差。
    /// 同值重复调用是 no-op。`generation` = 发送方单调递增的代号:门控消息各走各的
    /// Task、到达次序不保证,不新于已生效者的消息丢弃(arch-review-2026-10-18/01 L3)。
    public func setRankingsActive(_ active: Bool, generation: UInt64) {
        guard generation > rankingsGateGeneration else { return }
        rankingsGateGeneration = generation
        guard active != rankingsActive else { return }
        rankingsActive = active
        if !active {
            rankings.reset()
        }
    }

    /// 作废差分基线(工单 03,spec 唤醒处理):系统睡眠唤醒后调用——
    /// 唤醒后的第一轮无前值,进程 CPU 差分与每核 tick 系统负载双双退化为 0
    /// (CPUDiffer/CoreTickDiffer 的首采口径),不产生一根横跨睡眠的巨大尖刺;
    /// 网络差分基线同步作废(工单 06):睡眠期累计量一并跳过,首轮丢弃;
    /// 排行账本同轨清账(票 A 高2)。
    /// 挂唤醒通知的接线在 SystemMonitor.start(UI 粘合层)。
    public func invalidateDeltas() {
        previousSnapshot = nil
        previousCoreTicks = nil
        previousNetworkCounters = nil
        rankings.reset()
    }

    /// 采样累计统计(工单 11:诊断报告在复制时按需取一次)。
    public func samplingStats() -> SamplingStats {
        stats
    }

    /// 采样主循环:采样节奏上每到点即采一张快照、差分、连同快照一起交付,
    /// 直至任务取消或 sleep 抛错。deliver 从 actor 上下文同步调用。
    public func run(deliver: @escaping @Sendable (SamplingUpdate) -> Void) async {
        while !Task.isCancelled {
            let wait = scheduler.delay(until: clock())
            if wait <= 0 {
                // 分阶段计时(resident-cost/01):同一段可注入时钟,零真实等待下可测;
                // 三路系统计数与差分按阶段归组,语义与未计时版逐位一致(纯函数间无顺序耦合)。
                let roundStart = clock()
                let snapshotStart = clock()
                let snapshot = source.snapshot()
                let snapshotDuration = clock().timeIntervalSince(snapshotStart)

                let countersStart = clock()
                let ticks = coreTicks.sample()
                let memory = memoryStats.sample()
                // 网络心跳轮(工单 06):每轮一次 sysctl 差分。读缺失(nil)保留
                // 旧基线等下一轮;读到了则以本轮计数重立基线——丢弃轮(首读/
                // 跳变/换口)速率为 0 但基线照常推进,下一轮即可正常差分。
                let networkCounters = networkCounters.sample()
                let countersDuration = clock().timeIntervalSince(countersStart)

                let diffStart = clock()
                let diff = CPUDiffer.diff(previous: previousSnapshot, current: snapshot)
                let cpu = CoreTickDiffer.breakdown(previous: previousCoreTicks, current: ticks)
                let network = networkCounters.map {
                    NetworkRateDiffer.result(previous: previousNetworkCounters, current: $0)
                }
                let diffDuration = clock().timeIntervalSince(diffStart)

                if networkCounters != nil {
                    previousNetworkCounters = networkCounters
                }
                // 模块排行(票 A 高2):同一张快照推进账本(门关不推进),并发布给
                // 心跳中继——全进程 rusage 只在 source.snapshot() 里读这一趟。
                let rankingStart = clock()
                let rankingRound = rankingsActive ? rankings.record(snapshot) : .empty
                let rankingDuration = clock().timeIntervalSince(rankingStart)

                heartbeatRelay?.publish(snapshot)
                previousSnapshot = snapshot
                previousCoreTicks = ticks
                scheduler.recordSample(at: clock())
                // 轮耗时只计采样工作本身(不含节奏等待),时钟可注入(测试内不走秒)。
                stats.record(
                    startedAt: roundStart,
                    roundDuration: clock().timeIntervalSince(roundStart),
                    processCount: snapshot.processes.count
                )
                stats.record(stage: .processSnapshot, duration: snapshotDuration)
                stats.record(stage: .systemCounters, duration: countersDuration)
                stats.record(stage: .diff, duration: diffDuration)
                if rankingsActive {
                    stats.record(stage: .rankingsLedger, duration: rankingDuration)
                }
                deliver(
                    SamplingUpdate(
                        snapshot: snapshot,
                        diff: diff,
                        cpu: cpu,
                        memory: memory,
                        network: network,
                        rankings: rankingRound
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
