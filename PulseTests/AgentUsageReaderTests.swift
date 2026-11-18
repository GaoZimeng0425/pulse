import CryptoKit
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

    /// 建假 db(GRDB 不建父目录,先自建 `.zcode/cli/db/`)。
    private func makeUsageDatabase() throws -> DatabaseQueue {
        let dbURL = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try DatabaseQueue(path: dbURL.path)
    }

    /// 现代 schema:带 computed_total_tokens + model_id 列 + session 表 join,读回
    /// 样本(含 workspace / 模型)、legacy=false。
    func testZCodeModernSchema() throws {
        let db = try makeUsageDatabase()
        try db.write { db in
            try db.execute(sql: """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, session_id TEXT, started_at INTEGER, completed_at INTEGER,
                duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER, computed_total_tokens INTEGER,
                model_id TEXT
            )
            """)
            try db.execute(sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, directory TEXT, path TEXT
            )
            """)
            try db.execute(sql: """
            INSERT INTO session VALUES ('sess_1', '/Users/x/pulse/.worktrees/agent-project', NULL)
            """)
            try db.execute(sql: """
            INSERT INTO model_usage VALUES ('u1', 'sess_1', 1000, 9000, 5000, 100, 50, 10, 80, 5, 150, 'GLM-5.3')
            """)
        }

        let reader = LiveAgentUsageReader(home: home)
        let result = reader.zcodeUsageSamples(sinceStartedAtMs: nil)
        XCTAssertFalse(result.legacySchema)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.samples.first?.id, "u1")
        XCTAssertEqual(result.samples.first?.computedTotalTokens, 150)
        XCTAssertEqual(result.samples.first?.workspacePath, "/Users/x/pulse/.worktrees/agent-project")
        XCTAssertEqual(result.samples.first?.modelId, "GLM-5.3")

        // 增量过滤(WHERE 下推到 SQL)。
        let since = reader.zcodeUsageSamples(sinceStartedAtMs: 5000)
        XCTAssertTrue(since.samples.isEmpty)
    }

    /// 现代 schema 但 model_id 列缺(更老库):SELECT 补 NULL 降级,样本不带模型。
    func testZCodeModernSchemaWithoutModelIDColumn() throws {
        let db = try makeUsageDatabase()
        try db.write { db in
            try db.execute(sql: """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, session_id TEXT, started_at INTEGER, completed_at INTEGER,
                duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER, computed_total_tokens INTEGER
            )
            """)
            try db.execute(sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, directory TEXT, path TEXT
            )
            """)
            try db.execute(sql: """
            INSERT INTO model_usage VALUES ('u1', NULL, 1000, 9000, 5000, 100, 50, 10, 80, 5, 150)
            """)
        }

        let result = LiveAgentUsageReader(home: home).zcodeUsageSamples(sinceStartedAtMs: nil)
        XCTAssertFalse(result.legacySchema)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertNil(result.samples.first?.modelId)
    }

    /// legacy schema:无 computed_total_tokens 列 → legacy=true、total 为 nil。
    func testZCodeLegacySchema() throws {
        let db = try makeUsageDatabase()
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

    /// 现存会话数(agent-tab/06):Claude = slug 目录下 jsonl 文件数(只列名);
    /// ZCode = db 按 workspace 数不同 session_id(NULL workspace 不计)。
    func testAgentSessionCounts() throws {
        try write("{}", relativePath: ".claude/projects/-Users-x-pulse/s1.jsonl")
        try write("{}", relativePath: ".claude/projects/-Users-x-pulse/s2.jsonl")
        // 非 jsonl 伴生文件不计;空目录不产生条目。
        try write("x", relativePath: ".claude/projects/-Users-x-pulse/s1.key")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects/-empty"),
            withIntermediateDirectories: true
        )
        try write("{}", relativePath: ".claude/projects/-Users-x-sage/only.jsonl")

        let db = try makeUsageDatabase()
        try db.write { db in
            try db.execute(sql: """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, session_id TEXT, started_at INTEGER
            )
            """)
            try db.execute(sql: """
            CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, path TEXT)
            """)
            try db.execute(sql: """
            INSERT INTO session VALUES
              ('a', '/Users/x/pulse/.worktrees/t1', NULL),
              ('b', '/Users/x/pulse', NULL),
              ('c', '/Users/x/sage', NULL),
              ('d', NULL, NULL)
            """)
            try db.execute(sql: """
            INSERT INTO model_usage VALUES
              ('u1', 'a', 1000), ('u2', 'a', 2000),
              ('u3', 'b', 3000),
              ('u4', 'c', 4000),
              ('u5', 'd', 5000)
            """)
        }

        let counts = LiveAgentUsageReader(home: home).agentSessionCounts()
        XCTAssertEqual(counts.claude["-Users-x-pulse"], 2)
        XCTAssertEqual(counts.claude["-Users-x-sage"], 1)
        XCTAssertEqual(counts.claude.count, 2)
        XCTAssertEqual(counts.zcode["/Users/x/pulse/.worktrees/t1"], 1)
        XCTAssertEqual(counts.zcode["/Users/x/pulse"], 1)
        XCTAssertEqual(counts.zcode["/Users/x/sage"], 1)
        XCTAssertEqual(counts.zcode.count, 3) // NULL workspace 的会话(d)归不了组
    }

    // MARK: Claude jsonl 与 stats-cache

    /// 库存只列 jsonl 正规文件;key = <slug>/<file>;size/mtime 如实。
    func testClaudeInventory() throws {
        try write(
            "x\ny\n",
            relativePath: ".claude/projects/-Users-x-pulse/s1.jsonl"
        )
        try write("{}", relativePath: ".claude/projects/-Users-x-pulse/s1.key")

        let inventory = LiveAgentUsageReader(home: home).claudeFileInventory()
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory.first?.key, "-Users-x-pulse/s1.jsonl")
        XCTAssertEqual(inventory.first?.sizeBytes, 4)
        XCTAssertNotNil(inventory.first?.modifiedAt)
    }

    /// 增量读全量档:只喂完整行(无换行尾行不喂),offset 停在行边界,
    /// SHA-256 覆盖 [0, offset)。
    func testClaudeIncrementalFullRead() throws {
        let line1 = #"{"type":"user","timestamp":"2026-11-12T03:00:00.000Z","content":"hi"}"#
        let line2 = #"{"type":"assistant","timestamp":"2026-11-12T03:00:01.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"#
        // 尾行无换行:不消费。
        try write(line1 + "\n" + line2, relativePath: ".claude/projects/-Users-x-pulse/s1.jsonl")

        let ref = try XCTUnwrap(LiveAgentUsageReader(home: home).claudeFileInventory().first)
        var lines: [String] = []
        let outcome = LiveAgentUsageReader(home: home).readClaudeFileIncremental(ref, checkpoint: nil) {
            lines.append($0)
        }
        guard case let .advanced(offset, sha) = outcome else {
            return XCTFail("expected advanced, got \(outcome)")
        }
        XCTAssertEqual(lines, [line1])
        XCTAssertEqual(offset, UInt64(line1.utf8.count + 1))
        // SHA 用 CryptoKit 独立复算。
        var hasher = SHA256()
        hasher.update(data: Data((line1 + "\n").utf8))
        XCTAssertEqual(sha, Data(hasher.finalize()))
    }

    /// 续扫:未追加 → unchanged;追加 → 只喂新行,offset/SHA 前进;改写 → rewritten。
    func testClaudeIncrementalResumeAndRewrite() throws {
        let path = ".claude/projects/-Users-x-pulse/s1.jsonl"
        let line1 = #"{"type":"assistant","timestamp":"2026-11-12T03:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"#
        try write(line1 + "\n", relativePath: path)
        let reader = LiveAgentUsageReader(home: home)

        var lines: [String] = []
        let first = try reader.readClaudeFileIncremental(
            XCTUnwrap(reader.claudeFileInventory().first),
            checkpoint: nil
        ) {
            lines.append($0)
        }
        guard case let .advanced(offset, sha) = first else {
            return XCTFail("expected advanced")
        }
        XCTAssertEqual(lines.count, 1)

        // 未追加(同库存引用):unchanged。
        let unchanged = try reader.readClaudeFileIncremental(
            XCTUnwrap(reader.claudeFileInventory().first),
            checkpoint: (offset, sha)
        ) { _ in }
        XCTAssertEqual(unchanged, .unchanged)

        // 追加新行:只喂新行,offset 前进。
        try append(
            line2: #"{"type":"assistant","timestamp":"2026-11-12T03:05:00.000Z","message":{"id":"m2","usage":{"input_tokens":3,"output_tokens":4}}}"#,
            relativePath: path
        )
        var resumed: [String] = []
        let second = try reader.readClaudeFileIncremental(
            XCTUnwrap(reader.claudeFileInventory().first),
            checkpoint: (offset, sha)
        ) {
            resumed.append($0)
        }
        guard case let .advanced(offset2, _) = second else {
            return XCTFail("expected advanced after append")
        }
        XCTAssertEqual(resumed.count, 1)
        XCTAssertTrue(resumed[0].contains("\"m2\""))
        XCTAssertGreaterThan(offset2, offset)

        // 改写前缀(原地重写第一行):rewritten。
        try write(
            #"{"type":"assistant","timestamp":"2026-11-12T03:00:00.000Z","message":{"id":"m0","usage":{"input_tokens":9,"output_tokens":9}}}"# +
                "\n",
            relativePath: path
        )
        let rewritten = try reader.readClaudeFileIncremental(
            XCTUnwrap(reader.claudeFileInventory().first),
            checkpoint: (offset2, sha),
            consume: { _ in }
        )
        XCTAssertEqual(rewritten, .rewritten)

        // 文件变小(< offset):rewritten。
        try write("{}", relativePath: path)
        let shrunk = try reader.readClaudeFileIncremental(
            XCTUnwrap(reader.claudeFileInventory().first),
            checkpoint: (offset2, sha),
            consume: { _ in }
        )
        XCTAssertEqual(shrunk, .rewritten)
    }

    /// 追加一行(保留原内容)。
    private func append(line2: String, relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line2 + "\n").utf8))
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
