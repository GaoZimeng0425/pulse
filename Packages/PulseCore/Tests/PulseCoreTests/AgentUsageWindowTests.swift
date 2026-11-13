@testable import PulseCore
import XCTest

// MARK: - 每日消耗卡窗口派生测试(agent-tab/05;夹具日期一律从 now 动态推导)

final class AgentUsageWindowTests: XCTestCase {
    private let calendar = Calendar.current

    /// 距 now N 天的本地日键(与账本行同格式)。
    private func dayKey(_ daysAgo: Int, from now: Date) -> String {
        let start = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: start)!
        return AgentUsageWindow.dayKey(date, calendar: calendar)
    }

    // MARK: 逐天合计

    func testDayTotalsFillMissingDaysWithZero() {
        let now = Date()
        let rows = [
            AgentDailyUsageRow(day: dayKey(0, from: now), source: .claude, origin: .jsonl, totalTokens: 30),
            AgentDailyUsageRow(day: dayKey(0, from: now), source: .zcode, origin: .db, totalTokens: 10),
            AgentDailyUsageRow(day: dayKey(2, from: now), source: .claude, origin: .jsonl, totalTokens: 50),
        ]
        let totals = AgentUsageWindow.dayTotals(rows: rows, days: 7, calendar: calendar, now: now)
        XCTAssertEqual(totals.count, 7)
        XCTAssertEqual(totals.last?.day, dayKey(0, from: now)) // 旧 → 新,今天殿后
        XCTAssertEqual(totals.last?.total, 40) // 两家同天合计
        XCTAssertEqual(totals[6 - 2].total, 50)
        XCTAssertEqual(totals.filter { $0.total == 0 }.count, 5) // 缺天 0
    }

    // MARK: 数字卡排

    func testFiguresDeltasAndPeak() {
        let now = Date()
        // 窗口 7 天:300,100,50×5 = 650;前窗 7 天:25×7 = 175。
        var rows: [AgentDailyUsageRow] = []
        func add(_ ago: Int, _ total: Int) {
            rows.append(AgentDailyUsageRow(
                day: dayKey(ago, from: now),
                source: .claude,
                origin: .jsonl,
                totalTokens: total
            ))
        }
        add(0, 300)
        add(1, 100)
        for ago in 2 ... 6 {
            add(ago, 50)
        }
        for ago in 7 ... 13 {
            add(ago, 25)
        }

        let figures = AgentUsageWindow.figures(rows: rows, days: 7, calendar: calendar, now: now)
        XCTAssertEqual(figures.todayTotal, 300)
        XCTAssertEqual(figures.todayDelta, 2.0) // (300-100)/100
        XCTAssertEqual(figures.windowTotal, 650)
        XCTAssertEqual(figures.windowDelta ?? 0, Double(650 - 175) / 175, accuracy: 1e-9)
        XCTAssertEqual(figures.windowAverage, 92) // 650/7 整除
        XCTAssertEqual(figures.windowPeak, 300)
        XCTAssertEqual(figures.windowDays, 7)
    }

    /// 昨日 / 前窗无数据:delta nil(无基准,不出 ±∞ 与 0% 假读数)。
    func testFiguresDeltaNilWithoutBaseline() {
        let now = Date()
        let rows = [
            AgentDailyUsageRow(day: dayKey(0, from: now), source: .claude, origin: .jsonl, totalTokens: 300),
        ]
        let figures = AgentUsageWindow.figures(rows: rows, days: 7, calendar: calendar, now: now)
        XCTAssertNil(figures.todayDelta)
        XCTAssertNil(figures.windowDelta)
        XCTAssertEqual(figures.windowPeak, 300)
    }

    // MARK: 项目大卡

    func testProjectsDeriveAllFields() {
        let now = Date()
        let projectRows = [
            AgentProjectUsageRow(
                day: dayKey(0, from: now),
                source: .claude,
                project: "pulse",
                totalTokens: 100,
                requestCount: 10
            ),
            AgentProjectUsageRow(
                day: dayKey(1, from: now),
                source: .zcode,
                project: "pulse",
                totalTokens: 100,
                requestCount: 5
            ),
            AgentProjectUsageRow(
                day: dayKey(0, from: now),
                source: .claude,
                project: "other",
                totalTokens: 50,
                requestCount: 2
            ),
            // 前窗行:不进本窗聚合,但给环比基数。
            AgentProjectUsageRow(
                day: dayKey(8, from: now),
                source: .claude,
                project: "pulse",
                totalTokens: 50,
                requestCount: 1
            ),
        ]
        let modelRows = [
            AgentModelUsageRow(
                day: dayKey(0, from: now),
                source: .claude,
                project: "pulse",
                model: "claude-opus-5-5",
                totalTokens: 60
            ),
            AgentModelUsageRow(
                day: dayKey(1, from: now),
                source: .zcode,
                project: "pulse",
                model: "GLM-5.3",
                totalTokens: 40
            ),
        ]

        let projects = AgentUsageWindow.projects(
            projectRows: projectRows,
            modelRows: modelRows,
            days: 7,
            calendar: calendar,
            now: now,
            liveCounts: ["pulse": 2]
        )
        XCTAssertEqual(projects.map(\.project), ["pulse", "other"]) // 按窗口总量降序

        let pulse = projects[0]
        XCTAssertEqual(pulse.total, 200)
        XCTAssertEqual(pulse.delta ?? 0, 3.0, accuracy: 1e-9) // (200-50)/50
        XCTAssertEqual(pulse.share ?? 0, 0.8, accuracy: 1e-9) // 200/250
        XCTAssertEqual(pulse.activeDays, 2)
        XCTAssertEqual(pulse.requests, 15)
        XCTAssertEqual(pulse.claudeShare, 0.5)
        XCTAssertEqual(pulse.liveSessions, 2)
        XCTAssertEqual(pulse.idleDays, 0) // 今天活跃
        XCTAssertEqual(pulse.models.count, 2)
        XCTAssertEqual(pulse.models.map(\.name), ["claude-opus-5-5", "GLM-5.3"])
        XCTAssertEqual(pulse.models.map(\.share), [0.6, 0.4])

        let other = projects[1]
        XCTAssertNil(other.delta) // 前窗无该项目的行
        XCTAssertEqual(other.liveSessions, 0)
        XCTAssertEqual(other.models.isEmpty, true) // 无模型行(如纯 cache 时代)
    }

    /// 项目最后活跃在 N 天前:idleDays 如实(在跑 > 今天活跃 > 静了 N 天)。
    func testProjectsIdleDays() {
        let now = Date()
        let projectRows = [
            AgentProjectUsageRow(day: dayKey(3, from: now), source: .claude, project: "sage", totalTokens: 10),
        ]
        let projects = AgentUsageWindow.projects(
            projectRows: projectRows,
            modelRows: [],
            days: 7,
            calendar: calendar,
            now: now
        )
        XCTAssertEqual(projects.first?.idleDays, 3)
    }

    // MARK: 模型 top3

    func testTopModelsMergesRestIntoOther() {
        // ≤3 项:原样降序。
        let two = AgentUsageWindow.topModels([(name: "b", total: 30), (name: "a", total: 50)])
        XCTAssertEqual(two.map(\.name), ["a", "b"])
        XCTAssertEqual(two.map(\.share), [0.625, 0.375])

        // >3 项:前二 + 其他(用户拍板 #9)。
        let four = AgentUsageWindow.topModels([
            (name: "a", total: 50), (name: "b", total: 30), (name: "c", total: 15), (name: "d", total: 5),
        ])
        XCTAssertEqual(four.map(\.name), ["a", "b", "其他"])
        XCTAssertEqual(four.map(\.share), [0.5, 0.3, 0.2])

        // 全零:空(不造 0/0)。
        XCTAssertTrue(AgentUsageWindow.topModels([(name: "a", total: 0)]).isEmpty)
    }

    // MARK: 在跑计数(会话快照 → 项目)

    func testLiveProjectCountsFoldWorktreesAndSkipIdleZCode() {
        let claude = ClaudeAgentSessionStatus(
            pid: 101,
            sessionId: "s1",
            projectName: "agent-usage", // basename(退路);cwd 全路径归组优先
            cwd: "/Users/x/pulse/.worktrees/agent-usage",
            status: "busy",
            ageSeconds: 60,
            model: nil,
            contextTokens: nil,
            contextLimit: nil,
            subagentCount: 0
        )
        let activeZCode = ZCodeSessionStatus(
            sessionId: "sess_1",
            workspaceName: "t2",
            activeAgents: 2,
            totalAgents: 3,
            totalTokens: nil,
            updatedAgoSeconds: nil,
            workspaceRoot: "/Users/x/pulse/.worktrees/t2"
        )
        let idleZCode = ZCodeSessionStatus(
            sessionId: "sess_2",
            workspaceName: "pulse",
            activeAgents: 0, // 无活跃 agent:不计在跑
            totalAgents: 1,
            totalTokens: nil,
            updatedAgoSeconds: nil,
            workspaceRoot: "/Users/x/pulse"
        )
        let counts = AgentUsageWindow.liveProjectCounts(
            claudeSessions: [claude],
            zcodeSessions: [activeZCode, idleZCode]
        )
        XCTAssertEqual(counts, ["pulse": 2]) // 两个 worktree 会话都折回主仓名
    }

    // MARK: 模型显示名

    func testModelDisplayNameStripsClaudePrefixes() {
        XCTAssertEqual(AgentUsageWindow.modelDisplayName("claude-opus-5-5"), "opus-5-5")
        XCTAssertEqual(AgentUsageWindow.modelDisplayName("claude/claude-haiku-5-5"), "haiku-5-5")
        XCTAssertEqual(AgentUsageWindow.modelDisplayName("GLM-5.3"), "GLM-5.3")
        XCTAssertEqual(AgentUsageWindow.modelDisplayName("glm-5.2"), "glm-5.2")
    }
}
