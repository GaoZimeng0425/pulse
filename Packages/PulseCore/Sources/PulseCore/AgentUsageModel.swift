import Foundation
import GRDB

// 每日 token 账本域模型与样本(agent-tab/02;solid-split 后本文件只留模型层)。

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
    /// 会话工作区真路径(session 表 directory/path;legacy schema 无 join 为 nil,
    /// 该行只进合计轨不进项目轨)。agent-tab/04。
    public var workspacePath: String?
    /// 模型标识(model_usage.model_id,如 "GLM-5.3";老 schema 列缺为 nil,
    /// 该行不进模型轨)。agent-tab/05。
    public var modelId: String?

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
        computedTotalTokens: Int? = nil,
        workspacePath: String? = nil,
        modelId: String? = nil
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
        self.workspacePath = workspacePath
        self.modelId = modelId
    }
}

// MARK: - 工作区归组(agent-tab/04)

/// 路径 → 项目名,worktree 归组主仓(tokscale `--merge-worktrees` 同思路,纯
/// 路径推导零 IO):含 `/.worktrees/<slug>` 段或 `/.git/worktrees/<name>` 段的,
/// 项目 = 该段**前一路径段**(`/Users/x/pulse/.worktrees/agent-usage` → `pulse`);
/// 其余取末段 basename。Claude slug 与 ZCode 真路径统一走「已切好的段数组」
/// 核心(slug 的 "-" 切分同样产生字面 `.worktrees` 段——"." 开头无歧义)。
public enum AgentWorkspaceResolution {
    /// 核心规则:段数组里找 `.worktrees` 字面段,或 `.git` 紧跟 `worktrees`
    /// 的段对;命中取前一段,否则末段。空/退化输入返回 nil(调用方放弃项目轨)。
    public static func projectName(components: [String]) -> String? {
        guard let last = components.last, !last.isEmpty else { return nil }
        if let worktrees = components.firstIndex(of: ".worktrees"), worktrees > 0 {
            let project = components[worktrees - 1]
            if !project.isEmpty {
                return project
            }
        }
        if let git = components.firstIndex(of: ".git"),
           components.indices.contains(git + 1), components[git + 1] == "worktrees",
           git > 0 {
            let project = components[git - 1]
            if !project.isEmpty {
                return project
            }
        }
        return last
    }

    /// 真路径(`/` 切分;ZCode workspace、任意 cwd)。
    public static func projectName(fromPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        return projectName(components: components)
    }

    /// Claude projects 目录的 slug(cwd 的 "/"→"-";`-` 切分)。
    /// 项目名含 "-" 时末段才逐字保真,worktree 归组不受影响(`.worktrees` 字面
    /// 段以 "." 开头,slug 切分不歧义)。
    public static func projectName(fromSlug slug: String) -> String? {
        let components = slug.split(separator: "-").map(String.init)
        return projectName(components: components)
    }

    /// 相对路径 `<slug>/<sessionId>.jsonl` 的 slug 段(项目归组输入)。
    public static func slug(fromRelativePath path: String) -> String? {
        guard let first = path.split(separator: "/").first, !first.isEmpty else { return nil }
        return String(first)
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
    /// 行内真实工作目录(实测 assistant 行 100% 带;项目归组首选,含 - 的
    /// 项目名保真。agent-tab/04)。
    public var cwd: String?
    /// 模型标识(message.model,如 "claude-opus-5-5";实测带 usage 的 assistant
    /// 行 100% 带,缺失为 nil 不进模型轨。agent-tab/05)。
    public var model: String?

    public init(
        timestampMs: Int64,
        messageId: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cwd: String? = nil,
        model: String? = nil
    ) {
        self.timestampMs = timestampMs
        self.messageId = messageId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cwd = cwd
        self.model = model
    }
}

/// 每日账本的**项目轨**行:一天 × 来源 × 项目一行,主键 `(day, source, project)`。
/// 与合计表 `agent_daily_usage` 平行(同一次扫描双轨产出);stats-cache 回填无
/// 项目维度,不进本表。展示只用 total / requests,五桶留作对称排查。
public struct AgentProjectUsageRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent_daily_project_usage"

    public var day: String
    public var source: AgentUsageSource
    /// 归组后的项目名(worktree 已折回主仓名)。
    public var project: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var totalTokens: Int
    public var requestCount: Int
    public var scannedAt: Int64

    /// 表列蛇形,映射集中一处(同 AgentDailyUsageRow 惯例)。
    enum CodingKeys: String, CodingKey {
        case day
        case source
        case project
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
        project: String,
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
        self.project = project
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

/// 每日账本的**模型轨**行:一天 × 来源 × 项目 × 模型一行,主键
/// `(day, source, project, model)`(agent-tab/05)。挂在项目轨之下(项目卡内的
/// 模型分段条数据源);模型标识缺失(Claude 老行无 message.model / ZCode 老
/// schema 无 model_id)不进本表,五桶留作对称排查同前两表。
public struct AgentModelUsageRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent_daily_model_usage"

    public var day: String
    public var source: AgentUsageSource
    public var project: String
    /// 模型标识原样串(Claude "claude-opus-5-5" / ZCode "GLM-5.3";显示层剥前缀)。
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var totalTokens: Int
    public var requestCount: Int
    public var scannedAt: Int64

    /// 表列蛇形,映射集中一处(同 AgentDailyUsageRow 惯例)。
    enum CodingKeys: String, CodingKey {
        case day
        case source
        case project
        case model
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
        project: String,
        model: String,
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
        self.project = project
        self.model = model
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
