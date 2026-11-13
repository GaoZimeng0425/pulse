import Foundation

// MARK: - 每日消耗卡窗口派生(agent-tab/05)

//
// 账本行 → 定稿原型的卡数据(纯值,UI 只描不算):数字卡排三卡的
// 今日/窗口合计/日均 + 环比,项目大卡一条的全派生字段。全部只吃现有
// 数据(环比 = 窗口对比、活跃天数 / 请求数 = 项目轨、在跑 = 会话快照)。

/// 数字卡排数据(三卡同规格;随 7/30 档位联动)。
public struct AgentUsageFigures: Equatable, Sendable {
    /// 今天合计。
    public let todayTotal: Int
    /// (今 - 昨) / 昨;昨为 0 → nil(无基准,UI 显「—」)。
    public let todayDelta: Double?
    /// 窗口(N 天,含今天)合计。
    public let windowTotal: Int
    /// (窗口 - 前窗口) / 前窗口;前窗口为 0 → nil。
    public let windowDelta: Double?
    public let windowAverage: Int
    public let windowPeak: Int
    /// 窗口天数(标签「N 天合计」「日均(N 天)」联动用)。
    public let windowDays: Int
}

/// 模型占比一项(「其他」已在此层合并;share 0…1 相对项目窗口总量)。
public struct AgentModelShare: Equatable, Sendable {
    public let name: String
    public let share: Double

    public init(name: String, share: Double) {
        self.name = name
        self.share = share
    }
}

/// 项目大卡一条(原型四层数据全派生)。
public struct AgentProjectSummary: Equatable, Sendable, Identifiable {
    public let project: String
    public let total: Int
    /// 窗口环比;前窗口该项目为 0 → nil(「—」)。
    public let delta: Double?
    /// 占窗口全部项目的份额(0…1)。
    public let share: Double
    /// 窗口内有消耗的天数。
    public let activeDays: Int
    /// 窗口内请求数合计(request_count)。
    public let requests: Int
    /// 模型占比(降序,≤3 项,剩余并「其他」)。
    public let models: [AgentModelShare]
    /// harness = source:claude 份额(0…1;zcode = 1 - claudeShare)。
    public let claudeShare: Double
    /// 会话快照里的在跑数(实时传入,非账本)。
    public let liveSessions: Int
    /// 距最后活跃日的天数(0 = 今天;日粒度账本派不出小时)。
    public let idleDays: Int

    public var id: String {
        project
    }
}

/// 一天的两家合计(折线 / 热力墙共用)。
public struct AgentDayTotal: Equatable, Sendable {
    public let day: String
    public let total: Int

    public init(day: String, total: Int) {
        self.day = day
        self.total = total
    }
}

/// 账本行 → 卡数据(全部纯函数)。
public enum AgentUsageWindow {
    // MARK: 逐天合计

    /// 近 `days` 天(含今天)逐天两家合计,旧 → 新;账本无行的天 = 0(当日无记录,不猜)。
    public static func dayTotals(
        rows: [AgentDailyUsageRow],
        days: Int,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [AgentDayTotal] {
        var byDay: [String: Int] = [:]
        for row in rows where row.totalTokens > 0 {
            byDay[row.day, default: 0] += row.totalTokens
        }
        let today = calendar.startOfDay(for: now)
        return (0 ..< days).reversed().compactMap { ago in
            calendar.date(byAdding: .day, value: -ago, to: today).map { date in
                let key = dayKey(date, calendar: calendar)
                return AgentDayTotal(day: key, total: byDay[key] ?? 0)
            }
        }
    }

    // MARK: 数字卡排

    /// 近 `days` 天(含今天)数字卡数据。
    public static func figures(
        rows: [AgentDailyUsageRow],
        days: Int,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> AgentUsageFigures {
        var byDay: [String: Int] = [:]
        for row in rows where row.totalTokens > 0 {
            byDay[row.day, default: 0] += row.totalTokens
        }

        let today = calendar.startOfDay(for: now)
        func key(daysAgo: Int) -> String? {
            calendar.date(byAdding: .day, value: -daysAgo, to: today)
                .map { dayKey($0, calendar: calendar) }
        }
        func windowTotal(firstDaysAgo: Int) -> Int {
            (firstDaysAgo ..< firstDaysAgo + days).reduce(0) { sum, ago in
                sum + (key(daysAgo: ago).flatMap { byDay[$0] } ?? 0)
            }
        }

        let todayTotal = key(daysAgo: 0).flatMap { byDay[$0] } ?? 0
        let yesterdayTotal = key(daysAgo: 1).flatMap { byDay[$0] } ?? 0
        let windowSum = windowTotal(firstDaysAgo: 0)
        let previousSum = windowTotal(firstDaysAgo: days)

        var peak = 0
        for ago in 0 ..< days {
            peak = max(peak, key(daysAgo: ago).flatMap { byDay[$0] } ?? 0)
        }

        return AgentUsageFigures(
            todayTotal: todayTotal,
            todayDelta: changeRatio(current: todayTotal, previous: yesterdayTotal),
            windowTotal: windowSum,
            windowDelta: changeRatio(current: windowSum, previous: previousSum),
            windowAverage: days > 0 ? windowSum / days : 0,
            windowPeak: peak,
            windowDays: days
        )
    }

    /// (current - previous) / previous;previous ≤ 0 → nil(无基准)。
    public static func changeRatio(current: Int, previous: Int) -> Double? {
        guard previous > 0 else { return nil }
        return Double(current - previous) / Double(previous)
    }

    // MARK: 项目大卡

    /// 近 `days` 天项目大卡数据(按窗口总量降序)。
    public static func projects(
        projectRows: [AgentProjectUsageRow],
        modelRows: [AgentModelUsageRow],
        days: Int,
        calendar: Calendar = .current,
        now: Date = Date(),
        liveCounts: [String: Int] = [:]
    ) -> [AgentProjectSummary] {
        let today = calendar.startOfDay(for: now)
        func keys(firstDaysAgo: Int) -> Set<String> {
            Set(
                (firstDaysAgo ..< firstDaysAgo + days).compactMap { ago in
                    calendar.date(byAdding: .day, value: -ago, to: today)
                        .map { dayKey($0, calendar: calendar) }
                }
            )
        }
        let windowKeys = keys(firstDaysAgo: 0)
        let previousKeys = keys(firstDaysAgo: days)

        struct ProjectAggregate {
            var total = 0
            var requests = 0
            var claudeTotal = 0
            var zcodeTotal = 0
            var activeDays: Set<String> = []
            var lastActiveDaysAgo = Int.max
        }
        var byProject: [String: ProjectAggregate] = [:]
        for row in projectRows
            where windowKeys.contains(row.day) && row.totalTokens > 0 {
            var aggregate = byProject[row.project] ?? ProjectAggregate()
            aggregate.total += row.totalTokens
            aggregate.requests += row.requestCount
            switch row.source {
            case .claude: aggregate.claudeTotal += row.totalTokens
            case .zcode: aggregate.zcodeTotal += row.totalTokens
            }
            aggregate.activeDays.insert(row.day)
            aggregate.lastActiveDaysAgo = min(
                aggregate.lastActiveDaysAgo,
                daysAgo(of: row.day, from: today, calendar: calendar) ?? .max
            )
            byProject[row.project] = aggregate
        }

        var previousTotals: [String: Int] = [:]
        for row in projectRows
            where previousKeys.contains(row.day) && row.totalTokens > 0 {
            previousTotals[row.project, default: 0] += row.totalTokens
        }

        var modelTotals: [String: [String: Int]] = [:]
        for row in modelRows
            where windowKeys.contains(row.day) && row.totalTokens > 0 {
            modelTotals[row.project, default: [:]][row.model, default: 0] += row.totalTokens
        }

        let grandTotal = byProject.values.reduce(0) { $0 + $1.total }
        return byProject
            .map { project, aggregate -> AgentProjectSummary in
                let shares = (modelTotals[project] ?? [:])
                    .map { (name: $0.key, total: $0.value) }
                return AgentProjectSummary(
                    project: project,
                    total: aggregate.total,
                    delta: changeRatio(
                        current: aggregate.total,
                        previous: previousTotals[project] ?? 0
                    ),
                    share: grandTotal > 0 ? Double(aggregate.total) / Double(grandTotal) : 0,
                    activeDays: aggregate.activeDays.count,
                    requests: aggregate.requests,
                    models: topModels(shares),
                    claudeShare: aggregate.total > 0
                        ? Double(aggregate.claudeTotal) / Double(aggregate.total)
                        : 0,
                    liveSessions: liveCounts[project] ?? 0,
                    idleDays: aggregate.lastActiveDaysAgo == .max
                        ? days
                        : aggregate.lastActiveDaysAgo
                )
            }
            .sorted { $0.total > $1.total }
    }

    /// 模型 top3:按量降序,≤3 项原样;>3 项取前二 + 剩余并「其他」
    /// (用户拍板 #9;share 相对项目窗口总量)。
    public static func topModels(_ shares: [(name: String, total: Int)]) -> [AgentModelShare] {
        let sorted = shares.sorted { $0.total > $1.total }
        let grand = sorted.reduce(0) { $0 + $1.total }
        guard grand > 0 else { return [] }

        if sorted.count <= 3 {
            return sorted.map { AgentModelShare(name: $0.name, share: Double($0.total) / Double(grand)) }
        }
        let rest = sorted.dropFirst(2).reduce(0) { $0 + $1.total }
        return [
            sorted[0], sorted[1], (name: "其他", total: rest),
        ].map { AgentModelShare(name: $0.name, share: Double($0.total) / Double(grand)) }
    }

    // MARK: 在跑计数(会话快照 → 项目)

    /// 会话快照 → 项目在跑数(Claude 实例本就按 pid 存活过滤,每实例计 1;
    /// ZCode 会话按活跃 agent 数 > 0 计 1)。项目名与账本同法 worktree 归组。
    public static func liveProjectCounts(
        claudeSessions: [ClaudeAgentSessionStatus],
        zcodeSessions: [ZCodeSessionStatus]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for session in claudeSessions {
            let project = AgentWorkspaceResolution.projectName(fromPath: session.cwd)
                ?? session.projectName
            counts[project, default: 0] += 1
        }
        for session in zcodeSessions where session.activeAgents > 0 {
            let project = session.workspaceRoot.flatMap(AgentWorkspaceResolution.projectName(fromPath:))
                ?? session.workspaceName
            if let project, !project.isEmpty {
                counts[project, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: 显示名

    /// 模型显示名:剥 "claude/" 与 "claude-" 前缀(claude-opus-5-5 → opus-5-5),
    /// 其余原样透传(GLM-5.3 大小写保真)。
    public static func modelDisplayName(_ model: String) -> String {
        var name = model
        if name.hasPrefix("claude/") {
            name.removeFirst("claude/".count)
        }
        if name.hasPrefix("claude-") {
            name.removeFirst("claude-".count)
        }
        return name
    }

    /// 日键(yyyy-MM-dd;毫秒免 DateFormatter,与账本行同格式)。
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 日键 → 距 today 的天数(越今为 0;非同月格式解析失败 → nil)。
    private static func daysAgo(of dayKey: String, from today: Date, calendar: Calendar) -> Int? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day
    }
}
