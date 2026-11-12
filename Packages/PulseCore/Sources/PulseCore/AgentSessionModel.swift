import Foundation

// AI 助手会话监视的纯逻辑(智能体 tab,工单 agent-tab/01):Claude Code 实例注册表、
// 会话 jsonl 尾读、用量限额快照、ZCode 子代理 metadata 的解析与编排。文件 IO 适配器
// 在 app target(AgentSessionReader.swift);本文件只吃 Data 与注入时刻,单测全合成夹具。

// MARK: - Claude Code 实例注册表(~/.claude/sessions/<pid>.json)

/// 注册表一条:Claude Code 每个活跃实例自报的状态(pid / 会话 / 工作目录 / 状态串)。
public struct ClaudeInstanceEntry: Equatable, Sendable {
    public let pid: pid_t
    public let sessionId: String
    public let cwd: String
    /// 会话启动时刻(Claude 写毫秒 Unix 纪元)。
    public let startedAt: Date?
    /// 实例自报名(如 "octok-client-0e";nameSource=derived 时也可用)。
    public let name: String?
    /// 实例状态原样串:实测 busy / idle / waiting / shell;未知值透传不猜。
    public let status: String?

    public init(
        pid: pid_t,
        sessionId: String,
        cwd: String,
        startedAt: Date?,
        name: String? = nil,
        status: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.name = name
        self.status = status
    }
}

/// 注册表 JSON 解析(单条文件内容;字段缺失/畸形返回 nil,不猜)。
public enum ClaudeSessionRegistry {
    private struct Record: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let startedAt: Double?
        let name: String?
        let status: String?
    }

    public static func parse(_ data: Data) -> ClaudeInstanceEntry? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return ClaudeInstanceEntry(
            pid: record.pid,
            sessionId: record.sessionId,
            cwd: record.cwd,
            startedAt: record.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            name: record.name,
            status: record.status
        )
    }
}

// MARK: - 会话 jsonl 尾读(projects/<slug>/<sessionId>.jsonl 的末条 assistant usage)

/// 尾读产物:末条 assistant 请求的模型与上下文占用。
public struct ClaudeContextReading: Equatable, Sendable {
    /// 模型名(如 "claude-opus-5-5")。
    public let model: String?
    /// 当前上下文占用 token 数,口径同 abtop:input + cache_read;会话首建缓存
    /// (cache_read 为 0 且 cache_creation > 0)时 input + cache_creation。
    /// cache_creation 不计入常态上下文(它是写缓存的旁路开销,abtop #54 同口径)。
    public let contextTokens: Int?
    public let timestamp: Date?
}

/// jsonl 尾部字节解析:从尾往前找第一条带 usage 的 assistant 记录。
/// 容错:首行半行(尾读从字节中间起)解析失败自然丢弃;全无 → nil(新会话未发首条)。
public enum ClaudeTranscriptTail {
    public static func parse(_ data: Data) -> ClaudeContextReading? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let record = object as? [String: Any],
                record["type"] as? String == "assistant"
            else { continue }
            let message = record["message"] as? [String: Any]
            let usage = message?["usage"] as? [String: Any]
            guard let usage else { continue }
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let contextTokens: Int = if cacheRead == 0, cacheCreation > 0 {
                input + cacheCreation
            } else {
                input + cacheRead
            }
            return ClaudeContextReading(
                model: message?["model"] as? String,
                contextTokens: contextTokens,
                timestamp: (record["timestamp"] as? String).flatMap(AgentISO8601.parse)
            )
        }
        return nil
    }
}

/// 上下文窗口上限口径(二档,abtop 同款):模型名带 "[1m]" 或当前上下文已越过
/// 200k(能跑到 200k 以上还没压缩的只可能是 1M 档会话)→ 1M;否则 200k。
public enum ClaudeContextWindow {
    public static let standard = 200_000
    public static let extended = 1_000_000

    public static func limit(model: String?, contextTokens: Int) -> Int {
        if let model, model.lowercased().contains("[1m]") {
            return extended
        }
        return contextTokens > standard ? extended : standard
    }
}

// MARK: - 用量限额快照(~/.claude/usage-snapshot.json)

/// 订阅用量快照:5 小时窗 / 7 天窗各自已用百分比与重置时刻(账户级,非单实例)。
public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 已用百分比(整数,快照原样)。
        public let usedPercentage: Int
        public let resetsAt: Date?

        public init(usedPercentage: Int, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?

    public init(fiveHour: Window?, sevenDay: Window?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// 快照里两窗全缺 → nil(读不到如实空态,不出 0%)。
    public static func parse(_ data: Data) -> ClaudeUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let fiveHour = window(object["five_hour"])
        let sevenDay = window(object["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeUsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ value: Any?) -> Window? {
        guard let dict = value as? [String: Any], let percent = dict["used_percentage"] as? Int else {
            return nil
        }
        return Window(
            usedPercentage: percent,
            resetsAt: (dict["resets_at"] as? String).flatMap(AgentISO8601.parse)
        )
    }
}

// MARK: - ZCode 子代理 metadata(~/.zcode/cli/agents/sess_*/agent_*/metadata.json)

/// 单个(子)agent 的自报状态。
public struct ZCodeAgentMeta: Equatable, Sendable {
    /// 状态原样串:实测 completed;运行期值未知 → 透传,活跃判定见 `isActive`。
    public let status: String?
    public let updatedAt: Date?
    public let workspaceRoot: String?
    /// 代理画像名(Explore / flash / …)。
    public let profile: String?
    /// 该 agent 全程 token 数(metadata 自报,无需碰 db.sqlite)。
    public let totalTokens: Int?

    /// 活跃 = 状态不是已知终态(completed / failed / cancelled / error)。
    /// 未知状态按活跃计:近窗内还在更新 metadata 的 agent,未知态更可能是运行中。
    public var isActive: Bool {
        let terminal: Set = ["completed", "failed", "cancelled", "error"]
        return terminal.contains(status?.lowercased() ?? "") == false
    }

    public init(
        status: String?,
        updatedAt: Date?,
        workspaceRoot: String?,
        profile: String?,
        totalTokens: Int?
    ) {
        self.status = status
        self.updatedAt = updatedAt
        self.workspaceRoot = workspaceRoot
        self.profile = profile
        self.totalTokens = totalTokens
    }
}

/// metadata.json 解析(畸形返回 nil)。
public enum ZCodeAgentMetadata {
    private struct Record: Decodable {
        let status: String?
        let updatedAt: String?
        let workspaceRoot: String?
        let profileId: String?
        let totalTokens: Int?
    }

    public static func parse(_ data: Data) -> ZCodeAgentMeta? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return ZCodeAgentMeta(
            status: record.status,
            updatedAt: record.updatedAt.flatMap(AgentISO8601.parse),
            workspaceRoot: record.workspaceRoot,
            profile: record.profileId,
            totalTokens: record.totalTokens
        )
    }
}

// MARK: - 卡片行模型

/// Claude Code 会话一行(实体行):项目 / 状态 / 模型 / 时长 / 上下文 / 子代理数。
public struct ClaudeAgentSessionStatus: Identifiable, Equatable, Sendable {
    public let pid: pid_t
    public let sessionId: String
    /// 行名 = 工作目录 basename。
    public let projectName: String
    public let cwd: String
    public let status: String?
    /// 实例已运行秒数(注册表 startedAt 至本轮时刻;缺 startedAt 为 nil)。
    public let ageSeconds: TimeInterval?
    public let model: String?
    /// 上下文占用 token;nil = 尾读无可用记录(新会话未发首条)。
    public let contextTokens: Int?
    /// 上下文窗口上限(contextTokens 为 nil 时同为 nil)。
    public let contextLimit: Int?
    /// 会话目录下子代理计数(subagents/agent-*.jsonl)。
    public let subagentCount: Int

    public var id: pid_t {
        pid
    }

    /// 状态的人读名:已知态给中文,未知值原样透传(不猜)。
    public var statusLabel: String? {
        switch status?.lowercased() {
        case nil: nil
        case "busy": "忙"
        case "idle": "空闲"
        case "waiting": "等待"
        case "shell": "Shell"
        case let raw?: raw
        }
    }

    /// 上下文占用比(0…1 钳位);读数或上限缺失为 nil。
    public var contextFraction: Double? {
        guard let contextTokens, let contextLimit, contextLimit > 0 else { return nil }
        return Swift.min(Swift.max(Double(contextTokens) / Double(contextLimit), 0), 1)
    }

    public init(
        pid: pid_t,
        sessionId: String,
        projectName: String,
        cwd: String,
        status: String?,
        ageSeconds: TimeInterval?,
        model: String?,
        contextTokens: Int?,
        contextLimit: Int?,
        subagentCount: Int
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.projectName = projectName
        self.cwd = cwd
        self.status = status
        self.ageSeconds = ageSeconds
        self.model = model
        self.contextTokens = contextTokens
        self.contextLimit = contextLimit
        self.subagentCount = subagentCount
    }
}

/// ZCode 会话一行:按 sess_* 聚合其(子)agent。
public struct ZCodeSessionStatus: Identifiable, Equatable, Sendable {
    /// "sess_<uuid>"(含前缀,即目录名)。
    public let sessionId: String
    /// 工作区 basename(取该会话 agents 的 workspaceRoot;混合时取最新一条的)。
    public let workspaceName: String?
    /// 活跃(非终态)agent 数 / 全部 agent 数。
    public let activeAgents: Int
    public let totalAgents: Int
    /// 会话内全部 agent 的 token 合计;全部缺失为 nil(不出 0 误导)。
    public let totalTokens: Int?
    /// 最近一次 agent 更新距今秒数。
    public let updatedAgoSeconds: TimeInterval?

    public var id: String {
        sessionId
    }

    public init(
        sessionId: String,
        workspaceName: String?,
        activeAgents: Int,
        totalAgents: Int,
        totalTokens: Int?,
        updatedAgoSeconds: TimeInterval?
    ) {
        self.sessionId = sessionId
        self.workspaceName = workspaceName
        self.activeAgents = activeAgents
        self.totalAgents = totalAgents
        self.totalTokens = totalTokens
        self.updatedAgoSeconds = updatedAgoSeconds
    }
}

/// 一轮聚合(功能模块发布态):Claude 实例表 / 用量限额 / ZCode 会话表。
public struct AgentSnapshot: Equatable, Sendable {
    public let claudeSessions: [ClaudeAgentSessionStatus]
    public let usage: ClaudeUsageSnapshot?
    public let zcodeSessions: [ZCodeSessionStatus]

    public static let empty = AgentSnapshot(claudeSessions: [], usage: nil, zcodeSessions: [])

    public init(
        claudeSessions: [ClaudeAgentSessionStatus],
        usage: ClaudeUsageSnapshot?,
        zcodeSessions: [ZCodeSessionStatus]
    ) {
        self.claudeSessions = claudeSessions
        self.usage = usage
        self.zcodeSessions = zcodeSessions
    }
}

// MARK: - IO 接缝(Live 实现在 app target;单测注入假实现)

public protocol AgentSessionReading: Sendable {
    /// `~/.claude/sessions/` 下全部注册表文件内容(仅 `<pid>.json`;顺序任意)。
    func claudeRegistryFiles() -> [Data]
    /// `~/.claude/usage-snapshot.json` 内容;缺失/不可读返回 nil。
    func claudeUsageSnapshotFile() -> Data?
    /// 会话 jsonl 的尾部字节(约末 128KB,可含首半行);文件不存在返回 nil。
    /// Live 侧由 cwd 推 projects/<slug> 目录(slug = cwd 的 "/"→"-"),失配回退目录扫描。
    func claudeTranscriptTail(cwd: String, sessionId: String) -> Data?
    /// 会话目录 `subagents/` 下 agent 文件计数;目录不存在返回 0。
    func claudeSubagentCount(cwd: String, sessionId: String) -> Int
    /// `~/.zcode/cli/agents/` 下近 `lookback` 秒有更新的会话的 metadata 文件
    /// (session 名 + 文件内容;会话数与每会话 agent 数由实现按上限封顶)。
    func zcodeAgentMetadataFiles(lookback: TimeInterval, now: Date) -> [(session: String, data: Data)]
}

// MARK: - 编排器

/// 盘点编排:IO 节流刷新 + 每轮 pid 存活过滤。
/// - 文件读全套按 `refreshInterval` 节流(弹窗 1s 档不放大 IO;默认 5s);
/// - 两轮刷新之间不再碰文件:每轮只用心跳快照的 pid 集合过滤缓存读数并重算时长——
///   实例退出 ≤1 轮内下榜;新实例要等下一轮刷新才上榜(注册表是 Claude 写的,
///   追新不如追退急);
/// - ZCode 会话只看 `zcodeLookback` 窗内有更新的,读数上限封顶防目录膨胀。
public struct AgentSessionCatalog: Sendable {
    public static let zcodeLookback: TimeInterval = 24 * 3600
    public static let maxZCodeSessions = 12
    public static let maxZCodeAgentsPerSession = 30

    /// 一次刷新时连同实例一起读下的会话级读数(节流轮复用,不再 IO)。
    private struct ClaudeReading: Sendable {
        let entry: ClaudeInstanceEntry
        let tail: ClaudeContextReading?
        let subagentCount: Int
    }

    private let refreshInterval: TimeInterval
    private var lastRefreshAt: Date?
    private var cachedClaude: [ClaudeReading] = []
    private var cachedUsage: ClaudeUsageSnapshot?
    private var cachedZCode: [ZCodeSessionStatus] = []

    public init(refreshInterval: TimeInterval = 5) {
        self.refreshInterval = refreshInterval
    }

    /// 推进一轮:返回当前聚合快照(读数未变也会重算时长,身份比较交给上层)。
    public mutating func update(
        reader: any AgentSessionReading,
        alivePids: Set<pid_t>,
        now: Date
    ) -> AgentSnapshot {
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < refreshInterval {
            // 节流轮:纯内存——过滤存活 + 重算时长,限额与 ZCode 沿用缓存。
            return AgentSnapshot(
                claudeSessions: claudeRows(alivePids: alivePids, now: now),
                usage: cachedUsage,
                zcodeSessions: cachedZCode
            )
        }
        lastRefreshAt = now
        cachedClaude = reader.claudeRegistryFiles().compactMap(ClaudeSessionRegistry.parse).map { entry in
            ClaudeReading(
                entry: entry,
                tail: reader.claudeTranscriptTail(cwd: entry.cwd, sessionId: entry.sessionId)
                    .flatMap(ClaudeTranscriptTail.parse),
                subagentCount: reader.claudeSubagentCount(cwd: entry.cwd, sessionId: entry.sessionId)
            )
        }
        cachedUsage = reader.claudeUsageSnapshotFile().flatMap(ClaudeUsageSnapshot.parse)
        cachedZCode = zcodeRows(reader: reader, now: now)
        return AgentSnapshot(
            claudeSessions: claudeRows(alivePids: alivePids, now: now),
            usage: cachedUsage,
            zcodeSessions: cachedZCode
        )
    }

    /// Claude 行:缓存读数按 pid 存活过滤,最新启动在前。
    private func claudeRows(alivePids: Set<pid_t>, now: Date) -> [ClaudeAgentSessionStatus] {
        cachedClaude
            .filter { alivePids.contains($0.entry.pid) }
            .sorted { ($0.entry.startedAt ?? .distantPast) > ($1.entry.startedAt ?? .distantPast) }
            .map { reading in
                ClaudeAgentSessionStatus(
                    pid: reading.entry.pid,
                    sessionId: reading.entry.sessionId,
                    projectName: (reading.entry.cwd as NSString).lastPathComponent,
                    cwd: reading.entry.cwd,
                    status: reading.entry.status,
                    ageSeconds: reading.entry.startedAt.map { now.timeIntervalSince($0) },
                    model: reading.tail?.model,
                    contextTokens: reading.tail?.contextTokens,
                    contextLimit: reading.tail?.contextTokens.map {
                        ClaudeContextWindow.limit(model: reading.tail?.model, contextTokens: $0)
                    },
                    subagentCount: reading.subagentCount
                )
            }
    }

    /// ZCode 行:metadata 按 session 聚合——每会话 agent 数封顶(更新近的优先),
    /// 工作区取最新 agent 的,token 合计(全部缺失则 nil 不出 0),最近更新在前。
    private func zcodeRows(reader: any AgentSessionReading, now: Date) -> [ZCodeSessionStatus] {
        var bySession: [String: [ZCodeAgentMeta]] = [:]
        for file in reader.zcodeAgentMetadataFiles(lookback: Self.zcodeLookback, now: now) {
            guard let meta = ZCodeAgentMetadata.parse(file.data) else { continue }
            bySession[file.session, default: []].append(meta)
        }
        return bySession
            .map { session, agents -> ZCodeSessionStatus in
                let capped = agents
                    .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                    .prefix(Self.maxZCodeAgentsPerSession)
                let latest = capped.first
                let tokenReadings = capped.compactMap(\.totalTokens)
                return ZCodeSessionStatus(
                    sessionId: session,
                    workspaceName: latest?.workspaceRoot.map { ($0 as NSString).lastPathComponent },
                    activeAgents: capped.filter(\.isActive).count,
                    totalAgents: capped.count,
                    totalTokens: tokenReadings.isEmpty ? nil : tokenReadings.reduce(0, +),
                    updatedAgoSeconds: latest?.updatedAt.map { now.timeIntervalSince($0) }
                )
            }
            .sorted { ($0.updatedAgoSeconds ?? 0) < ($1.updatedAgoSeconds ?? 0) }
            .prefix(Self.maxZCodeSessions)
            .map(\.self)
    }
}

/// ISO8601 宽容解析:带/不带毫秒的 "2026-11-12T07:55:23.231Z"。formatter 为局部
/// 变量(每 5s 一轮、每轮个位数条,不值得缓存;也避开静态非 Sendable 态)。
enum AgentISO8601 {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }
}
