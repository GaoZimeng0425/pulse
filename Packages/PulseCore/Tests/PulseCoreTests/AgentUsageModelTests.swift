@testable import PulseCore
import XCTest

// MARK: - 每日 token 账本测试(agent-tab/02;夹具形状取自本机实测 + tokscale zcode.rs)

/// 记录调用参数的假 reader(catalog 断言「今天档只拉今天」用)。
/// 只在单线程测试里使用,夹具可变存储故 @unchecked。
private final class FakeUsageReader: AgentUsageReading, @unchecked Sendable {
    var zcode: [ZCodeUsageSample] = []
    var legacySchema = false
    /// 文件级 mtime(Live 侧同职责:今天档只喂今天有改动的文件)。
    var claudeFiles: [(key: String, modifiedAt: Date, lines: [String])] = []
    var statsCache: Data?

    private(set) var capturedSinceMs: Int64?
    private(set) var capturedModifiedSince: Date?

    func zcodeUsageSamples(sinceStartedAtMs: Int64?) -> (
        samples: [ZCodeUsageSample], legacySchema: Bool
    ) {
        capturedSinceMs = sinceStartedAtMs
        let filtered: [ZCodeUsageSample] = if let since = sinceStartedAtMs {
            zcode.filter { ($0.startedAtMs ?? 0) >= since }
        } else {
            zcode
        }
        return (filtered, legacySchema)
    }

    func readClaudeTranscripts(
        modifiedSince: Date?,
        consume: (_ relativePath: String, _ line: String) -> Void
    ) {
        capturedModifiedSince = modifiedSince
        for file in claudeFiles where modifiedSince == nil || file.modifiedAt >= modifiedSince! {
            for line in file.lines {
                consume(file.key, line)
            }
        }
    }

    func claudeStatsCacheData() -> Data? {
        statsCache
    }
}

/// 本地正午的毫秒时间戳(任何合理时区偏移下都留在同一天;跨午夜不是被测对象)。
private func noonMs(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    let date = Calendar.current.date(from: components)!
    return Int64(date.timeIntervalSince1970 * 1000)
}

/// 本地正午的日键字符串。
private func dayKey(_ year: Int, _ month: Int, _ day: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(noonMs(year, month, day)) / 1000))
}

/// 相对时钟的动态夹具三件(硬编码日期 + 真实 now 的组合午夜后必挂,
/// 2026-11-13 00:05 /tmp check 实案):毫秒纪元、UTC ISO 串、本地日键。
private func nowMs(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000)
}

private func isoUtc(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

private func localDayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}

/// assistant 行夹具(usage 形状 = projects jsonl 实测;cwd / model 可选注入)。
private func claudeLine(
    id: String?,
    timestamp: String = "2026-11-10T12:00:00.000Z",
    input: Int = 100,
    cacheRead: Int = 50,
    cacheWrite: Int = 10,
    output: Int = 200,
    cwd: String? = nil,
    model: String? = nil
) -> String {
    let messageId = id.map { "\"id\":\"\($0)\"," } ?? ""
    let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
    let modelField = model.map { "\"model\":\"\($0)\"," } ?? ""
    return """
    {"type":"assistant","timestamp":"\(timestamp)",\(cwdField)"message":{\(messageId)\(modelField)"role":"assistant","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite),"output_tokens":\(output)}}}
    """
}

final class AgentUsageModelTests: XCTestCase {
    // MARK: ZCode 归一化

    /// 含重叠形状:total == input+output → 减重叠(tokscale 测试数字:
    /// 100/50/80/5/10/total150 → 净 15/40,total 150 不变)。
    func testZCodeNormalizationInclusiveShapeSubtracts() {
        let n = ZCodeTokenNormalization.normalize(
            input: 100, output: 50, cacheRead: 80, cacheWrite: 5,
            reasoning: 10, computedTotal: 150, legacySchema: false
        )
        XCTAssertEqual(n.netInput, 15)
        XCTAssertEqual(n.netOutput, 40)
        XCTAssertEqual(n.cacheRead, 80)
        XCTAssertEqual(n.cacheWrite, 5)
        XCTAssertEqual(n.reasoning, 10)
        XCTAssertEqual(n.total, 150)
    }

    /// 互斥形状:total == 全加和 → 原样保留不减。
    func testZCodeNormalizationExclusiveShapePreserved() {
        let n = ZCodeTokenNormalization.normalize(
            input: 20, output: 30, cacheRead: 80, cacheWrite: 10,
            reasoning: 5, computedTotal: 145, legacySchema: false
        )
        XCTAssertEqual(n.netInput, 20)
        XCTAssertEqual(n.netOutput, 30)
        XCTAssertEqual(n.total, 145)
    }

    /// legacy schema(无 computed_total 列):无条件减重叠。
    func testZCodeNormalizationLegacySubtractsUnconditionally() {
        let n = ZCodeTokenNormalization.normalize(
            input: 100, output: 50, cacheRead: 80, cacheWrite: 5,
            reasoning: 10, computedTotal: nil, legacySchema: true
        )
        XCTAssertEqual(n.netInput, 15)
        XCTAssertEqual(n.netOutput, 40)
        XCTAssertEqual(n.total, 150)
    }

    /// 新 schema 但该行 total 为 NULL:形状未知,透传不猜(宁少勿错加)。
    func testZCodeNormalizationModernNullTotalPassesThrough() {
        let n = ZCodeTokenNormalization.normalize(
            input: 100, output: 50, cacheRead: 80, cacheWrite: 5,
            reasoning: 10, computedTotal: nil, legacySchema: false
        )
        XCTAssertEqual(n.netInput, 100)
        XCTAssertEqual(n.netOutput, 50)
    }

    /// 时间锚:started_at 优先;缺失时 completed - duration 回推;都缺 nil。
    func testZCodeAnchorTimestamp() {
        XCTAssertEqual(
            ZCodeTokenNormalization.anchorTimestampMs(startedAt: 1000, completedAt: 9000, durationMs: 5000),
            1000
        )
        XCTAssertEqual(
            ZCodeTokenNormalization.anchorTimestampMs(startedAt: nil, completedAt: 9000, durationMs: 5000),
            4000
        )
        XCTAssertNil(
            ZCodeTokenNormalization.anchorTimestampMs(startedAt: nil, completedAt: nil, durationMs: 5000)
        )
        // 回推落负:退回 completed_at 本身。
        XCTAssertEqual(
            ZCodeTokenNormalization.anchorTimestampMs(startedAt: nil, completedAt: 3000, durationMs: 5000),
            3000
        )
    }

    // MARK: Claude 行解析

    func testClaudeLineParsesUsage() throws {
        let sample = try XCTUnwrap(ClaudeTranscriptUsageParser.parse(line: claudeLine(id: "msg_1")))
        XCTAssertEqual(sample.messageId, "msg_1")
        XCTAssertEqual(sample.inputTokens, 100)
        XCTAssertEqual(sample.cacheReadTokens, 50)
        XCTAssertEqual(sample.cacheWriteTokens, 10)
        XCTAssertEqual(sample.outputTokens, 200)
        // 2026-11-10T12:00:00.000Z 的毫秒纪元。
        XCTAssertEqual(sample.timestampMs, 1_794_312_000_000)
    }

    /// user 行 / 全零 usage / 缺 timestamp / 非 JSON:安静 nil。
    func testClaudeLineRejectsNonUsage() {
        XCTAssertNil(ClaudeTranscriptUsageParser.parse(
            line: #"{"type":"user","timestamp":"2026-11-10T12:00:00.000Z","message":{"usage":{"input_tokens":1}}}"#
        ))
        XCTAssertNil(ClaudeTranscriptUsageParser.parse(
            line: claudeLine(id: nil, input: 0, cacheRead: 0, cacheWrite: 0, output: 0)
        ))
        XCTAssertNil(ClaudeTranscriptUsageParser.parse(
            line: #"{"type":"assistant","message":{"id":"m","usage":{"input_tokens":5}}}"#
        ))
        XCTAssertNil(ClaudeTranscriptUsageParser.parse(line: "not json"))
    }

    // MARK: stats-cache 解析

    func testStatsCacheDailyTotals() {
        let json = """
        {"lastComputedDate":"2026-11-04","dailyModelTokens":[
          {"date":"2026-11-03","tokensByModel":{"claude-opus-5-5":290,"glm-5.2":10}},
          {"date":"2026-11-04","tokensByModel":{"claude-opus-5-5":94}},
          {"date":"2026-11-05","tokensByModel":{}}
        ]}
        """
        let totals = ClaudeStatsCacheParser.dailyTotals(from: json.data(using: .utf8))
        XCTAssertEqual(totals.map(\.day), ["2026-11-03", "2026-11-04"])
        XCTAssertEqual(totals.map(\.totalTokens), [300, 94])
        // 坏形状安静空。
        XCTAssertTrue(ClaudeStatsCacheParser.dailyTotals(from: Data("[]".utf8)).isEmpty)
        XCTAssertTrue(ClaudeStatsCacheParser.dailyTotals(from: nil).isEmpty)
    }

    // MARK: 聚合器

    /// 样本按天聚合、跨天分开;ZCode 归一化后入桶。
    func testAggregatorSplitsByDayAndNormalizesZCode() {
        var aggregator = AgentDailyAggregator()
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u1", startedAtMs: noonMs(2026, 11, 10),
                inputTokens: 100, outputTokens: 50, reasoningTokens: 10,
                cacheReadTokens: 80, cacheWriteTokens: 5, computedTotalTokens: 150
            ),
            legacySchema: false
        )
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u2", startedAtMs: noonMs(2026, 11, 11),
                inputTokens: 10, outputTokens: 5, reasoningTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, computedTotalTokens: 15
            ),
            legacySchema: false
        )
        let rows = aggregator.rows(scannedAt: Date())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].day, dayKey(2026, 11, 10))
        XCTAssertEqual(rows[0].source, .zcode)
        XCTAssertEqual(rows[0].totalTokens, 150)
        XCTAssertEqual(rows[0].requestCount, 1)
        XCTAssertEqual(rows[1].day, dayKey(2026, 11, 11))
        XCTAssertEqual(rows[1].totalTokens, 15)
    }

    /// stream 多行 / resume 复制到新文件:同 message.id 只计一次(全局
    /// msg id);id 缺失如实计不去重。
    func testAggregatorDedupsByMessageId() throws {
        var aggregator = AgentDailyAggregator()
        func sample(_ line: String) throws -> ClaudeUsageSample {
            try XCTUnwrap(ClaudeTranscriptUsageParser.parse(line: line))
        }
        let line = claudeLine(id: "msg_1")
        try aggregator.addClaude(sample(line))
        try aggregator.addClaude(sample(line))
        try aggregator.addClaude(sample(line))
        // 无 id 行不去重。
        let noId = claudeLine(id: nil)
        try aggregator.addClaude(sample(noId))
        try aggregator.addClaude(sample(noId))

        let rows = aggregator.rows(scannedAt: Date())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].requestCount, 3) // 1 条 msg_1 + 2 条无 id
        XCTAssertEqual(rows[0].totalTokens, 360 + 720)
    }

    /// 时间锚全失败的 ZCode 行、全零样本:跳过不入桶。
    func testAggregatorSkipsUnanchorableRows() {
        var aggregator = AgentDailyAggregator()
        aggregator.addZCode(
            ZCodeUsageSample(id: "u", startedAtMs: nil, completedAtMs: nil, inputTokens: 100, outputTokens: 5),
            legacySchema: false
        )
        XCTAssertTrue(aggregator.isEmpty)
    }

    // MARK: 合并策略

    /// cache 回填只填「非今天且库中无 claude 行」的天。
    func testMergeCacheBackfillRules() {
        let detailed = [
            AgentDailyUsageRow(day: "2026-11-12", source: .claude, origin: .jsonl, totalTokens: 100),
        ]
        let cache = [
            AgentDailyUsageRow(day: "2026-11-12", source: .claude, origin: .cache, totalTokens: 999), // 今天不填
            AgentDailyUsageRow(day: "2026-11-01", source: .claude, origin: .cache, totalTokens: 500), // 已知天不填
            AgentDailyUsageRow(day: "2026-10-20", source: .claude, origin: .cache, totalTokens: 300), // 缺天可填
        ]
        let merged = AgentUsageMerge.merge(
            freshDetailed: detailed,
            cacheBackfill: cache,
            knownClaudeDays: ["2026-11-01", "2026-11-12"],
            today: "2026-11-12"
        )
        XCTAssertEqual(merged.upserts, detailed)
        XCTAssertEqual(merged.insertsIfAbsent.map(\.day), ["2026-10-20"])
    }

    // MARK: 落库 store(真 in-memory SQLite)

    func testStoreUpsertOverwritesAndInsertIfAbsentIgnores() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())

        try store.upsert([
            AgentDailyUsageRow(
                day: "2026-11-10",
                source: .claude,
                origin: .jsonl,
                totalTokens: 100,
                requestCount: 2,
                scannedAt: 1
            ),
        ])
        // 覆盖写:同 (day, source) 换值不追加。
        try store.upsert([
            AgentDailyUsageRow(
                day: "2026-11-10",
                source: .claude,
                origin: .jsonl,
                totalTokens: 260,
                requestCount: 5,
                scannedAt: 2
            ),
        ])
        // insertIfAbsent:冲突忽略,新天照插。
        try store.insertIfAbsent([
            AgentDailyUsageRow(day: "2026-11-10", source: .claude, origin: .cache, totalTokens: 999, scannedAt: 3),
            AgentDailyUsageRow(day: "2026-10-01", source: .claude, origin: .cache, totalTokens: 40, scannedAt: 3),
        ])

        let rows = try store.rows()
        XCTAssertEqual(rows.count, 2)
        let november = rows.first { $0.day == "2026-11-10" }
        XCTAssertEqual(november?.totalTokens, 260)
        XCTAssertEqual(november?.origin, .jsonl)
        XCTAssertEqual(try store.knownClaudeDays(), ["2026-11-10", "2026-10-01"])
        XCTAssertTrue(try store.hasAnyRow())
    }

    // MARK: 编排器

    /// 定时档:节流内跳过;只拉今天(ZCode since = 今天 0 点、Claude 只扫今天
    /// 有改动的文件);结果 upsert 今天行。
    func testRefreshTodayThrottlesAndScopesToToday() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())
        let reader = FakeUsageReader()
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        // 夹具日期相对 now 动态取(硬编码日期 + 真实 now = 午夜后必挂)。
        reader.zcode = [
            ZCodeUsageSample(
                id: "today",
                startedAtMs: nowMs(now),
                inputTokens: 10,
                outputTokens: 5,
                computedTotalTokens: 15
            ),
            ZCodeUsageSample(
                id: "yesterday",
                startedAtMs: nowMs(yesterday),
                inputTokens: 10,
                outputTokens: 5,
                computedTotalTokens: 15
            ),
        ]
        reader.claudeFiles = [
            (key: "s1.jsonl", modifiedAt: now, lines: [claudeLine(id: "m1", timestamp: isoUtc(now))]),
            // 昨天的文件:今天档不喂(文件级 mtime 过滤是 Live 侧职责,fake 同口径)。
            (
                key: "s2.jsonl",
                modifiedAt: yesterday,
                lines: [claudeLine(id: "m2", timestamp: isoUtc(yesterday))]
            ),
        ]
        var catalog = AgentUsageCatalog()

        let first = catalog.refreshToday(reader: reader, store: store, now: now)
        XCTAssertNotNil(first)
        XCTAssertNotNil(reader.capturedSinceMs)
        XCTAssertNotNil(reader.capturedModifiedSince)
        // 只剩今天两行(claude + zcode 各一),昨天的数据定时档不碰。
        XCTAssertEqual(first?.count, 2)
        XCTAssertFalse(first?.contains { $0.day == localDayKey(yesterday) } ?? true)

        // 节流窗内:跳过(nil)。
        XCTAssertNil(catalog.refreshToday(reader: reader, store: store, now: now.addingTimeInterval(60)))
    }

    /// 全量档:三源全拉;cache 只填缺天、不覆盖 jsonl 已有行、不填今天。
    /// 「今天」相对 now 动态取(硬编码日期 + 真实 now = 午夜后必挂)。
    func testFullRescanBackfillsCacheGaps() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())
        // 库里已有 11-01 的 jsonl 行(模拟此前扫过)。
        try store.upsert([
            AgentDailyUsageRow(day: "2026-11-01", source: .claude, origin: .jsonl, totalTokens: 100),
        ])

        let now = Date()
        let today = localDayKey(now)
        let reader = FakeUsageReader()
        reader.zcode = [
            ZCodeUsageSample(
                id: "u1",
                startedAtMs: nowMs(now),
                inputTokens: 100,
                outputTokens: 50,
                computedTotalTokens: 150
            ),
        ]
        reader.claudeFiles = [
            (key: "s1.jsonl", modifiedAt: now, lines: [claudeLine(id: "m1", timestamp: isoUtc(now))]),
        ]
        reader.statsCache = """
        {"dailyModelTokens":[
          {"date":"2026-11-01","tokensByModel":{"m":500}},
          {"date":"2026-11-04","tokensByModel":{"m":700}},
          {"date":"\(today)","tokensByModel":{"m":999}}
        ]}
        """.data(using: .utf8)

        var catalog = AgentUsageCatalog()
        let rows = catalog.fullRescan(reader: reader, store: store, now: now)

        // 11-01 仍是 jsonl 100(cache 500 不覆盖);11-04 补 cache 700;
        // 今天 cache 不填(999 不出现;今天只有 jsonl/zcode 实扫行)。
        XCTAssertEqual(rows.first { $0.day == "2026-11-01" }?.origin, .jsonl)
        XCTAssertEqual(rows.first { $0.day == "2026-11-01" }?.totalTokens, 100)
        XCTAssertEqual(rows.first { $0.day == "2026-11-04" }?.origin, .cache)
        XCTAssertEqual(rows.first { $0.day == "2026-11-04" }?.totalTokens, 700)
        XCTAssertFalse(rows.contains { $0.day == today && $0.origin == .cache })
        XCTAssertEqual(rows.first { $0.day == today && $0.source == .zcode }?.totalTokens, 150)
    }

    // MARK: 工作区归组与项目轨(agent-tab/04)

    /// 归组三形态:worktree 折主仓、.git/worktrees 折主仓、普通取末段;退化输入 nil。
    func testWorkspaceResolution() {
        XCTAssertEqual(
            AgentWorkspaceResolution.projectName(fromPath: "/Users/x/pulse/.worktrees/agent-project"),
            "pulse"
        )
        XCTAssertEqual(
            AgentWorkspaceResolution.projectName(fromPath: "/Users/x/pulse/.git/worktrees/feat"),
            "pulse"
        )
        XCTAssertEqual(
            AgentWorkspaceResolution.projectName(fromPath: "/Users/x/macos/pulse"),
            "pulse"
        )
        // slug(worktree 段字面保留;项目名含 "-" 不受影响——末段逐字)。
        XCTAssertEqual(
            AgentWorkspaceResolution.projectName(fromSlug: "-Users-x-pulse-.worktrees-agent-usage"),
            "pulse"
        )
        XCTAssertEqual(
            AgentWorkspaceResolution.projectName(fromSlug: "-Users-aa-Documents-Learn-macos-pulse"),
            "pulse"
        )
        XCTAssertNil(AgentWorkspaceResolution.projectName(fromPath: ""))
        XCTAssertEqual(AgentWorkspaceResolution.slug(fromRelativePath: "-Users-x-pulse/s1.jsonl"), "-Users-x-pulse")
    }

    /// 双轨聚合:同一样本进合计轨与项目轨(worktree 归组主仓名);
    /// workspace 缺失只进合计轨;cache 回填只进合计轨。
    func testAggregatorDualTrack() throws {
        var aggregator = AgentDailyAggregator()
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u1", startedAtMs: noonMs(2026, 11, 10),
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150,
                workspacePath: "/Users/x/pulse/.worktrees/agent-project"
            ),
            legacySchema: false
        )
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u2", startedAtMs: noonMs(2026, 11, 10),
                inputTokens: 10, outputTokens: 5, computedTotalTokens: 15,
                workspacePath: nil
            ),
            legacySchema: false
        )
        try aggregator.addClaude(
            XCTUnwrap(ClaudeTranscriptUsageParser.parse(line: claudeLine(id: "m1", cwd: "/Users/x/octok-client"))),
            slug: "-Users-x-octok-client"
        )
        // cwd 缺失的老格式行:slug 兜底(含 - 项目名取末词,限制如实钉住)。
        try aggregator.addClaude(
            XCTUnwrap(ClaudeTranscriptUsageParser.parse(line: claudeLine(
                id: "m2",
                timestamp: "2026-11-10T13:00:00.000Z"
            ))),
            slug: "-Users-x-my-app"
        )
        aggregator.addStatsCacheDay(dayKey(2026, 11, 10), totalTokens: 999)

        let totals = aggregator.rows(scannedAt: Date())
        XCTAssertEqual(totals.filter { $0.source == .zcode }.first?.totalTokens, 165)

        let projects = aggregator.projectRows(scannedAt: Date())
        XCTAssertEqual(projects.count, 3) // zcode→pulse、claude→octok-client(cwd 保真)、slug 兜底→app
        let pulse = projects.first { $0.project == "pulse" }
        XCTAssertEqual(pulse?.source, .zcode)
        XCTAssertEqual(pulse?.totalTokens, 150) // u2 无 workspace 不进项目轨
        XCTAssertEqual(projects.first { $0.project == "octok-client" }?.totalTokens, 360)
        XCTAssertEqual(projects.first { $0.project == "app" }?.totalTokens, 360)
    }

    /// 项目表 store:覆盖写 + 排序读回。
    func testStoreProjectRows() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())
        try store.upsertProjects([
            AgentProjectUsageRow(day: "2026-11-10", source: .claude, project: "pulse", totalTokens: 100, scannedAt: 1),
        ])
        try store.upsertProjects([
            AgentProjectUsageRow(day: "2026-11-10", source: .claude, project: "pulse", totalTokens: 260, scannedAt: 2),
            AgentProjectUsageRow(day: "2026-11-10", source: .zcode, project: "pulse", totalTokens: 40, scannedAt: 2),
        ])
        let rows = try store.projectRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.source == .claude }?.totalTokens, 260)
    }

    /// 全量档产出项目轨行(编排器 upsertProjects 接线)。
    func testFullRescanWritesProjectRows() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())
        let reader = FakeUsageReader()
        reader.zcode = [
            ZCodeUsageSample(
                id: "u1", startedAtMs: noonMs(2026, 11, 12),
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150,
                workspacePath: "/Users/x/pulse/.worktrees/agent-project"
            ),
        ]
        reader.claudeFiles = [
            (
                key: "-Users-x-pulse/s1.jsonl",
                modifiedAt: Date(),
                lines: [claudeLine(id: "m1", timestamp: "2026-11-12T12:00:00.000Z")]
            ),
        ]

        var catalog = AgentUsageCatalog()
        _ = catalog.fullRescan(reader: reader, store: store, now: Date())

        let projects = try store.projectRows()
        // 两家都归到 pulse(claude slug 末段 = pulse)。
        XCTAssertEqual(projects.count, 2)
        XCTAssertTrue(projects.allSatisfy { $0.project == "pulse" })
    }

    // MARK: 模型轨(agent-tab/05)

    /// 解析器提出 message.model;缺失为 nil。
    func testClaudeLineParsesModel() throws {
        let withModel = try XCTUnwrap(
            ClaudeTranscriptUsageParser.parse(line: claudeLine(id: "m1", model: "claude-opus-5-5"))
        )
        XCTAssertEqual(withModel.model, "claude-opus-5-5")
        let without = try XCTUnwrap(ClaudeTranscriptUsageParser.parse(line: claudeLine(id: "m2")))
        XCTAssertNil(without.model)
    }

    /// 三轨聚合:模型挂在项目之下——项目 + 模型都归组成功才进;模型缺失 /
    /// 项目缺失都只进前两轨;模型分桶独立于来源(claude 与 zcode 同模型各自一行,
    /// source 是主键的一部分)。
    func testAggregatorModelTrack() throws {
        var aggregator = AgentDailyAggregator()
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u1", startedAtMs: noonMs(2026, 11, 10),
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150,
                workspacePath: "/Users/x/pulse/.worktrees/agent-project",
                modelId: "GLM-5.3"
            ),
            legacySchema: false
        )
        // workspace 在、model_id 缺(老 schema):只进项目轨。
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u2", startedAtMs: noonMs(2026, 11, 10),
                inputTokens: 10, outputTokens: 5, computedTotalTokens: 15,
                workspacePath: "/Users/x/pulse"
            ),
            legacySchema: false
        )
        // workspace 缺、model 在:只进合计轨(模型轨挂项目之下,项目未知不进)。
        aggregator.addZCode(
            ZCodeUsageSample(
                id: "u3", startedAtMs: noonMs(2026, 11, 10),
                inputTokens: 1, outputTokens: 1, computedTotalTokens: 2,
                modelId: "GLM-5.3"
            ),
            legacySchema: false
        )
        try aggregator.addClaude(
            XCTUnwrap(ClaudeTranscriptUsageParser.parse(
                line: claudeLine(id: "m1", cwd: "/Users/x/pulse", model: "claude-opus-5-5")
            ))
        )
        // model 缺失的老行:进项目轨、不进模型轨。
        try aggregator.addClaude(
            XCTUnwrap(ClaudeTranscriptUsageParser.parse(line: claudeLine(
                id: "m2",
                timestamp: "2026-11-10T13:00:00.000Z",
                cwd: "/Users/x/pulse"
            )))
        )

        let models = aggregator.modelRows(scannedAt: Date())
        XCTAssertEqual(models.count, 2) // zcode→GLM-5.3、claude→claude-opus-5-5(同项目不同来源)
        let glm = models.first { $0.model == "GLM-5.3" }
        XCTAssertEqual(glm?.project, "pulse")
        XCTAssertEqual(glm?.source, .zcode)
        XCTAssertEqual(glm?.totalTokens, 150) // u2/u3 不进模型轨
        let opus = models.first { $0.model == "claude-opus-5-5" }
        XCTAssertEqual(opus?.source, .claude)
        XCTAssertEqual(opus?.totalTokens, 360)
        XCTAssertEqual(opus?.requestCount, 1)

        // 前两轨不受模型轨增减影响(u2 计入项目轨、u3 只进合计轨)。
        let projects = aggregator.projectRows(scannedAt: Date())
        let pulseZcode = projects.first { $0.project == "pulse" && $0.source == .zcode }
        XCTAssertEqual(pulseZcode?.totalTokens, 165)
    }

    /// 模型表 store:覆盖写 + 排序读回。
    func testStoreModelRows() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())
        try store.upsertModels([
            AgentModelUsageRow(
                day: "2026-11-10",
                source: .claude,
                project: "pulse",
                model: "claude-opus-5-5",
                totalTokens: 100,
                scannedAt: 1
            ),
        ])
        try store.upsertModels([
            AgentModelUsageRow(
                day: "2026-11-10",
                source: .claude,
                project: "pulse",
                model: "claude-opus-5-5",
                totalTokens: 260,
                scannedAt: 2
            ),
            AgentModelUsageRow(
                day: "2026-11-10",
                source: .claude,
                project: "pulse",
                model: "glm-5.2",
                totalTokens: 40,
                scannedAt: 2
            ),
        ])
        let rows = try store.modelRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.model == "claude-opus-5-5" }?.totalTokens, 260)
    }

    /// 全量档产出模型轨行(编排器 upsertModels 接线)。
    func testFullRescanWritesModelRows() throws {
        let store = try AgentUsageStore(database: HistoryDatabase.openInMemory())
        let reader = FakeUsageReader()
        reader.zcode = [
            ZCodeUsageSample(
                id: "u1", startedAtMs: nowMs(Date()),
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150,
                workspacePath: "/Users/x/pulse/.worktrees/agent-project",
                modelId: "GLM-5.3"
            ),
        ]
        var catalog = AgentUsageCatalog()
        _ = catalog.fullRescan(reader: reader, store: store, now: Date())

        let models = try store.modelRows()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "GLM-5.3")
        XCTAssertEqual(models.first?.project, "pulse")
    }
}
