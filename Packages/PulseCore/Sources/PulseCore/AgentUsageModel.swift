import Foundation
import GRDB

// MARK: - 每日 token 账本(agent-tab/02)

//
// 三源按天聚合,落 Pulse 自己的历史库(`agent_daily_usage` 表,HistoryDatabase
// 同库新表)——源会删历史(ZCode session 级联删 model_usage、Claude 30 天滚动
// 清理),落库行不再受源存亡影响。双档刷新(2026-11-12 用户拍板):定时档只重算
// 「今天」(跨午夜偏差用户明示接受,不做今天+昨天双覆盖);全量档手动触发
// (「重新扫描」),补齐漏掉的天,库空时首次自动跑一次。
//
// 口径(全部实测 + tokscale zcode.rs 实证,见票 agent-tab/02):
// - ZCode `model_usage.input_tokens` **已含** cache_read+cache_creation、
//   `output_tokens` **已含** reasoning,五桶非互斥——`computed_total_tokens`
//   探形状(total==input+output 即含重叠,减之);时间锚 `started_at`
//   (非 completed_at,tokscale #890 教训)。
// - Claude jsonl 五桶天然互斥;`output_tokens` 已含 thinking(details 不另加),
//   reasoning 桶恒 0;按 message.id 去重防 stream 多行重复计。
// - stats-cache dailyModelTokens 只有按天 total——jsonl 30 天窗口外的兜底
//   回填,只填库中无数据且非今天的天,origin 标 cache。

/// 账本来源。
public enum AgentUsageSource: String, Codable, Sendable, DatabaseValueConvertible {
    case claude
    case zcode
}

/// 账本行的数据出处(排查「这天数字哪来的」)。
public enum AgentUsageOrigin: String, Codable, Sendable, DatabaseValueConvertible {
    /// Claude projects jsonl(细粒度,30 天窗口内)。
    case jsonl
    /// ZCode db.sqlite model_usage(细粒度)。
    case db
    /// Claude stats-cache.json(粗粒度回填,只有 total)。
    case cache
}

/// 每日账本行:一天 × 一来源一行,主键 `(day, source)`;重扫永远覆盖(upsert)
/// 不追加,怎么扫都不重复计数。
public struct AgentDailyUsageRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent_daily_usage"

    /// "yyyy-MM-dd"(聚合时本地时区)。
    public var day: String
    public var source: AgentUsageSource
    public var origin: AgentUsageOrigin
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    /// 五桶互斥口径的总和(= 五桶相加;cache 回填行只有此列非零)。
    public var totalTokens: Int
    public var requestCount: Int
    /// 落库时刻(epoch 秒)。
    public var scannedAt: Int64

    /// 表列是蛇形(建表 SQL),record 属性驼峰——显式映射集中在这一处。
    enum CodingKeys: String, CodingKey {
        case day
        case source
        case origin
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case reasoningTokens = "reasoning_tokens"
        case totalTokens = "total_tokens"
        case requestCount = "request_count"
        case scannedAt = "scanned_at"
    }

    public init(
        day: String,
        source: AgentUsageSource,
        origin: AgentUsageOrigin,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int = 0,
        requestCount: Int = 0,
        scannedAt: Int64 = 0
    ) {
        self.day = day
        self.source = source
        self.origin = origin
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.scannedAt = scannedAt
    }
}

// MARK: - 样本

/// ZCode `model_usage` 原始行(未归一化;毫秒时间戳、含重叠的五桶)。
public struct ZCodeUsageSample: Equatable, Sendable {
    public var id: String
    public var startedAtMs: Int64?
    public var completedAtMs: Int64?
    public var durationMs: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var computedTotalTokens: Int?

    public init(
        id: String,
        startedAtMs: Int64?,
        completedAtMs: Int64? = nil,
        durationMs: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        computedTotalTokens: Int? = nil
    ) {
        self.id = id
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.computedTotalTokens = computedTotalTokens
    }
}

/// Claude jsonl 一条带 usage 的 assistant 记录(五桶互斥;output 已含 thinking)。
public struct ClaudeUsageSample: Equatable, Sendable {
    public var timestampMs: Int64
    /// message.id(stream 多行去重键);缺失不去重、如实计。
    public var messageId: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(
        timestampMs: Int64,
        messageId: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) {
        self.timestampMs = timestampMs
        self.messageId = messageId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

// MARK: - ZCode 归一化(tokscale zcode.rs 同款)

/// 五桶重叠扣除与时间锚定。input/output 的含重叠形状由 `computedTotalTokens`
/// 检测:total == input+output(而非全加和)即含重叠,把重叠从 input/output
/// 减掉;检测不出形状(无 total)按 schema 新旧区分处理。
public enum ZCodeTokenNormalization {
    /// 饱和减法:overlap 钳在 value 内,不落负。
    static func subtractOverlap(_ value: Int, _ overlap: Int) -> Int {
        let value = max(value, 0)
        let overlap = max(overlap, 0)
        return value - min(overlap, value)
    }

    /// 归一化为互斥五桶 + 总和。
    /// - computedTotal 在且形状=含重叠 → 减重叠;
    /// - computedTotal 缺失 + legacy schema → 无条件减(旧库行实测均含重叠);
    /// - computedTotal 缺失 + 新 schema → 形状未知,原样透传(宁少勿错加)。
    public static func normalize(
        input: Int?,
        output: Int?,
        cacheRead: Int?,
        cacheWrite: Int?,
        reasoning: Int?,
        computedTotal: Int?,
        legacySchema: Bool
    ) -> (netInput: Int, netOutput: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, total: Int) {
        let rawInput = max(input ?? 0, 0)
        let rawOutput = max(output ?? 0, 0)
        let cacheRead = max(cacheRead ?? 0, 0)
        let cacheWrite = max(cacheWrite ?? 0, 0)
        let reasoning = max(reasoning ?? 0, 0)
        let cacheOverlap = cacheRead + cacheWrite

        var netInput = rawInput
        var netOutput = rawOutput
        if let total = computedTotal.map({ max($0, 0) }) {
            let inclusiveTotal = rawInput + rawOutput
            let exclusiveTotal = inclusiveTotal + cacheOverlap + reasoning
            if cacheOverlap > 0 || reasoning > 0, total == inclusiveTotal, total != exclusiveTotal {
                netInput = subtractOverlap(rawInput, cacheOverlap)
                netOutput = subtractOverlap(rawOutput, reasoning)
            }
        } else if legacySchema {
            netInput = subtractOverlap(rawInput, cacheOverlap)
            netOutput = subtractOverlap(rawOutput, reasoning)
        }

        let total = netInput + netOutput + cacheRead + cacheWrite + reasoning
        return (netInput, netOutput, cacheRead, cacheWrite, reasoning, total)
    }

    /// 时间锚:started_at 优先;缺失时 completed_at - duration 回推(防幻影
    /// 前向投影);都缺返回 nil(该行无法归天,调用方跳过)。
    public static func anchorTimestampMs(
        startedAt: Int64?,
        completedAt: Int64?,
        durationMs: Int64?
    ) -> Int64? {
        if let started = startedAt, started > 0 {
            return started
        }
        guard let completed = completedAt, completed > 0 else { return nil }
        if let duration = durationMs, duration > 0 {
            let back = completed - duration
            if back > 0 {
                return back
            }
        }
        return completed
    }
}

// MARK: - Claude 行解析

/// projects jsonl 单行 → usage 样本。只认 assistant 行且 `message.usage` 五项
/// 非全零;user / tool / 半行安静返回 nil。timestamp 顶层 ISO8601,缺失跳过。
public enum ClaudeTranscriptUsageParser {
    /// 一行(已 trim);解析不出样本返回 nil。
    public static func parse(line: String) -> ClaudeUsageSample? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (record["type"] as? String) == "assistant",
              let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + cacheRead + cacheWrite + output > 0,
              let timestamp = (record["timestamp"] as? String).flatMap(AgentISO8601.parse)
        else { return nil }

        let messageId = message["id"] as? String
        return ClaudeUsageSample(
            timestampMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            messageId: (messageId?.isEmpty == false) ? messageId : nil,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
    }
}

// MARK: - stats-cache 解析

/// `~/.claude/stats-cache.json` 的 `dailyModelTokens`(实测 2026-11-12:
/// `[{date: "2026-08-01", tokensByModel: {model: tokens}}]`)。只有按天 total,
/// 是 jsonl 30 天窗口外的兜底回填源;新鲜度由 Claude 自算不受控
/// (lastComputedDate 实测停 11-04)。
public enum ClaudeStatsCacheParser {
    /// 按天 token 总量(各模型求和);形状不符返回空。
    public static func dailyTotals(from data: Data?) -> [(day: String, totalTokens: Int)] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["dailyModelTokens"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let day = entry["date"] as? String,
                  let byModel = entry["tokensByModel"] as? [String: Int]
            else { return nil }
            let total = byModel.values.reduce(0, +)
            guard total > 0 else { return nil }
            return (day, total)
        }
    }
}

// MARK: - 聚合器

/// 样本 → 按 `(day, source, origin)` 的账本行;本地时区分天。Claude 侧按
/// `fileKey + message.id` 去重(stream 多行只计一次);id 缺失如实计不去重。
public struct AgentDailyAggregator {
    /// 累加桶(行模型字段平铺;day 为聚合键的一部分)。
    private struct Bucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0
        var total = 0
        var requests = 0
    }

    private var buckets: [Key: Bucket] = [:]
    private var seenClaudeMessageIDs: Set<String> = []
    /// 非 static(DateFormatter 非并发安全,实例持有;聚合器本身单线程使用)。
    private let dayFormatter: DateFormatter

    private struct Key: Hashable {
        var day: String
        var source: AgentUsageSource
        var origin: AgentUsageOrigin
    }

    public init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter = formatter
    }

    /// 归一化并聚合一条 ZCode 行;时间锚解析失败的行跳过。日键按本地时区。
    public mutating func addZCode(_ sample: ZCodeUsageSample, legacySchema: Bool) {
        let normalized = ZCodeTokenNormalization.normalize(
            input: sample.inputTokens,
            output: sample.outputTokens,
            cacheRead: sample.cacheReadTokens,
            cacheWrite: sample.cacheWriteTokens,
            reasoning: sample.reasoningTokens,
            computedTotal: sample.computedTotalTokens,
            legacySchema: legacySchema
        )
        guard normalized.total > 0,
              let anchorMs = ZCodeTokenNormalization.anchorTimestampMs(
                  startedAt: sample.startedAtMs,
                  completedAt: sample.completedAtMs,
                  durationMs: sample.durationMs.map { Int64($0) }
              ),
              let day = day(forMillis: anchorMs)
        else { return }

        let key = Key(day: day, source: .zcode, origin: .db)
        accumulate(into: &buckets[key, default: Bucket()], normalized: normalized)
    }

    /// 聚合一条 Claude 样本;重复 message.id 只计一次——msg id 是 Anthropic 消息
    /// 级全局标识,resume/compact 把历史复制进新文件时同 id 不双计。
    /// id 缺失如实计不去重。
    public mutating func addClaude(_ sample: ClaudeUsageSample) {
        let total = sample.inputTokens + sample.outputTokens
            + sample.cacheReadTokens + sample.cacheWriteTokens
        guard total > 0,
              let day = day(forMillis: sample.timestampMs)
        else { return }

        if let messageId = sample.messageId {
            guard !seenClaudeMessageIDs.contains(messageId) else { return }
            seenClaudeMessageIDs.insert(messageId)
        }

        let key = Key(day: day, source: .claude, origin: .jsonl)
        var bucket = buckets[key, default: Bucket()]
        bucket.input += sample.inputTokens
        bucket.output += sample.outputTokens
        bucket.cacheRead += sample.cacheReadTokens
        bucket.cacheWrite += sample.cacheWriteTokens
        bucket.total += total
        bucket.requests += 1
        buckets[key] = bucket
    }

    /// stats-cache 回填天(只有 total;day 字符串原样入桶)。
    public mutating func addStatsCacheDay(_ day: String, totalTokens: Int) {
        guard totalTokens > 0 else { return }
        let key = Key(day: day, source: .claude, origin: .cache)
        buckets[key, default: Bucket()].total += totalTokens
    }

    /// 输出账本行(按天排序;`scannedAt` 统一盖当前时刻)。
    public func rows(scannedAt: Date) -> [AgentDailyUsageRow] {
        let stamp = Int64(scannedAt.timeIntervalSince1970)
        return buckets
            .map { key, bucket in
                AgentDailyUsageRow(
                    day: key.day,
                    source: key.source,
                    origin: key.origin,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    cacheWriteTokens: bucket.cacheWrite,
                    reasoningTokens: bucket.reasoning,
                    totalTokens: bucket.total,
                    requestCount: bucket.requests,
                    scannedAt: stamp
                )
            }
            .sorted { ($0.day, $0.source.rawValue) < ($1.day, $1.source.rawValue) }
    }

    /// 是否已聚合到任何行(编排器判断「今天有没有数据」用)。
    public var isEmpty: Bool {
        buckets.isEmpty
    }

    private func accumulate(
        into bucket: inout Bucket,
        normalized: (netInput: Int, netOutput: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, total: Int)
    ) {
        bucket.input += normalized.netInput
        bucket.output += normalized.netOutput
        bucket.cacheRead += normalized.cacheRead
        bucket.cacheWrite += normalized.cacheWrite
        bucket.reasoning += normalized.reasoning
        bucket.total += normalized.total
        bucket.requests += 1
    }

    /// 毫秒时间戳 → 本地时区日键(dayFormatter 默认系统时区)。
    private func day(forMillis ms: Int64) -> String? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return dayFormatter.string(from: date)
    }
}

// MARK: - 合并策略

/// 扫描结果与库中已有行的合并:细粒度(jsonl / db)永远覆盖写;cache 只填
/// 「库中无该天 claude 行且非今天」的缺口(今天的 cache 数据可能还没被 Claude
/// 算出来,宁缺勿错)。
public enum AgentUsageMerge {
    /// - Parameters:
    ///   - freshDetailed: 本轮扫出的细粒度行(origin = jsonl / db)。
    ///   - cacheBackfill: stats-cache 粗粒度行(origin = cache)。
    ///   - knownClaudeDays: 库中已有 claude 行的天(任何 origin)。
    ///   - today: 今天日键;cache 不回填今天。
    public static func merge(
        freshDetailed: [AgentDailyUsageRow],
        cacheBackfill: [AgentDailyUsageRow],
        knownClaudeDays: Set<String>,
        today: String
    ) -> (upserts: [AgentDailyUsageRow], insertsIfAbsent: [AgentDailyUsageRow]) {
        let upserts = freshDetailed
        let inserts = cacheBackfill.filter { row in
            row.day != today && !knownClaudeDays.contains(row.day)
        }
        return (upserts, inserts)
    }
}

// MARK: - 落库 store

/// `agent_daily_usage` 表的读写(HistoryDatabase 同库;表迁移在 HistoryDatabase
/// migrator `agent-tab-02-usage`)。线程安全由 GRDB DatabaseQueue 串行保证。
public final class AgentUsageStore: Sendable {
    private let database: DatabaseQueue

    /// 打开历史库(要求迁移已就位——HistoryDatabase.open 之后注入同一队列)。
    public init(database: DatabaseQueue) {
        self.database = database
    }

    /// 覆盖写(主键 (day, source) 冲突即替换)。
    public func upsert(_ rows: [AgentDailyUsageRow]) throws {
        guard !rows.isEmpty else { return }
        try database.write { db in
            for row in rows {
                try row.save(db)
            }
        }
    }

    /// 只插缺失天(主键冲突忽略)——cache 回填专用。
    public func insertIfAbsent(_ rows: [AgentDailyUsageRow]) throws {
        guard !rows.isEmpty else { return }
        try database.write { db in
            for row in rows {
                try row.insert(db, onConflict: .ignore)
            }
        }
    }

    /// 库中已有 claude 行的天(任何 origin)。
    public func knownClaudeDays() throws -> Set<String> {
        try database.read { db in
            try Set(
                String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT day FROM agent_daily_usage WHERE source = ?",
                    arguments: [AgentUsageSource.claude.rawValue]
                )
            )
        }
    }

    /// 全部账本行(图表数据;按天升序)。
    public func rows() throws -> [AgentDailyUsageRow] {
        try database.read { db in
            try AgentDailyUsageRow
                .order(sql: "day ASC, source ASC")
                .fetchAll(db)
        }
    }

    /// 账本是否有任何行(首次自动全量的判断)。
    public func hasAnyRow() throws -> Bool {
        try database.read { db in
            try AgentDailyUsageRow.fetchCount(db) > 0
        }
    }
}

// MARK: - IO 接缝

public protocol AgentUsageReading: Sendable {
    /// ZCode db.sqlite `model_usage` 原始行。`sinceStartedAtMs` nil = 全量;
    /// 库缺席 / 表或列不识别 → 空样本(安静降级,schema 是 ZCode 私有演进物)。
    /// `legacySchema` = 实现探测 `computed_total_tokens` 列缺失(旧 schema
    /// 无条件减重叠)。
    func zcodeUsageSamples(sinceStartedAtMs: Int64?) -> (
        samples: [ZCodeUsageSample], legacySchema: Bool
    )

    /// 逐行喂 `~/.claude/projects/` 下会话 jsonl(`modifiedSince` nil = 全部
    /// 文件;文件级 mtime 过滤)。consume 在调用线程同步逐行执行(非逃逸
    /// 语义),不跨线程。
    func readClaudeTranscripts(
        modifiedSince: Date?,
        consume: (_ line: String) -> Void
    )

    /// `~/.claude/stats-cache.json` 内容;缺失返回 nil。
    func claudeStatsCacheData() -> Data?
}

// MARK: - 编排器

/// 双档刷新编排(纯值内核,IO 与落库经参数注入):
/// - **定时档** `refreshToday`:按 `refreshInterval` 节流,只重算今天
///   (用户拍板:只算一天,跨午夜偏差接受)——ZCode 增量(今天 0 点起)、
///   Claude 只扫今天有改动的文件,upsert 今天行。
/// - **全量档** `fullRescan`:ZCode 全表 + Claude 全部 jsonl + stats-cache
///   回填;细粒度覆盖、cache 只填缺天。手动触发,库空时首次自动跑。
public struct AgentUsageCatalog {
    /// 定时档节流(分钟级——不进秒级心跳档;弹窗开 1s 不放大 IO)。
    public static let defaultRefreshInterval: TimeInterval = 300

    private var lastRefreshAt: Date?
    private let refreshInterval: TimeInterval

    public init(refreshInterval: TimeInterval = AgentUsageCatalog.defaultRefreshInterval) {
        self.refreshInterval = refreshInterval
    }

    /// 定时档:节流内返回 nil(调用方无事发生);刷新后返回全表账本行。
    @discardableResult
    public mutating func refreshToday(
        reader: any AgentUsageReading,
        store: AgentUsageStore,
        calendar: Calendar = .current,
        now: Date
    ) -> [AgentDailyUsageRow]? {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < refreshInterval {
            return nil
        }
        lastRefreshAt = now

        let startOfToday = calendar.startOfDay(for: now)
        var aggregator = AgentDailyAggregator()
        let samples = reader.zcodeUsageSamples(
            sinceStartedAtMs: Int64(startOfToday.timeIntervalSince1970 * 1000)
        )
        for sample in samples.samples {
            aggregator.addZCode(sample, legacySchema: samples.legacySchema)
        }
        reader.readClaudeTranscripts(modifiedSince: startOfToday) { line in
            guard let sample = ClaudeTranscriptUsageParser.parse(line: line) else { return }
            // 捕获聚合器:去重集跨文件累积,不能每次调用新建。
            aggregator.addClaude(sample)
        }

        try? store.upsert(aggregator.rows(scannedAt: now))
        return try? store.rows()
    }

    /// 全量档:全源重扫 + stats-cache 回填缺天;返回全表账本行。
    @discardableResult
    public mutating func fullRescan(
        reader: any AgentUsageReading,
        store: AgentUsageStore,
        calendar: Calendar = .current,
        now: Date
    ) -> [AgentDailyUsageRow] {
        lastRefreshAt = now

        var aggregator = AgentDailyAggregator()
        let samples = reader.zcodeUsageSamples(sinceStartedAtMs: nil)
        for sample in samples.samples {
            aggregator.addZCode(sample, legacySchema: samples.legacySchema)
        }
        reader.readClaudeTranscripts(modifiedSince: nil) { line in
            guard let sample = ClaudeTranscriptUsageParser.parse(line: line) else { return }
            aggregator.addClaude(sample)
        }
        for backfill in ClaudeStatsCacheParser.dailyTotals(from: reader.claudeStatsCacheData()) {
            aggregator.addStatsCacheDay(backfill.day, totalTokens: backfill.totalTokens)
        }

        let today = aggregator.dayKey(now)
        let all = aggregator.rows(scannedAt: now)
        let detailed = all.filter { $0.origin != .cache }
        let cacheRows = all.filter { $0.origin == .cache }
        let knownDays = (try? store.knownClaudeDays()) ?? []
        let merged = AgentUsageMerge.merge(
            freshDetailed: detailed,
            cacheBackfill: cacheRows,
            knownClaudeDays: knownDays,
            today: today
        )
        try? store.upsert(merged.upserts)
        try? store.insertIfAbsent(merged.insertsIfAbsent)
        return (try? store.rows()) ?? []
    }
}

extension AgentDailyAggregator {
    /// 单点日键(全量档判「今天」用;internal 供编排器)。
    func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
