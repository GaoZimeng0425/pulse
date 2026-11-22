import Foundation
import GRDB

// MCP 自查账本(工单 mcp-self-usage/01):AI 会话内一问,答「当前会话 + 今天 +
// 近 7 天」的 token 用量。查询层与口径归一住这里(InsightQuery 同款:SQL 进
// PulseCore、带 Database 参数可测);文本拼装在 pulse-mcp。口径铁律:一律报
// **互斥五桶**(ZCode 源列 input 已含缓存两桶、output 已含 reasoning,直接
// 加总虚高——ZCodeTokenNormalization 归一后才可入账,票面事实档记档)。

/// ZCode 用量库(~/.zcode/cli/db/db.sqlite)的外部只读连接(mcp-self-usage/01):
/// HistoryDatabase.openReader 同款纪律——存在才开、绝不创建,PRAGMA query_only
/// 硬保证只读(WAL -shm 需可创建,故不用 SQLite readonly 模式),busy 超时
/// 3s 同 app 侧 AgentUsageReader 口径。
public enum ZCodeUsageDatabase {
    public static func openReader() throws -> DatabaseQueue? {
        let path = NSHomeDirectory() + "/.zcode/cli/db/db.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var configuration = Configuration()
        configuration.busyMode = .timeout(3)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")
        }
        return try DatabaseQueue(path: path, configuration: configuration)
    }
}

public enum AgentUsageInsightQuery {
    // MARK: - 模型

    /// 互斥五桶读数(账本口径;合计 = 五桶相加)。
    public struct Buckets: Equatable, Sendable {
        /// 净输入(ZCode 源 input 已含缓存,入账前已扣)。
        public var inputTokens = 0
        /// 净输出(不含已单列的推理)。
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheWriteTokens = 0
        public var reasoningTokens = 0
        public var requestCount = 0

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
        }

        public init() {}

        public static let empty = Buckets()

        public mutating func add(_ other: Buckets) {
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            cacheReadTokens += other.cacheReadTokens
            cacheWriteTokens += other.cacheWriteTokens
            reasoningTokens += other.reasoningTokens
            requestCount += other.requestCount
        }
    }

    /// 一个窗口(今天 / 近 N 天)的全机用量:合计 + 按来源拆。
    public struct WindowUsage: Equatable, Sendable {
        public struct Source: Equatable, Sendable {
            public let name: String
            public let buckets: Buckets

            public init(name: String, buckets: Buckets) {
                self.name = name
                self.buckets = buckets
            }
        }

        public let buckets: Buckets
        /// 份额降序;账本行只有 zcode / claude 两来源。
        public let sources: [Source]

        public init(buckets: Buckets, sources: [Source]) {
            self.buckets = buckets
            self.sources = sources
        }
    }

    /// 一个会话的用量(任一 harness)。
    public struct SessionUsage: Equatable, Sendable {
        /// "ZCode" / "Claude"。
        public let harness: String
        /// 显示短号(sess_ 去前缀 8 位 / 文件名 8 位)。
        public let sessionID: String
        public let buckets: Buckets
        public let lastActiveAt: Date?

        public init(harness: String, sessionID: String, buckets: Buckets, lastActiveAt: Date?) {
            self.harness = harness
            self.sessionID = sessionID
            self.buckets = buckets
            self.lastActiveAt = lastActiveAt
        }
    }

    /// 会话择取(拍板③:识别不猜):同工作区候选里最近活跃者主报,其余如实
    /// 列表——同工作区并发多会话时,调用方看得见全部候选自己判断。
    public struct SessionPick: Equatable, Sendable {
        public let primary: SessionUsage?
        public let others: [SessionUsage]

        public static func pick(_ sessions: [SessionUsage], othersLimit: Int = 3) -> SessionPick {
            let ordered = sessions.sorted {
                ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
            }
            guard let first = ordered.first else {
                return SessionPick(primary: nil, others: [])
            }
            return SessionPick(primary: first, others: Array(ordered.dropFirst().prefix(othersLimit)))
        }
    }

    /// 本地时区 "yyyy-MM-dd"(账本 day 列口径;聚合时区同源)。locale 钉
    /// en_US_POSIX 与账本写侧(AgentUsageAggregation)同款——系统日历非公历的
    /// 用户否则会写出对不上的 day 键,窗口 SQL 永远空匹配(评审 P2)。
    public static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 窗口(账本库)

    /// 账本日用量表按来源聚合:day ∈ [fromDay, throughDay] 闭区间;空表返回
    /// 零窗(如实,不编数)。
    public static func windowUsage(
        fromDay: String,
        throughDay: String,
        in db: Database
    ) throws -> WindowUsage {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT source,
                   SUM(input_tokens) AS input,
                   SUM(output_tokens) AS output,
                   SUM(cache_read_tokens) AS cache_read,
                   SUM(cache_write_tokens) AS cache_write,
                   SUM(reasoning_tokens) AS reasoning,
                   SUM(request_count) AS requests
            FROM agent_daily_model_usage
            WHERE day >= ? AND day <= ?
            GROUP BY source
            """,
            arguments: [fromDay, throughDay]
        )
        var total = Buckets.empty
        var sources: [WindowUsage.Source] = []
        for row in rows {
            var buckets = Buckets.empty
            buckets.inputTokens = row["input"] ?? 0
            buckets.outputTokens = row["output"] ?? 0
            buckets.cacheReadTokens = row["cache_read"] ?? 0
            buckets.cacheWriteTokens = row["cache_write"] ?? 0
            buckets.reasoningTokens = row["reasoning"] ?? 0
            buckets.requestCount = row["requests"] ?? 0
            total.add(buckets)
            sources.append(WindowUsage.Source(name: row["source"] ?? "?", buckets: buckets))
        }
        sources.sort { $0.buckets.totalTokens > $1.buckets.totalTokens }
        return WindowUsage(buckets: total, sources: sources)
    }

    // MARK: - ZCode 会话(用量库 ~/.zcode/cli/db/db.sqlite,只读)

    /// 工作区匹配(会话 directory 或 path)且 started_at ≥ lookback 前的会话,
    /// 逐请求行归一化(computed_total 形状探测)后按会话聚合。行量级 = 单会话
    /// 请求数(几十到几百),全量取回逐行算,不做 SQL 聚合——形状探测是行级
    /// 判定,聚合后减会算错(tokscale 五桶非互斥教训)。
    public static func zcodeSessions(
        workspace: String,
        lookback: TimeInterval,
        now: Date,
        in db: Database
    ) throws -> [SessionUsage] {
        let sinceMs = Int64((now.timeIntervalSince1970 - lookback) * 1000)
        // 列探测降级(照 app 侧 AgentUsageReader 先例,评审 P2):旧库无
        // computed_total_tokens 时该列引用直接 no such column 抛错——不探测会把
        // 「查询失败」伪装成「无记录」(读失败不得冒充读数)。legacy 分支去掉
        // 该列,归一化走「无条件减」旧规则。
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(model_usage)")
        let hasComputedTotal = columns.contains { ($0["name"] as String?) == "computed_total_tokens" }
        let query = """
        SELECT model_usage.session_id AS sid,
               model_usage.input_tokens AS raw_input,
               model_usage.output_tokens AS raw_output,
               model_usage.cache_read_input_tokens AS raw_cache_read,
               model_usage.cache_creation_input_tokens AS raw_cache_write,
               model_usage.reasoning_tokens AS raw_reasoning,
               \(hasComputedTotal ? "model_usage.computed_total_tokens" : "NULL") AS computed_total,
               model_usage.started_at AS started_at
        FROM model_usage
        LEFT JOIN session AS s ON s.id = model_usage.session_id
        WHERE model_usage.started_at >= ?
          AND (s.directory = ? OR s.path = ?)
        ORDER BY model_usage.started_at
        """
        let rows = try Row.fetchAll(db, sql: query, arguments: [sinceMs, workspace, workspace])
        var bySession: [String: (buckets: Buckets, lastActive: Date?)] = [:]
        for row in rows {
            let normalized = ZCodeTokenNormalization.normalize(
                input: row["raw_input"],
                output: row["raw_output"],
                cacheRead: row["raw_cache_read"],
                cacheWrite: row["raw_cache_write"],
                reasoning: row["raw_reasoning"],
                computedTotal: row["computed_total"],
                legacySchema: !hasComputedTotal
            )
            let sid: String = row["sid"] ?? ""
            var entry = bySession[sid] ?? (buckets: Buckets.empty, lastActive: nil)
            entry.buckets.inputTokens += normalized.netInput
            entry.buckets.outputTokens += normalized.netOutput
            entry.buckets.cacheReadTokens += normalized.cacheRead
            entry.buckets.cacheWriteTokens += normalized.cacheWrite
            entry.buckets.reasoningTokens += normalized.reasoning
            entry.buckets.requestCount += 1
            if let startedMs: Int64 = row["started_at"] {
                let started = Date(timeIntervalSince1970: Double(startedMs) / 1000)
                if started > (entry.lastActive ?? .distantPast) {
                    entry.lastActive = started
                }
            }
            bySession[sid] = entry
        }
        return bySession.map { sid, entry in
            SessionUsage(
                harness: "ZCode",
                sessionID: String(sid.dropFirst("sess_".count).prefix(8)),
                buckets: entry.buckets,
                lastActiveAt: entry.lastActive
            )
        }
    }

    // MARK: - Claude 会话(文件行聚合;文件 IO 在调用方)

    /// Claude 会话文件聚合结果。
    public struct ClaudeFileSum: Equatable, Sendable {
        public let buckets: Buckets
        /// 末条 assistant 样本时间锚(缺时间戳的行不计入)。
        public let latestAt: Date?

        public init(buckets: Buckets, latestAt: Date?) {
            self.buckets = buckets
            self.latestAt = latestAt
        }
    }

    /// 一个会话 jsonl 的全部行 → 互斥五桶(Claude 源天然互斥,reasoning 恒 0;
    /// 按 message.id 文件内去重——resume/compact 复制历史不双计,parser 同款)。
    public static func sumClaudeLines(_ lines: [String]) -> ClaudeFileSum {
        var buckets = Buckets.empty
        var seenMessageIDs: Set<String> = []
        var latestAt: Date?
        for line in lines {
            guard let sample = ClaudeTranscriptUsageParser.parse(line: line) else { continue }
            if let id = sample.messageId {
                guard seenMessageIDs.insert(id).inserted else { continue }
            }
            buckets.inputTokens += sample.inputTokens
            buckets.outputTokens += sample.outputTokens
            buckets.cacheReadTokens += sample.cacheReadTokens
            buckets.cacheWriteTokens += sample.cacheWriteTokens
            buckets.requestCount += 1
            let at = Date(timeIntervalSince1970: Double(sample.timestampMs) / 1000)
            latestAt = max(latestAt ?? .distantPast, at)
        }
        return ClaudeFileSum(buckets: buckets, latestAt: latestAt)
    }
}
