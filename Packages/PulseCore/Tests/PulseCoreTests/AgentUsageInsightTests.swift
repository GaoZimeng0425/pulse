import GRDB
@testable import PulseCore
import XCTest

// mcp-self-usage/01:自查账本查询层。全合成夹具——账本库用 openInMemory 造行,
// ZCode 库按真实 schema(子集列)建内存表,Claude 行用 parser 可吃的 jsonl 字符串。
// 口径断言要点:互斥五桶(源列含重叠必须扣)、窗口闭区间、会话择取不猜。

final class AgentUsageInsightQueryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 窗口(账本库)

    private func makeLedgerDB() throws -> DatabaseQueue {
        let queue = try HistoryDatabase.openInMemory()
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO agent_daily_model_usage
                (day, source, project, model, input_tokens, output_tokens,
                 cache_read_tokens, cache_write_tokens, reasoning_tokens,
                 total_tokens, request_count, scanned_at)
            VALUES
                ('2026-11-23', 'zcode',  'p', 'glm',   100, 50, 700, 200, 30, 1080, 10, 0),
                ('2026-11-23', 'claude', 'p', 'opus',   40, 20, 300, 100,  0,  460,  4, 0),
                ('2026-11-22', 'zcode',  'p', 'glm',   900, 60, 800, 300, 40, 2100, 90, 0)
            """)
        }
        return queue
    }

    func testWindowUsageTodayAggregatesSources() throws {
        let db = try makeLedgerDB()
        let usage = try db.read {
            try AgentUsageInsightQuery.windowUsage(fromDay: "2026-11-23", throughDay: "2026-11-23", in: $0)
        }
        // 账本行已互斥,直接加:zcode 1080 / claude 460 / 合计 1540;请求 14。
        XCTAssertEqual(usage.buckets.totalTokens, 1540)
        XCTAssertEqual(usage.buckets.requestCount, 14)
        XCTAssertEqual(usage.sources.map(\.name), ["zcode", "claude"])
        XCTAssertEqual(usage.sources.first?.buckets.cacheReadTokens, 700)
    }

    func testWindowUsageWeekIncludesBothDays() throws {
        let db = try makeLedgerDB()
        let usage = try db.read {
            try AgentUsageInsightQuery.windowUsage(fromDay: "2026-11-17", throughDay: "2026-11-23", in: $0)
        }
        XCTAssertEqual(usage.buckets.totalTokens, 3640)
    }

    func testWindowUsageEmptyLedgerIsZeroWindow() throws {
        let db = try HistoryDatabase.openInMemory()
        let usage = try db.read {
            try AgentUsageInsightQuery.windowUsage(fromDay: "2026-11-23", throughDay: "2026-11-23", in: $0)
        }
        XCTAssertEqual(usage, AgentUsageInsightQuery.WindowUsage(buckets: .empty, sources: []))
        XCTAssertEqual(usage.buckets.totalTokens, 0)
    }

    // MARK: - ZCode 会话(用量库)

    /// 按 db.sqlite 真实 schema 的必要子集建内存表。
    private func makeZCodeDB() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                directory TEXT,
                path TEXT
            )
            """)
            try db.execute(sql: """
            CREATE TABLE model_usage (
                id INTEGER PRIMARY KEY,
                session_id TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER,
                reasoning_tokens INTEGER,
                computed_total_tokens INTEGER,
                started_at INTEGER
            )
            """)
            let started = Int64(now.timeIntervalSince1970 * 1000)
            try db.execute(sql: "INSERT INTO session VALUES ('sess_aaaaaaaa', ?, NULL)", arguments: ["/w/pulse"])
            try db.execute(sql: "INSERT INTO session VALUES ('sess_bbbbbbbb', NULL, '/w/pulse')")
            try db.execute(sql: "INSERT INTO session VALUES ('sess_other', ?, NULL)", arguments: ["/w/other"])
            // 含重叠形状:input 100 已含缓存 70+20,output 60 已含推理 30,computed=160=input+output
            try db.execute(
                sql: "INSERT INTO model_usage (session_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, computed_total_tokens, started_at) VALUES (?, 100, 60, 70, 20, 30, 160, ?)",
                arguments: ["sess_aaaaaaaa", started]
            )
            try db.execute(
                sql: "INSERT INTO model_usage (session_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, computed_total_tokens, started_at) VALUES (?, 10, 5, 0, 0, 0, 15, ?)",
                arguments: ["sess_bbbbbbbb", started - 1000]
            )
            // 别的工作区 + 超窗的行都不该进结果
            try db.execute(
                sql: "INSERT INTO model_usage (session_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, computed_total_tokens, started_at) VALUES (?, 999, 0, 0, 0, 0, 999, ?)",
                arguments: ["sess_other", started]
            )
            try db.execute(
                sql: "INSERT INTO model_usage (session_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, computed_total_tokens, started_at) VALUES (?, 999, 0, 0, 0, 0, 999, ?)",
                arguments: ["sess_aaaaaaaa", started - Int64(8 * 86400 * 1000)]
            )
        }
        return queue
    }

    func testZcodeSessionsNormalizesToExclusiveBuckets() throws {
        let db = try makeZCodeDB()
        let sessions = try db.read {
            try AgentUsageInsightQuery.zcodeSessions(
                workspace: "/w/pulse", lookback: 7 * 86400, now: now, in: $0
            )
        }
        XCTAssertEqual(sessions.count, 2)
        let main = sessions.first { $0.sessionID == "aaaaaaaa" }
        XCTAssertNotNil(main)
        // 互斥五桶:净输入 100-90=10,净输出 60-30=30,缓存读 70,缓存写 20,推理 30。
        XCTAssertEqual(main?.buckets.inputTokens, 10)
        XCTAssertEqual(main?.buckets.outputTokens, 30)
        XCTAssertEqual(main?.buckets.cacheReadTokens, 70)
        XCTAssertEqual(main?.buckets.cacheWriteTokens, 20)
        XCTAssertEqual(main?.buckets.reasoningTokens, 30)
        XCTAssertEqual(main?.buckets.totalTokens, 160)
        XCTAssertEqual(main?.buckets.requestCount, 1)
        // path 形态工作区命中 + 无重叠行原样透传(10+5)。
        let viaPath = sessions.first { $0.sessionID == "bbbbbbbb" }
        XCTAssertEqual(viaPath?.buckets.totalTokens, 15)
    }

    // MARK: - Claude 行聚合

    private func claudeLine(id: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","timestamp":"2026-11-23T10:00:00.000Z","cwd":"/w/pulse","message":{"id":"\(id)","model":"opus","usage":{"input_tokens":\(input),"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":\(output)}}}
        """
    }

    func testSumClaudeLinesDedupesByMessageID() {
        let lines = [
            claudeLine(id: "m1", input: 100, output: 10),
            claudeLine(id: "m1", input: 100, output: 10), // resume 复制,不双计
            claudeLine(id: "m2", input: 50, output: 5),
            "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}", // 非样本
        ]
        let sum = AgentUsageInsightQuery.sumClaudeLines(lines)
        XCTAssertEqual(sum.buckets.inputTokens, 150)
        XCTAssertEqual(sum.buckets.outputTokens, 15)
        XCTAssertEqual(sum.buckets.requestCount, 2)
        XCTAssertNotNil(sum.latestAt)
    }

    // MARK: - 会话择取

    func testPickEmptyYieldsNil() {
        let pick = AgentUsageInsightQuery.SessionPick.pick([])
        XCTAssertNil(pick.primary)
        XCTAssertTrue(pick.others.isEmpty)
    }

    func testPickMostRecentPrimaryOthersCapped() {
        // 全不同时间戳:主报 = 最近,其余活跃降序、超上限丢尾(排序确定性)。
        let sessions = (0 ..< 6).map { index in
            AgentUsageInsightQuery.SessionUsage(
                harness: "ZCode",
                sessionID: "s\(index)",
                buckets: .empty,
                lastActiveAt: Date(timeIntervalSince1970: 100 + Double(index))
            )
        }
        let pick = AgentUsageInsightQuery.SessionPick.pick(sessions, othersLimit: 3)
        XCTAssertEqual(pick.primary?.sessionID, "s5")
        XCTAssertEqual(pick.others.map(\.sessionID), ["s4", "s3", "s2"])
    }
}

// MARK: - 归一化边界两形(评审 P3 补:票面点名「computed_total 有无两形」)

final class AgentUsageInsightNormalizationEdgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDB(legacy: Bool) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, path TEXT)")
            var columns = """
            CREATE TABLE model_usage (
                id INTEGER PRIMARY KEY, session_id TEXT,
                input_tokens INTEGER, output_tokens INTEGER,
                cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER,
                reasoning_tokens INTEGER, started_at INTEGER
            """
            if !legacy {
                columns += ", computed_total_tokens INTEGER"
            }
            columns += ")"
            try db.execute(sql: columns)
            let started = Int64(now.timeIntervalSince1970 * 1000)
            try db.execute(sql: "INSERT INTO session VALUES ('sess_edge', '/w', NULL)")
            if legacy {
                // legacy:input 100 含缓存 70+20,output 60 含推理 30 → 无条件减
                try db.execute(
                    sql: "INSERT INTO model_usage (session_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, started_at) VALUES (?, 100, 60, 70, 20, 30, ?)",
                    arguments: ["sess_edge", started]
                )
            } else {
                // 新 schema 但行值为 NULL:形状未知,原样透传(宁少勿错加)
                try db.execute(
                    sql: "INSERT INTO model_usage (session_id, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, computed_total_tokens, started_at) VALUES (?, 100, 60, 70, 20, 30, NULL, ?)",
                    arguments: ["sess_edge", started]
                )
            }
        }
        return queue
    }

    func testLegacySchemaUnconditionallySubtracts() throws {
        let db = try makeDB(legacy: true)
        let sessions = try db.read {
            try AgentUsageInsightQuery.zcodeSessions(workspace: "/w", lookback: 86400, now: now, in: $0)
        }
        XCTAssertEqual(sessions.first?.buckets.inputTokens, 10)
        XCTAssertEqual(sessions.first?.buckets.outputTokens, 30)
    }

    func testNewSchemaNullComputedTotalPassesThrough() throws {
        let db = try makeDB(legacy: false)
        let sessions = try db.read {
            try AgentUsageInsightQuery.zcodeSessions(workspace: "/w", lookback: 86400, now: now, in: $0)
        }
        // 透传:不做重叠扣除,五桶按源列原样入账。
        XCTAssertEqual(sessions.first?.buckets.inputTokens, 100)
        XCTAssertEqual(sessions.first?.buckets.cacheReadTokens, 70)
        XCTAssertEqual(sessions.first?.buckets.totalTokens, 280)
    }
}
