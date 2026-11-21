import Foundation
import GRDB

// 落库 store + IO 接缝 + 编排器——自 AgentUsageModel 拆出(solid-split,纯搬运)。

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

    // MARK: 项目轨(agent-tab/04)

    /// 项目行覆盖写(主键 (day, source, project) 冲突即替换)。
    public func upsertProjects(_ rows: [AgentProjectUsageRow]) throws {
        guard !rows.isEmpty else { return }
        try database.write { db in
            for row in rows {
                try row.save(db)
            }
        }
    }

    /// 全部项目行(按天升序;UI 按窗口聚合用)。
    public func projectRows() throws -> [AgentProjectUsageRow] {
        try database.read { db in
            try AgentProjectUsageRow
                .order(sql: "day ASC, source ASC, project ASC")
                .fetchAll(db)
        }
    }

    // MARK: 模型轨(agent-tab/05)

    /// 模型行覆盖写(主键 (day, source, project, model) 冲突即替换)。
    public func upsertModels(_ rows: [AgentModelUsageRow]) throws {
        guard !rows.isEmpty else { return }
        try database.write { db in
            for row in rows {
                try row.save(db)
            }
        }
    }

    /// 全部模型行(按天升序;UI 按窗口聚合用)。
    public func modelRows() throws -> [AgentModelUsageRow] {
        try database.read { db in
            try AgentModelUsageRow
                .order(sql: "day ASC, source ASC, project ASC, model ASC")
                .fetchAll(db)
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

    /// Claude 会话文件库存(stat 不打开):`~/.claude/projects/` 下全部 jsonl。
    /// `key` = `<slug>/<sessionId>.jsonl`(项目归组从 slug 反解,agent-tab/04)。
    func claudeFileInventory() -> [ClaudeFileRef]

    /// 增量读一个文件(agent-tab/12):检查点 nil = 从 0 全量;有检查点先校验
    /// 前缀哈希(只读不解析),失配/变小返回 `.rewritten`(调用方清 seen 后
    /// 以 nil 检查点重读)。consume 只喂**完整行**(含换行才算消费;无换行
    /// 尾巴留在未消费区下轮重读),同步逐行、非逃逸。
    func readClaudeFileIncremental(
        _ file: ClaudeFileRef,
        checkpoint: (offset: UInt64, prefixSha256: Data)?,
        consume: (_ line: String) -> Void
    ) -> ClaudeFileReadOutcome

    /// `~/.claude/stats-cache.json` 内容;缺失返回 nil。
    func claudeStatsCacheData() -> Data?

    /// 现存会话数按归组键(agent-tab/06):Claude 键 = projects 子目录 slug、
    /// 值 = 该目录下会话 jsonl 文件数(≈近 30 天未删);ZCode 键 = workspace
    /// 真路径、值 = db 中该工作区的不同 session_id 数(有账全史;被 purge 的
    /// 数不到)。合成项目计数走 `AgentUsageWindow.sessionCounts`。
    /// **必须是正式要求**(2026-11-19 实锤:只放扩展时,`any AgentUsageReading`
    /// 调用静态绑定默认空实现,真实现上线即死,全项目恒 0);默认空值在扩展里,
    /// 假实现与 Inert 桩免改。
    func agentSessionCounts() -> (claude: [String: Int], zcode: [String: Int])
}

public extension AgentUsageReading {
    /// 上条的默认实现 = 能力缺席(空计数);假实现与 Inert 桩免改。
    func agentSessionCounts() -> (claude: [String: Int], zcode: [String: Int]) {
        ([:], [:])
    }
}

// MARK: - 编排器

//
// 双档编排自 agent-tab/12 起由 `AgentUsageScan`(AgentIncrementalModel.swift)
// 承担:Claude 走检查点增量 + Σ 落账,ZCode 原路径合入,stats-cache 回填
// 全量档保留。旧 `AgentUsageCatalog`(每轮全量重读)已删。
