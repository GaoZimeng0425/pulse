import Foundation

// MARK: - 热力墙色阶与按周聚合(agent-tab/11)

//
// 用户 2026-11-16「日历图可以切换周,切换了以后每一列都是一周,这一周都是同一个
// 颜色,不同用量按周区分颜色,hover 上去是这一周的用量」。热力墙列 = 连续 7 天
// (最新列以今天收尾),按周档把一列 7 天合成一个值、同一色阶。色阶逻辑自视图
// 收进包:按天 / 按周两档同一量化式,今天折算全天等效量的规则也只写一处。

/// 一列(连续 7 天;末列可能不足 7 天)的合计。
public struct AgentWeekTotal: Equatable, Sendable {
    public let firstDay: String
    public let lastDay: String
    public let total: Int
    /// 四桶合计(列内逐天累加;全为回填天 → 全 0)。
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public init(
        firstDay: String,
        lastDay: String,
        total: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0
    ) {
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.total = total
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    /// 四桶明细;列内没有任何分项 → nil,浮层照旧单行。
    public var breakdown: AgentTokenBreakdown? {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens > 0
            ? AgentTokenBreakdown(
                input: inputTokens, output: outputTokens,
                cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens
            )
            : nil
    }
}

public enum AgentHeatScale {
    /// 灰档线:值 ≤ 峰值 8% 归灰档。
    static let grayFloor = 0.08
    /// 今天折算下限(凌晨数据少,防折算虚高)。
    public static let minimumTodayElapsed: TimeInterval = 6 * 3600

    /// 四档量化:0 = 灰档,1…4 = 值/峰值 ×4 向上取整。
    public static func levels(_ values: [Double]) -> [Int] {
        let peak = values.max() ?? 0
        guard peak > 0 else { return values.map { _ in 0 } }
        return values.map { value in
            let normalized = value / peak
            return normalized <= grayFloor ? 0 : min(4, Int(ceil(normalized * 4)))
        }
    }

    public static func levels(_ values: [Int]) -> [Int] {
        levels(values.map(Double.init))
    }

    /// 旧 → 新逐天合计按 7 天一列切块(首列起点 = 首天)。
    public static func weeks(_ days: [AgentDayTotal]) -> [AgentWeekTotal] {
        stride(from: 0, to: days.count, by: 7).map { start in
            let chunk = days[start ..< min(start + 7, days.count)]
            return AgentWeekTotal(
                firstDay: chunk.first?.day ?? "",
                lastDay: chunk.last?.day ?? "",
                total: chunk.reduce(0) { $0 + $1.total },
                inputTokens: chunk.reduce(0) { $0 + $1.inputTokens },
                outputTokens: chunk.reduce(0) { $0 + $1.outputTokens },
                cacheReadTokens: chunk.reduce(0) { $0 + $1.cacheReadTokens },
                cacheWriteTokens: chunk.reduce(0) { $0 + $1.cacheWriteTokens }
            )
        }
    }

    /// 按天色阶。`todayElapsed` = 末天(今天)已过去的秒数;nil = 不折算。
    public static func dayLevels(_ days: [AgentDayTotal], todayElapsed: TimeInterval?) -> [Int] {
        levels(projectedValues(days, todayElapsed: todayElapsed))
    }

    /// 按周色阶(每列一个值):末列里今天那份按时刻折算后再合计。
    public static func weekLevels(_ days: [AgentDayTotal], todayElapsed: TimeInterval?) -> [Int] {
        let values = projectedValues(days, todayElapsed: todayElapsed)
        let sums = stride(from: 0, to: values.count, by: 7).map { start in
            values[start ..< min(start + 7, values.count)].reduce(0, +)
        }
        return levels(sums)
    }

    /// 全天等效量:进行中的今天按已过时间折算成的等效全天用量——只用于和完整天
    /// 比较(日历色阶、今日环比),任何读数都不显示它。不足 `minimumTodayElapsed`
    /// 按下限算(凌晨数据少,防折算虚高);`todayElapsed` 为 nil = 不折算。
    public static func dayEquivalent(ofToday total: Double, todayElapsed: TimeInterval?) -> Double {
        guard let todayElapsed else { return total }
        return total * 86400 / max(todayElapsed, minimumTodayElapsed)
    }

    /// 逐天值;末天(今天)换成全天等效量。
    private static func projectedValues(_ days: [AgentDayTotal], todayElapsed: TimeInterval?) -> [Double] {
        var values = days.map { Double($0.total) }
        if let last = values.indices.last {
            values[last] = dayEquivalent(ofToday: values[last], todayElapsed: todayElapsed)
        }
        return values
    }
}
