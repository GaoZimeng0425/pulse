import Foundation

// MARK: - 历史窗口对齐(工单 03)

/// 分钟/小时窗口的 epoch 对齐口径:窗口按整秒 epoch 划分(分钟 = ts/60*60,
/// 小时 = ts/3600*3600),与本地时区无关——分钟与小时处处等长;只有按"当地日"
/// 触发的留存清理(随每日首次 rollup)走注入的 Calendar。库中 ts 一律存
/// 整秒 epoch INTEGER,写读两端共用这一份换算。
enum HistoryWindows {
    /// 所在分钟的起点(整秒 epoch 对齐)。
    static func minuteStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: Double(minuteStartSeconds(of: date)))
    }

    /// 所在小时的起点(整秒 epoch 对齐)。
    static func hourStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: Double(hourStartSeconds(of: date)))
    }

    static func minuteStartSeconds(of date: Date) -> Int {
        epochSeconds(of: date) / 60 * 60
    }

    static func hourStartSeconds(of date: Date) -> Int {
        epochSeconds(of: date) / 3600 * 3600
    }

    /// 整秒 epoch(向下取整;1970 年后的年代恒为正)。
    static func epochSeconds(of date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }
}

// MARK: - 分钟卷积(纯逻辑)

/// 单个组一分钟窗的聚合(sample_min 一行):窗口内均值/峰值。
struct GroupMinuteAggregate: Equatable, Sendable {
    let identity: GroupIdentity
    let cpuAverage: Double
    let cpuPeak: Double
    let memoryPeak: UInt64
    /// 窗口内最多时的存活进程数(spec procs 列)。
    let processPeak: Int
}

/// 一分钟窗的完整聚合:组级若干行 + 系统级一行。
struct MinuteAggregate: Equatable, Sendable {
    /// 窗口起点(分钟边界)。
    let minuteStart: Date
    /// 组级聚合,按 stableKey 升序(行序稳定,便于断言与展示)。
    let groups: [GroupMinuteAggregate]
    let systemLoadAverage: Double
    let systemLoadPeak: Double
}

/// 分钟窗卷积器(纯逻辑,工单 03"每 60 秒把环形缓冲卷积进分钟表"的聚合半边):
/// 5s 采样按自身时间戳归入所在分钟;时钟跨入新分钟时,把整个上一分钟折叠成
/// 一条 `MinuteAggregate` 冲刷出去。跨过的空分钟不产出——app 未运行/睡眠
/// = 无行,历史页留空不补零(spec)。
///
/// 5s 原始值只存在于本缓冲(内存),永不落盘(工单 03 验收)。
/// 冲刷时机 = 跨分钟后的首个采样(5s 节奏下分钟行滞后边界 ≤1 采样轮)。
struct MinuteRollupBuffer: Sendable, Equatable {
    /// 单组窗内累计。
    private struct GroupAccumulator: Equatable, Sendable {
        var cpuSum = 0.0
        var cpuPeak = -Double.infinity
        var memoryPeak = UInt64(0)
        var processPeak = 0
        var count = 0
    }

    /// 当前窗的分钟起点;无样本时为 nil。
    private var currentMinuteStart: Date?
    private var groupAccumulators: [GroupIdentity: GroupAccumulator] = [:]
    private var systemLoads: [Double] = []

    /// 采样进窗。跨入新分钟时返回上一分钟的聚合(该分钟有样本才非 nil);
    /// 时间戳早于当前窗(时钟回拨/乱序迟到)时丢弃该样本,不污染已聚合窗口。
    mutating func ingest(
        at now: Date,
        systemLoad: Double,
        groups: [GroupSample]
    ) -> MinuteAggregate? {
        let minute = HistoryWindows.minuteStart(of: now)
        if let current = currentMinuteStart {
            guard minute >= current else { return nil }
            if minute > current {
                let flushed = buildAggregate()
                currentMinuteStart = minute
                groupAccumulators = [:]
                systemLoads = []
                accumulate(systemLoad: systemLoad, groups: groups)
                return flushed
            }
        } else {
            currentMinuteStart = minute
        }
        accumulate(systemLoad: systemLoad, groups: groups)
        return nil
    }

    private mutating func accumulate(systemLoad: Double, groups: [GroupSample]) {
        systemLoads.append(systemLoad)
        var presentByID: [GroupIdentity: GroupSample] = [:]
        for sample in groups {
            presentByID[sample.id] = sample // 同轮重复 id 以最后一条为准(与环形缓冲同口径)
        }
        for (id, sample) in presentByID {
            var accumulator = groupAccumulators[id] ?? GroupAccumulator()
            accumulator.cpuSum += sample.cpuPercent
            accumulator.cpuPeak = max(accumulator.cpuPeak, sample.cpuPercent)
            accumulator.memoryPeak = max(accumulator.memoryPeak, sample.memoryBytes)
            accumulator.processPeak = max(accumulator.processPeak, sample.processCount)
            accumulator.count += 1
            groupAccumulators[id] = accumulator
        }
    }

    private func buildAggregate() -> MinuteAggregate {
        let systemAverage = systemLoads.isEmpty
            ? 0
            : systemLoads.reduce(0.0, +) / Double(systemLoads.count)
        let groups = groupAccumulators
            .map { id, accumulator in
                GroupMinuteAggregate(
                    identity: id,
                    cpuAverage: accumulator.cpuSum / Double(accumulator.count),
                    cpuPeak: accumulator.cpuPeak,
                    memoryPeak: accumulator.memoryPeak,
                    processPeak: accumulator.processPeak
                )
            }
            .sorted { $0.identity < $1.identity } // stableKey 字典序(Comparable 即此序)
        return MinuteAggregate(
            minuteStart: currentMinuteStart ?? .distantPast,
            groups: groups,
            systemLoadAverage: systemAverage,
            systemLoadPeak: systemLoads.max() ?? 0
        )
    }
}

// MARK: - 留存计划(纯逻辑)

/// 留存清理的触发与截止口径(纯逻辑):分钟表留 7 天、小时表留 30 天,
/// 随每日首次 rollup 顺带执行(spec)。截止也按整秒 epoch 比较。
enum HistoryRetention {
    static let minuteLifespan: TimeInterval = 7 * 24 * 3600
    static let hourLifespan: TimeInterval = 30 * 24 * 3600

    /// 今天是否该跑清理:上次清理日不是今天(含从未清理)。
    /// 当地日界用注入的 Calendar(spec"今天/7 天"同口径)。
    static func isDue(lastRunDayStart: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let lastRunDayStart else { return true }
        return !calendar.isDate(lastRunDayStart, inSameDayAs: now)
    }

    /// 分钟表的清理截止:now − 7 天。
    static func minuteCutoff(now: Date) -> Date {
        now.addingTimeInterval(-minuteLifespan)
    }

    /// 小时表的清理截止:now − 30 天。
    static func hourCutoff(now: Date) -> Date {
        now.addingTimeInterval(-hourLifespan)
    }
}
