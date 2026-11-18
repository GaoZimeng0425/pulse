import Foundation
import GRDB

// MARK: - Claude jsonl 增量检查点扫描(agent-tab/12)

//
// 账本 Claude 侧从「每轮全量重读重解析」改为**每文件检查点续扫**(tokscale
// claudecode.rs 同思路):未变文件零打开、追加文件只解析新增字节、原地改写由
// 前缀 SHA-256 失配检出后全量重读。机制与取舍全档见票 agent-tab/12。
//
// 三件套:
// - `agent_file_checkpoints`:每文件的已消费字节偏移 + 前缀哈希 + 它对账本的
//   **完整贡献**(day × project × model 五桶)——账本行 = Σ 全部检查点贡献,
//   每轮完整重算(便宜),compact 缩水由此自愈;
// - `agent_seen_messages`:全局 message-id 去重状态(resume 复制历史进新文件
//   不双计;全史实测 ~15 万行,sqlite 量级轻松);
// - `AgentUsageScan`:编排——库存 stat 快路径 → 增量读 → Σ 落账(含 ZCode 原
//   路径与 stats-cache 回填)。
//
// 与 agent-tab/02 热修「定时档只写今天」的关系:该护栏针对「今天子集覆盖完整
// 历史」;检查点 Σ 是完整口径,写 Σ 中有数据的全部天反而能自愈缩水,护栏由
// 本机制取代(票面已拍板)。

/// Claude 会话文件引用(库存枚举产物;stat 而不打开)。
public struct ClaudeFileRef: Equatable, Sendable {
    /// `<slug>/<sessionId>.jsonl`(相对 projects 根;项目归组的输入)。
    public var key: String
    public var modifiedAt: Date
    public var sizeBytes: UInt64

    public init(key: String, modifiedAt: Date, sizeBytes: UInt64) {
        self.key = key
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
    }
}

/// 单文件一次增量读的结果。
public enum ClaudeFileReadOutcome: Equatable, Sendable {
    /// 检查点命中且内容未变(哈希一致);无需解析。
    case unchanged
    /// 续扫推进:新消费到的字节偏移(完整行边界,含换行)+ 覆盖 [0, offset) 的
    /// 前缀 SHA-256。
    case advanced(consumedOffset: UInt64, prefixSha256: Data)
    /// 前缀哈希失配 / 文件变小:被原地改写(compact 等),调用方清 seen 后全量重读。
    case rewritten
}

/// 一个文件对账本的一天 × 项目 × 模型贡献(五桶互斥口径,同账本行)。
/// project / model 为 nil = 该行不进对应细分轨(与 AgentDailyAggregator 口径一致)。
public struct AgentCheckpointBucket: Codable, Equatable, Sendable {
    public var day: String
    public var project: String?
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var totalTokens: Int
    public var requestCount: Int

    public init(
        day: String,
        project: String? = nil,
        model: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int = 0,
        requestCount: Int = 0
    ) {
        self.day = day
        self.project = project
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
    }
}

/// 检查点聚合键(day × project × model)。
struct AgentCheckpointBucketKey: Hashable {
    var day: String
    var project: String?
    var model: String?
}

// MARK: - 落库行

/// `agent_file_checkpoints` 行。
public struct AgentFileCheckpointRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent_file_checkpoints"

    public var fileKey: String
    public var consumedOffset: Int64
    public var prefixSha256: Data
    public var bucketsJSON: Data
    /// mtime 快路径缓存(epoch 秒;哈希才是权威)。
    public var savedAtMtime: Double
    public var savedAtSize: Int64

    enum CodingKeys: String, CodingKey {
        case fileKey = "file_key"
        case consumedOffset = "consumed_offset"
        case prefixSha256 = "prefix_sha256"
        case bucketsJSON = "buckets_json"
        case savedAtMtime = "saved_at_mtime"
        case savedAtSize = "saved_at_size"
    }
}

/// `agent_seen_messages` 行(全局 message-id 去重状态)。
public struct AgentSeenMessageRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent_seen_messages"

    public var messageId: String
    public var fileKey: String
    public var day: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case fileKey = "file_key"
        case day
    }
}

// MARK: - store

/// 已载入的检查点(内存形状;buckets 已解码)。
public struct AgentLoadedCheckpoint: Sendable {
    public var consumedOffset: UInt64
    public var prefixSha256: Data
    public var savedAtMtime: Double
    public var savedAtSize: Int64
    public var buckets: [AgentCheckpointBucket]

    public init(
        consumedOffset: UInt64,
        prefixSha256: Data,
        savedAtMtime: Double,
        savedAtSize: Int64,
        buckets: [AgentCheckpointBucket]
    ) {
        self.consumedOffset = consumedOffset
        self.prefixSha256 = prefixSha256
        self.savedAtMtime = savedAtMtime
        self.savedAtSize = savedAtSize
        self.buckets = buckets
    }
}

/// 检查点两表的读写(HistoryDatabase 同库;线程安全由 DatabaseQueue 串行)。
public final class AgentCheckpointStore: Sendable {
    private let database: DatabaseQueue

    public init(database: DatabaseQueue) {
        self.database = database
    }

    /// 全部检查点(fileKey → 已解码形状)。buckets_json 损坏的行安静跳过
    /// (该文件自然走全量重读重建)。
    public func loadCheckpoints() throws -> [String: AgentLoadedCheckpoint] {
        try database.read { db in
            var result: [String: AgentLoadedCheckpoint] = [:]
            for row in try AgentFileCheckpointRow.fetchAll(db) {
                guard let buckets = Self.decodeBuckets(row.bucketsJSON) else { continue }
                result[row.fileKey] = AgentLoadedCheckpoint(
                    consumedOffset: UInt64(bitPattern: row.consumedOffset),
                    prefixSha256: row.prefixSha256,
                    savedAtMtime: row.savedAtMtime,
                    savedAtSize: row.savedAtSize,
                    buckets: buckets
                )
            }
            return result
        }
    }

    /// 全局 seen id 集(整表载入;全史 ~15 万行,内存集可接受)。
    public func loadSeenMessageIDs() throws -> Set<String> {
        try database.read { db in
            try Set(String.fetchAll(db, sql: "SELECT message_id FROM agent_seen_messages"))
        }
    }

    /// 某文件的 seen id(改写重读前清局部状态用)。
    public func seenMessageIDs(fileKey: String) throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT message_id FROM agent_seen_messages WHERE file_key = ?",
                arguments: [fileKey]
            )
        }
    }

    /// 原子落一个文件的检查点 + 本轮新见的 message id(单事务)。
    public func replace(
        fileKey: String,
        consumedOffset: UInt64,
        prefixSha256: Data,
        savedAtMtime: Double,
        savedAtSize: Int64,
        buckets: [AgentCheckpointBucket],
        newSeenMessages: [(messageId: String, day: String)]
    ) throws {
        let row = AgentFileCheckpointRow(
            fileKey: fileKey,
            consumedOffset: Int64(bitPattern: consumedOffset),
            prefixSha256: prefixSha256,
            bucketsJSON: Self.encodeBuckets(buckets),
            savedAtMtime: savedAtMtime,
            savedAtSize: savedAtSize
        )
        try database.write { db in
            try row.save(db)
            for seen in newSeenMessages {
                try AgentSeenMessageRow(messageId: seen.messageId, fileKey: fileKey, day: seen.day)
                    .insert(db, onConflict: .ignore)
            }
        }
    }

    /// mtime 快路径刷新(mtime 变了但哈希一致;不动 offset/buckets)。
    public func touchMtime(fileKey: String, savedAtMtime: Double, savedAtSize: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE agent_file_checkpoints SET saved_at_mtime = ?, saved_at_size = ? WHERE file_key = ?",
                arguments: [savedAtMtime, savedAtSize, fileKey]
            )
        }
    }

    /// 清一个文件的检查点 + seen 行(改写重读前 / 文件消失时)。
    public func purgeFile(fileKey: String) throws {
        try database.write { db in
            _ = try AgentFileCheckpointRow.deleteOne(db, key: fileKey)
            try db.execute(
                sql: "DELETE FROM agent_seen_messages WHERE file_key = ?",
                arguments: [fileKey]
            )
        }
    }

    static func encodeBuckets(_ buckets: [AgentCheckpointBucket]) -> Data {
        (try? JSONEncoder().encode(buckets)) ?? Data("[]".utf8)
    }

    static func decodeBuckets(_ data: Data) -> [AgentCheckpointBucket]? {
        try? JSONDecoder().decode([AgentCheckpointBucket].self, from: data)
    }
}

// MARK: - Σ 求和(检查点 → 账本三轨行)

/// Σ 全部文件贡献 → 账本行(claude 侧;source=.claude,origin=.jsonl)。
enum AgentCheckpointSummer {
    /// 合并两份桶列表(同键相加;用于检查点旧贡献 + 本轮增量)。
    static func mergeBuckets(
        _ base: [AgentCheckpointBucket],
        _ delta: [AgentCheckpointBucket]
    ) -> [AgentCheckpointBucket] {
        var byKey: [AgentCheckpointBucketKey: AgentCheckpointBucket] = [:]
        for bucket in base {
            byKey[key(of: bucket)] = bucket
        }
        for bucket in delta {
            let k = key(of: bucket)
            if var existing = byKey[k] {
                accumulate(&existing, bucket)
                byKey[k] = existing
            } else {
                byKey[k] = bucket
            }
        }
        return Array(byKey.values)
    }

    /// Σ → 三轨行(合计 / 项目 / 模型;`scannedAt` 统一盖当前时刻)。
    static func ledgerRows(
        buckets: [AgentCheckpointBucket],
        scannedAt: Date
    ) -> (main: [AgentDailyUsageRow], projects: [AgentProjectUsageRow], models: [AgentModelUsageRow]) {
        let stamp = Int64(scannedAt.timeIntervalSince1970)
        var main: [AgentDailyUsageRow] = []
        var projects: [AgentProjectUsageRow] = []
        var models: [AgentModelUsageRow] = []
        let grouped = Dictionary(grouping: buckets, by: \.day)

        for (day, dayBuckets) in grouped {
            let total = dayBuckets.reduce(AgentCheckpointBucket(day: day)) { partial, bucket in
                var next = partial
                accumulate(&next, bucket)
                return next
            }
            main.append(
                AgentDailyUsageRow(
                    day: day,
                    source: .claude,
                    origin: .jsonl,
                    inputTokens: total.inputTokens,
                    outputTokens: total.outputTokens,
                    cacheReadTokens: total.cacheReadTokens,
                    cacheWriteTokens: total.cacheWriteTokens,
                    reasoningTokens: total.reasoningTokens,
                    totalTokens: total.totalTokens,
                    requestCount: total.requestCount,
                    scannedAt: stamp
                )
            )
            // 项目轨:project 非 nil 的桶按 (day, project) 再 Σ。
            let byProject = Dictionary(grouping: dayBuckets.filter { $0.project != nil }, by: \.project!)
            for (project, projectBuckets) in byProject {
                let sum = projectBuckets.reduce(AgentCheckpointBucket(day: day, project: project)) { partial, bucket in
                    var next = partial
                    accumulate(&next, bucket)
                    return next
                }
                projects.append(
                    AgentProjectUsageRow(
                        day: day,
                        source: .claude,
                        project: project,
                        inputTokens: sum.inputTokens,
                        outputTokens: sum.outputTokens,
                        cacheReadTokens: sum.cacheReadTokens,
                        cacheWriteTokens: sum.cacheWriteTokens,
                        reasoningTokens: sum.reasoningTokens,
                        totalTokens: sum.totalTokens,
                        requestCount: sum.requestCount,
                        scannedAt: stamp
                    )
                )
                // 模型轨:project+model 双全的桶按 (day, project, model) Σ。
                let byModel = Dictionary(grouping: projectBuckets.filter { $0.model != nil }, by: \.model!)
                for (model, modelBuckets) in byModel {
                    let msum = modelBuckets.reduce(AgentCheckpointBucket(
                        day: day,
                        project: project,
                        model: model
                    )) { partial, bucket in
                        var next = partial
                        accumulate(&next, bucket)
                        return next
                    }
                    models.append(
                        AgentModelUsageRow(
                            day: day,
                            source: .claude,
                            project: project,
                            model: model,
                            inputTokens: msum.inputTokens,
                            outputTokens: msum.outputTokens,
                            cacheReadTokens: msum.cacheReadTokens,
                            cacheWriteTokens: msum.cacheWriteTokens,
                            reasoningTokens: msum.reasoningTokens,
                            totalTokens: msum.totalTokens,
                            requestCount: msum.requestCount,
                            scannedAt: stamp
                        )
                    )
                }
            }
        }
        return (main, projects, models)
    }

    private static func key(of bucket: AgentCheckpointBucket) -> AgentCheckpointBucketKey {
        AgentCheckpointBucketKey(day: bucket.day, project: bucket.project, model: bucket.model)
    }

    private static func accumulate(_ into: inout AgentCheckpointBucket, _ other: AgentCheckpointBucket) {
        into.inputTokens += other.inputTokens
        into.outputTokens += other.outputTokens
        into.cacheReadTokens += other.cacheReadTokens
        into.cacheWriteTokens += other.cacheWriteTokens
        into.reasoningTokens += other.reasoningTokens
        into.totalTokens += other.totalTokens
        into.requestCount += other.requestCount
    }
}

// MARK: - 扫描编排

/// Claude 增量扫描档位。
public enum AgentScanScope: Sendable, Equatable {
    /// 定时档:ZCode 只拉今天(检查点后 Claude 侧两档等价,区别只剩 ZCode 窗口
    /// 与 stats-cache 回填)。
    case today
    /// 全量档:ZCode 全表 + stats-cache 回填缺天。
    case full
}

/// 增量扫描编排(agent-tab/12):检查点续扫 Claude → Σ 全部检查点落账 →
/// ZCode 原路径合入 → stats-cache 回填(全量档)。无内部节流——调用方
/// (AgentUsageFeature)的心跳按 `defaultRefreshInterval`(沿用 agent-tab/02
/// 的 5 分钟档)自行闸。
public struct AgentUsageScan {
    /// 定时档节流间隔(分钟级;agent-tab/02 拍板沿用)。
    public static let defaultRefreshInterval: TimeInterval = 300

    public init() {}

    /// 一轮扫描;返回全表账本行。IO/落库异常整体吞掉返回 nil(下轮再试,
    /// 与旧 catalog 语义一致)。
    @discardableResult
    public func scan(
        reader: any AgentUsageReading,
        checkpoints: AgentCheckpointStore,
        ledger: AgentUsageStore,
        calendar: Calendar = .current,
        now: Date,
        scope: AgentScanScope
    ) -> [AgentDailyUsageRow]? {
        let claude = scanClaude(reader: reader, checkpoints: checkpoints, now: now)
        guard let claude else { return nil }

        // ZCode 原路径(查询本就按 started_at 增量;agent-tab/12 票外)。
        var aggregator = AgentDailyAggregator()
        let sinceMs: Int64? = scope == .today
            ? Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
            : nil
        let samples = reader.zcodeUsageSamples(sinceStartedAtMs: sinceMs)
        for sample in samples.samples {
            aggregator.addZCode(sample, legacySchema: samples.legacySchema)
        }
        let mainRows = claude.main + aggregator.rows(scannedAt: now)
        let projectRows = claude.projects + aggregator.projectRows(scannedAt: now)
        let modelRows = claude.models + aggregator.modelRows(scannedAt: now)

        do {
            try ledger.upsert(mainRows)
            try ledger.upsertProjects(projectRows)
            try ledger.upsertModels(modelRows)
            // stats-cache 回填(全量档;规则不变:只填无细粒度数据且非今天的天)。
            if scope == .full {
                var backfiller = AgentDailyAggregator()
                for backfill in ClaudeStatsCacheParser.dailyTotals(from: reader.claudeStatsCacheData()) {
                    backfiller.addStatsCacheDay(backfill.day, totalTokens: backfill.totalTokens)
                }
                let cacheRows = backfiller.rows(scannedAt: now)
                let knownDays = try (ledger.knownClaudeDays())
                    .union(Set(mainRows.filter { $0.source == .claude }.map(\.day)))
                let merged = AgentUsageMerge.merge(
                    freshDetailed: [],
                    cacheBackfill: cacheRows,
                    knownClaudeDays: knownDays,
                    today: dayKey(now, calendar: calendar)
                )
                try ledger.insertIfAbsent(merged.insertsIfAbsent)
            }
            return try ledger.rows()
        } catch {
            return nil
        }
    }

    /// Claude 侧一轮增量扫描(单独抽出便于测试):返回 Σ 后的三轨行。
    func scanClaude(
        reader: any AgentUsageReading,
        checkpoints: AgentCheckpointStore,
        calendar: Calendar = .current,
        now: Date
    ) -> (main: [AgentDailyUsageRow], projects: [AgentProjectUsageRow], models: [AgentModelUsageRow])? {
        guard let loaded = try? checkpoints.loadCheckpoints(),
              let seenAll = try? checkpoints.loadSeenMessageIDs()
        else { return nil }

        var seen = seenAll
        // 文件 → 当前完整贡献(未触碰文件直接用检查点缓存)。
        var perFileBuckets: [String: [AgentCheckpointBucket]] = loaded.mapValues(\.buckets)
        let inventory = reader.claudeFileInventory()
        var alive = Set<String>()

        for file in inventory {
            alive.insert(file.key)
            let existing = loaded[file.key]
            // mtime+size 快路径:零打开零解析。
            if let checkpoint = existing,
               checkpoint.savedAtSize == Int64(bitPattern: file.sizeBytes),
               checkpoint.savedAtMtime == file.modifiedAt.timeIntervalSince1970 {
                continue
            }

            var parser = CheckpointLineParser(
                seen: seen,
                slug: AgentWorkspaceResolution.slug(fromRelativePath: file.key)
            )
            let checkpointArg = existing.map {
                (offset: $0.consumedOffset, prefixSha256: $0.prefixSha256)
            }
            let outcome = reader.readClaudeFileIncremental(file, checkpoint: checkpointArg) { line in
                parser.consume(line)
            }

            switch outcome {
            case .unchanged:
                // mtime 变了但内容一致:刷新快路径缓存,免得每轮重哈希。
                try? checkpoints.touchMtime(
                    fileKey: file.key,
                    savedAtMtime: file.modifiedAt.timeIntervalSince1970,
                    savedAtSize: Int64(bitPattern: file.sizeBytes)
                )
            case let .advanced(offset, sha256):
                // 续扫:旧贡献 + 本轮增量(同键相加)。
                let merged = existing != nil
                    ? AgentCheckpointSummer.mergeBuckets(existing!.buckets, parser.buckets)
                    : parser.buckets
                try? checkpoints.replace(
                    fileKey: file.key,
                    consumedOffset: offset,
                    prefixSha256: sha256,
                    savedAtMtime: file.modifiedAt.timeIntervalSince1970,
                    savedAtSize: Int64(bitPattern: file.sizeBytes),
                    buckets: merged,
                    newSeenMessages: parser.newSeenMessages
                )
                perFileBuckets[file.key] = merged
                seen.formUnion(parser.newSeenIDs)
            case .rewritten:
                // 原地改写(compact):贡献要**替换**不是叠加。先取旧 seen id 出
                // 局部集(防幸存轮次被自己旧 id 误判重复),全量重读;重读成功
                // 才 purge + 落新检查点(重读竞态失败则检查点原样,本轮放弃)。
                let staleIDs = (try? checkpoints.seenMessageIDs(fileKey: file.key)) ?? []
                for id in staleIDs {
                    seen.remove(id)
                }
                var fullParser = CheckpointLineParser(
                    seen: seen,
                    slug: AgentWorkspaceResolution.slug(fromRelativePath: file.key)
                )
                let reparsed = reader.readClaudeFileIncremental(file, checkpoint: nil) { line in
                    fullParser.consume(line)
                }
                if case let .advanced(offset, sha256) = reparsed {
                    try? checkpoints.purgeFile(fileKey: file.key)
                    try? checkpoints.replace(
                        fileKey: file.key,
                        consumedOffset: offset,
                        prefixSha256: sha256,
                        savedAtMtime: file.modifiedAt.timeIntervalSince1970,
                        savedAtSize: Int64(bitPattern: file.sizeBytes),
                        buckets: fullParser.buckets,
                        newSeenMessages: fullParser.newSeenMessages
                    )
                    perFileBuckets[file.key] = fullParser.buckets
                    seen.formUnion(fullParser.newSeenIDs)
                } else {
                    for id in staleIDs {
                        seen.insert(id)
                    }
                }
            }
        }

        // 消失的文件:清检查点 + seen;贡献移出 Σ(账本旧行保留,不归零)。
        for vanished in Set(loaded.keys).subtracting(alive) {
            try? checkpoints.purgeFile(fileKey: vanished)
            perFileBuckets[vanished] = nil
        }

        let allBuckets = perFileBuckets.values.flatMap(\.self)
        return AgentCheckpointSummer.ledgerRows(buckets: allBuckets, scannedAt: now)
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - 行 → 检查点桶的解析闭包

/// 一轮文件读的行消费器:解析 + 全局去重 + 落到该文件的增量桶。
struct CheckpointLineParser {
    private var seen: Set<String>
    /// 文件 slug(行内 cwd 缺失时的项目归组退路,同旧聚合器)。
    private let slug: String?
    private var byKey: [AgentCheckpointBucketKey: AgentCheckpointBucket] = [:]
    private(set) var newSeenMessages: [(messageId: String, day: String)] = []
    private(set) var newSeenIDs: [String] = []
    /// 非 static(DateFormatter 非并发安全;单文件读单线程使用)。
    private let dayFormatter: DateFormatter

    init(seen: Set<String>, slug: String?) {
        self.seen = seen
        self.slug = slug
        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    }

    mutating func consume(_ line: String) {
        guard let sample = ClaudeTranscriptUsageParser.parse(line: line) else { return }
        let total = sample.inputTokens + sample.outputTokens
            + sample.cacheReadTokens + sample.cacheWriteTokens
        guard total > 0 else { return }
        if let messageId = sample.messageId {
            guard !seen.contains(messageId) else { return }
            seen.insert(messageId)
            newSeenIDs.append(messageId)
        }
        let day = dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(sample.timestampMs) / 1000))
        if let messageId = sample.messageId {
            newSeenMessages.append((messageId, day))
        }
        // 项目归组:行内 cwd 优先,退 slug 反解(同 AgentDailyAggregator.addClaude)。
        let project = sample.cwd.flatMap(AgentWorkspaceResolution.projectName(fromPath:))
            ?? slug.flatMap(AgentWorkspaceResolution.projectName(fromSlug:))
        accumulate(
            day: day,
            project: project,
            model: sample.model,
            sample: sample,
            total: total
        )
    }

    var buckets: [AgentCheckpointBucket] {
        Array(byKey.values)
    }

    private mutating func accumulate(
        day: String,
        project: String?,
        model: String?,
        sample: ClaudeUsageSample,
        total: Int
    ) {
        let key = AgentCheckpointBucketKey(day: day, project: project, model: model)
        var bucket = byKey[key] ?? AgentCheckpointBucket(day: day, project: project, model: model)
        bucket.inputTokens += sample.inputTokens
        bucket.outputTokens += sample.outputTokens
        bucket.cacheReadTokens += sample.cacheReadTokens
        bucket.cacheWriteTokens += sample.cacheWriteTokens
        bucket.totalTokens += total
        bucket.requestCount += 1
        byKey[key] = bucket
    }
}
