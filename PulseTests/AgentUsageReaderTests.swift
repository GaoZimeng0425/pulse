import GRDB
@testable import Pulse
import PulseCore
import XCTest

// MARK: - 每日账本 Live 读取 smoke(agent-tab/02):临时目录假 home,负载最小。

final class AgentUsageReaderTests: XCTestCase {
    /// 临时 home(假 `.zcode` / `.claude` 全在里面的根)。
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: ZCode db

    /// 现代 schema:带 computed_total_tokens 列,读回样本、legacy=false。
    func testZCodeModernSchema() throws {
        let dbPath = home.appendingPathComponent(".zcode/cli/db/db.sqlite").path
        let db = try DatabaseQueue(path: dbPath)
        try db.write { db in
            try db.execute(sql: """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, started_at INTEGER, completed_at INTEGER,
                duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER, computed_total_tokens INTEGER
            )
            """)
            try db.execute(sql: """
            INSERT INTO model_usage VALUES ('u1', 1000, 9000, 5000, 100, 50, 10, 80, 5, 150)
            """)
        }

        let reader = LiveAgentUsageReader(home: home)
        let result = reader.zcodeUsageSamples(sinceStartedAtMs: nil)
        XCTAssertFalse(result.legacySchema)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.samples.first?.id, "u1")
        XCTAssertEqual(result.samples.first?.computedTotalTokens, 150)

        // 增量过滤(WHERE 下推到 SQL)。
        let since = reader.zcodeUsageSamples(sinceStartedAtMs: 5000)
        XCTAssertTrue(since.samples.isEmpty)
    }

    /// legacy schema:无 computed_total_tokens 列 → legacy=true、total 为 nil。
    func testZCodeLegacySchema() throws {
        let dbPath = home.appendingPathComponent(".zcode/cli/db/db.sqlite").path
        let db = try DatabaseQueue(path: dbPath)
        try db.write { db in
            try db.execute(sql: """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, started_at INTEGER, completed_at INTEGER,
                duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER
            )
            """)
            try db.execute(sql: "INSERT INTO model_usage VALUES ('u1', 1000, 9000, 5000, 100, 50, 10, 80, 5)")
        }

        let result = LiveAgentUsageReader(home: home).zcodeUsageSamples(sinceStartedAtMs: nil)
        XCTAssertTrue(result.legacySchema)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertNil(result.samples.first?.computedTotalTokens)
    }

    /// 库缺席 / 表不识别:安静空,不抛。
    func testZCodeAbsentDatabaseReturnsEmpty() {
        let result = LiveAgentUsageReader(home: home).zcodeUsageSamples(sinceStartedAtMs: nil)
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertFalse(result.legacySchema)
    }

    // MARK: Claude jsonl 与 stats-cache

    /// 流式逐行 + mtime 过滤:今天档只喂今天有改动的文件。
    func testClaudeTranscriptsStreamAndFilter() throws {
        try write(
            """
            {"type":"user","timestamp":"2026-11-12T03:00:00.000Z","content":"hi"}
            {"type":"assistant","timestamp":"2026-11-12T03:00:01.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}
            """,
            relativePath: ".claude/projects/-Users-x-pulse/s1.jsonl"
        )
        // 旧文件(mtime 拨回昨天):今天档不喂。
        try write(
            #"{"type":"assistant","timestamp":"2026-11-11T03:00:00.000Z","message":{"id":"m2","usage":{"input_tokens":9,"output_tokens":9}}}"# +
                "\n",
            relativePath: ".claude/projects/-Users-x-pulse/s2.jsonl"
        )
        let oldFile = home.appendingPathComponent(".claude/projects/-Users-x-pulse/s2.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)],
            ofItemAtPath: oldFile.path
        )

        let reader = LiveAgentUsageReader(home: home)

        // 今天档:只有 s1 的两行(user 行也喂——解析过滤是内核职责)。
        var todayLines: [String] = []
        reader.readClaudeTranscripts(modifiedSince: Date()) { todayLines.append($0) }
        XCTAssertEqual(todayLines.count, 2)

        // 全量档:三个文件都喂(尾行无换行也喂)。
        var allLines: [String] = []
        reader.readClaudeTranscripts(modifiedSince: nil) { allLines.append($0) }
        XCTAssertEqual(allLines.count, 3)
    }

    /// stats-cache 原样读回;缺失 nil。
    func testStatsCacheData() throws {
        let reader = LiveAgentUsageReader(home: home)
        XCTAssertNil(reader.claudeStatsCacheData())

        try write(
            #"{"dailyModelTokens":[{"date":"2026-11-04","tokensByModel":{"m":7}}]}"#,
            relativePath: ".claude/stats-cache.json"
        )
        let data = try XCTUnwrap(reader.claudeStatsCacheData())
        XCTAssertEqual(ClaudeStatsCacheParser.dailyTotals(from: data).count, 1)
    }
}
