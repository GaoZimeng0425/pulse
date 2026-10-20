import Foundation
import GRDB

/// 出生登记行(lineage 表的读回形状):读回即可重建 `LineageRegistry.Entry`。
/// argv 以 JSON 数组序列化(参数可含任意空白);写侧用同一份编码。
struct LineageRow: Decodable, FetchableRecord, TableRecord {
    static let databaseTableName = "lineage"

    let pid: Int64
    let parentPID: Int64
    let executablePath: String?
    let cwd: String?
    let argv: String?
    let firstSeen: Double

    enum CodingKeys: String, CodingKey {
        case pid, cwd, argv
        case parentPID = "parent_pid"
        case executablePath = "executable_path"
        case firstSeen = "first_seen"
    }

    /// 内存登记表条目;argv 解码失败按空(登记字段本就可缺失,不伪造)。
    var entry: LineageRegistry.Entry {
        let arguments = argv
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return LineageRegistry.Entry(
            parentPID: pid_t(parentPID),
            identity: ProcessIdentity(executablePath: executablePath, cwd: cwd, argv: arguments)
        )
    }

    static func argvJSON(_ argv: [String]) -> String {
        guard let data = try? JSONEncoder().encode(argv),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

/// 历史库健康状态沿(过渡非轮询的日志惯例,LogService 教训③):落库、累计查询与历史页
/// 查询共用一面旗——库坏时几处都会失败,第一处记进入边,其余静默;先恢复者记恢复边。
/// 持续失败若逐条记,5s 一轮会把日志刷满留存窗口。返回值 = 这一次要不要记日志。
struct HistoryHealthEdge {
    private(set) var healthy = true

    mutating func recordFailure() -> Bool {
        defer { healthy = false }
        return healthy
    }

    mutating func recordSuccess() -> Bool {
        defer { healthy = true }
        return !healthy
    }
}

/// 历史引擎(工单 03):采样落地 actor,把 5s 采样卷积进分钟表、按小时二次
/// 卷积进小时表、按当地日清理留存、增量持久化出生登记与组展示元数据。
///
/// - 时间全部显式传入(ingest 的采样时刻由调用方给注入时钟的读数)——
///   rollup、留存、小时卷积都可在单测里确定性驱动(Testing Decisions);
/// - 库为注入的真 SQLite(不设缝);所有写在一个事务里,失败只记日志,
///   历史是旁路,绝不拖垮实时页;
/// - 5s 原始值只活在 MinuteRollupBuffer(内存),永不落盘。
actor HistoryEngine {
    /// 库队列(nil = 库打开失败,历史整体缺席)。internal:写路径在本文件,
    /// 读入口(历史页查询,工单 04)在同模块 HistoryQueries.swift 的 extension。
    let database: DatabaseQueue?
    private let calendar: Calendar

    private var buffer = MinuteRollupBuffer()
    /// 小时卷积推进锚点(epoch 秒):该边界之前的所有小时已确保入小时表。
    /// nil = 尚未建立(建立时先补齐存量)。
    private var hourRollupBoundary: Int?
    /// 上次留存清理的当地日;nil = 本会话尚未清理(首次 ingest 触发)。
    private var lastRetentionDayStart: Date?
    /// 已确认在库的出生 pid:增量写,避免每轮全表重插。
    private var persistedLineagePIDs: Set<pid_t> = []
    /// 已持久化的组名(stableKey → name):改名才重写。
    private var persistedGroupNames: [String: String] = [:]
    /// 库健康状态沿(HistoryHealthEdge):落库、累计、历史页查询共用。
    private var health = HistoryHealthEdge()

    /// 构造:打开方负责给库(文件或内存)。只读回组名缓存(一张小表);存量小时补卷积
    /// 不在这里做——构造跑在调用方线程(app 启动时是主线程),补卷积由本会话首笔落库
    /// 在 actor 上完成,且只从小时表已有的最后一小时起卷(arch-review-2026-10-18/03 乙5)。
    /// `now` 保留给调用方兼容。
    /// init 是非隔离上下文:闭包内只动局部量,actor 状态在闭包外赋值。
    init(database: DatabaseQueue?, now: Date = Date(), calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
        guard let database else { return }
        do {
            persistedGroupNames = try database.read { db in try Self.persistedGroupNames(in: db) }
        } catch {
            LogService.error("历史库启动初始化失败:\(error)", category: "History")
        }
    }

    /// 小时表已有的最后一小时(无行为 0 = 从头卷;重卷它幂等):首笔落库补卷积的下界,
    /// 成本不随留存窗增长。
    private static func lastRolledHour(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM system_hour") ?? 0
    }

    /// 默认引擎:打开应用库;失败返回 nil(SystemMonitor 降级为无历史)。
    static func openDefault() -> HistoryEngine? {
        do {
            return HistoryEngine(database: try HistoryDatabase.open())
        } catch {
            LogService.error("历史库打开失败,历史管线停用:\(error)", category: "History")
            return nil
        }
    }

    // MARK: 采样进历史

    /// 一轮采样进历史(每轮采样调用,`now` = 该轮采样时刻):
    /// 5s 原始值进内存缓冲;跨分钟冲刷上一分钟为行;跨小时卷积完整小时;
    /// 跨当地日顺带留存清理;出生登记与组元数据增量落库——同一事务。
    /// `netRxBytes`/`netTxBytes` = 本轮网络记账增量(工单 06,差分丢弃轮为 0);
    /// `diskReadBytes`/`diskWriteBytes` = 本轮磁盘吞吐记账增量(差分丢弃轮
    /// 同为 0,与网络同口径)。返回本轮是否写了分钟行(跨分钟冲刷)——库里的累计
    /// 只在这时变,调用方据此决定要不要重查网络累计(乙7)。
    @discardableResult
    func ingest(
        at now: Date,
        systemLoad: Double,
        groups: [GroupSample],
        displayNames: [GroupIdentity: String],
        lineage: LineageRegistry,
        netRxBytes: UInt64 = 0,
        netTxBytes: UInt64 = 0,
        diskReadBytes: UInt64 = 0,
        diskWriteBytes: UInt64 = 0
    ) -> Bool {
        guard let database else { return false }
        var wroteMinute = false
        do {
            try database.write { db in
                if let aggregate = buffer.ingest(
                    at: now,
                    systemLoad: systemLoad,
                    groups: groups,
                    netRxBytes: netRxBytes,
                    netTxBytes: netTxBytes,
                    diskReadBytes: diskReadBytes,
                    diskWriteBytes: diskWriteBytes
                ) {
                    try Self.insertMinute(aggregate, in: db)
                    wroteMinute = true
                }

                let boundary = HistoryWindows.hourStartSeconds(of: now)
                if boundary > (hourRollupBoundary ?? Int.min) {
                    let lower = try hourRollupBoundary ?? Self.lastRolledHour(in: db)
                    try Self.rollupHours(from: lower, through: boundary, in: db)
                    hourRollupBoundary = boundary
                }

                if HistoryRetention.isDue(
                    lastRunDayStart: lastRetentionDayStart, now: now, calendar: calendar
                ) {
                    try Self.runRetention(now: now, in: db)
                    lastRetentionDayStart = calendar.startOfDay(for: now)
                }

                try persistLineage(lineage, seenAt: now, in: db)
                try persistGroupMetadata(displayNames, in: db)
            }
            noteDatabaseSuccess()
            return wroteMinute
        } catch {
            noteDatabaseFailure("历史落库失败", error)
            return false
        }
    }

    /// 状态沿恢复边:从失败态回到成功记一条(只在该边记,平时安静)。
    func noteDatabaseSuccess() {
        guard health.recordSuccess() else { return }
        LogService.info("历史库恢复", category: "History")
    }

    /// 状态沿进入边:健康 → 失败记一条,此后静默至恢复。
    func noteDatabaseFailure(_ what: String, _ error: Error) {
        guard health.recordFailure() else { return }
        LogService.error("\(what)(此后静默至恢复):\(error)", category: "History")
    }

    // MARK: 网络 Today/7 天累计(工单 06)

    /// Today/7 天网络累计(system_min/system_hour SQL 聚合,当地零点为日界):
    /// 已过小时边界前的分钟行在分钟表与小时表**各有一份**(小时卷积幂等保留
    /// 明细),查询按"当前小时边界前走小时表、边界后走分钟表"两段相加——
    /// 天真地对两表同窗求和会重复计数。库缺席/查询失败返回 nil(UI 占位,
    /// 不伪造);03 时代的旧行 net 列为 NULL,SUM 忽略之。
    func networkTotals(now: Date) -> NetworkTotalsReading? {
        guard let database else { return nil }
        do {
            let totals = try database.read { db in
                let dayStart = calendar.startOfDay(for: now)
                let weekStart = calendar.date(byAdding: .day, value: -6, to: dayStart)
                let hourStart = HistoryWindows.hourStartSeconds(of: now)
                let dayStartSeconds = HistoryWindows.epochSeconds(of: dayStart)
                let weekStartSeconds = weekStart.map { HistoryWindows.epochSeconds(of: $0) }
                    ?? dayStartSeconds

                /// net 两列的窗口求和(rx = 下行,tx = 上行):`[lower, upper)`。
                /// upper = nil = 不封顶(当前小时未卷积段,行只可能 ≤ now);
                /// 表名/边界都是本文件字面量整数,无注入面。
                func sum(table: String, lower: Int, upper: Int?) throws -> (rx: Int64, tx: Int64) {
                    let bound = upper.map { "AND ts < \(Int($0))" } ?? ""
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT COALESCE(SUM(net_rx), 0) AS rx, COALESCE(SUM(net_tx), 0) AS tx
                            FROM \(table) WHERE ts >= \(Int(lower)) \(bound)
                            """
                    )
                    let rx: Int64 = row?["rx"] ?? 0
                    let tx: Int64 = row?["tx"] ?? 0
                    return (rx, tx)
                }

                func total(_ hour: Int64, _ minute: Int64) -> UInt64 {
                    UInt64(max(0, hour + minute))
                }

                let (todayHourRx, todayHourTx) = try sum(table: "system_hour", lower: dayStartSeconds, upper: hourStart)
                let (weekHourRx, weekHourTx) = try sum(table: "system_hour", lower: weekStartSeconds, upper: hourStart)
                // 当前未卷积段的分钟表窗只有这一个([hourStart, ∞)),Today 与
                // 7 天共用一次求和——同窗跑两遍是纯浪费(评审修复)。
                let (currentMinuteRx, currentMinuteTx) = try sum(table: "system_min", lower: hourStart, upper: nil)
                return NetworkTotalsReading(
                    todayDownBytes: total(todayHourRx, currentMinuteRx),
                    todayUpBytes: total(todayHourTx, currentMinuteTx),
                    weekDownBytes: total(weekHourRx, currentMinuteRx),
                    weekUpBytes: total(weekHourTx, currentMinuteTx)
                )
            }
            noteDatabaseSuccess()
            return totals
        } catch {
            noteDatabaseFailure("网络累计查询失败", error)
            return nil
        }
    }

    // MARK: 改项目根的组身份迁移(arch-review-2026-10-18/03 乙3)

    /// metadata 表里上一版项目根快照的键。
    private static let projectRootsKey = "project_roots"

    /// 对账项目根(启动时与每次改根各调一次):与库里上一版快照比对,按
    /// ProjectRootMigration 的一对一配对把旧根的组键改写成新根(分钟表 / 小时表 /
    /// 组元数据,worktree 后缀保留),再存下这一版快照。首启(无快照)只存快照。
    /// 新键在同一时刻已有行时(PRIMARY KEY 冲突)保留新行、旧行原样留下(OR IGNORE)。
    /// 失败只记日志——历史是旁路。
    func reconcileProjectRoots(_ roots: [String]) {
        guard let database else { return }
        let normalized = roots.map(PathNormalization.normalize).sorted()
        do {
            let plan: ProjectRootMigration.Plan? = try database.write { db in
                let stored = try String.fetchOne(
                    db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [Self.projectRootsKey]
                )
                let previous = stored
                    .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
                var plan: ProjectRootMigration.Plan?
                if let previous, previous != normalized {
                    let computed = ProjectRootMigration.plan(previous: previous, current: normalized)
                    for move in computed.moves {
                        try Self.rewriteGroupKeys(move, in: db)
                    }
                    plan = computed
                }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)",
                    arguments: [Self.projectRootsKey, LineageRow.argvJSON(normalized)]
                )
                return plan
            }
            guard let plan else { return }
            for move in plan.moves {
                LogService.info("项目根变更:历史从 \(move.from) 迁到 \(move.to)", category: "History")
            }
            for root in plan.skipped {
                LogService.info("项目根变更:\(root) 的新去处有歧义,历史未迁移", category: "History")
            }
            if !plan.moves.isEmpty {
                persistedGroupNames = try database.read { db in try Self.persistedGroupNames(in: db) }
            }
        } catch {
            LogService.error("项目根对账失败:\(error)", category: "History")
        }
    }

    /// 一处根迁移:旧键 "project:<from>" 与 "project:<from>@<wt>" 换成新根前缀。
    /// 用 substr 比前缀而非 LIKE(路径里可能有 % 与 _);长度按 Unicode 码点数
    /// (SQLite 对 TEXT 的 substr 以字符计)。
    private static func rewriteGroupKeys(_ move: ProjectRootMigration.Move, in db: Database) throws {
        let oldPrefix = ProjectRootMigration.keyPrefix(ofRoot: move.from)
        let newPrefix = ProjectRootMigration.keyPrefix(ofRoot: move.to)
        let worktreePrefix = oldPrefix + "@"
        let tailStart = oldPrefix.unicodeScalars.count + 1
        let arguments: StatementArguments = [
            newPrefix, tailStart, oldPrefix, worktreePrefix.unicodeScalars.count, worktreePrefix,
        ]
        let match = "group_id = ? OR substr(group_id, 1, ?) = ?"
        for table in ["sample_min", "sample_hour"] {
            try db.execute(
                sql: "UPDATE OR IGNORE \(table) SET group_id = ? || substr(group_id, ?) WHERE \(match)",
                arguments: arguments
            )
        }
        try db.execute(
            sql: """
                UPDATE OR IGNORE groups SET group_id = ? || substr(group_id, ?), project_root = ?
                WHERE \(match)
                """,
            arguments: [newPrefix, tailStart, move.to, oldPrefix, worktreePrefix.unicodeScalars.count, worktreePrefix]
        )
    }

    // MARK: 出生登记回灌(重启保归因)

    /// 启动回灌:库中全部出生登记读回为内存登记表(此前见过的断链进程,
    /// 重启后依旧归原宿主——验收锚点①先半),同时预热"已持久化"集合,
    /// 后续增量写跳过存量。库不可用返回空表(管线照常跑)。
    func importLineage() -> LineageRegistry {
        guard let database else { return LineageRegistry() }
        do {
            let rows = try database.read { db in
                try LineageRow.fetchAll(db)
            }
            var registry = LineageRegistry()
            for row in rows {
                persistedLineagePIDs.insert(pid_t(row.pid))
                registry.register(pid: pid_t(row.pid), entry: row.entry)
            }
            return registry
        } catch {
            LogService.error("出生登记回灌失败:\(error)", category: "History")
            return LineageRegistry()
        }
    }

    /// 增量登记:只写未持久化过的 pid(INSERT OR IGNORE,首记为准——与
    /// 内存登记表同口径)。first_seen = 落库时刻(登记即落库,滞后 ≤1 轮)。
    private func persistLineage(
        _ lineage: LineageRegistry, seenAt now: Date, in db: Database
    ) throws {
        let firstSeen = now.timeIntervalSince1970
        for (pid, entry) in lineage.entries where !persistedLineagePIDs.contains(pid) {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO lineage
                        (pid, parent_pid, executable_path, cwd, argv, first_seen)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    pid,
                    entry.parentPID,
                    entry.executablePath,
                    entry.cwd,
                    LineageRow.argvJSON(entry.argv),
                    firstSeen,
                ]
            )
            persistedLineagePIDs.insert(pid)
        }
    }

    // MARK: 组展示元数据缓存

    /// 组元数据只在首见或改名时重写;project_root 仅项目组有。
    private func persistGroupMetadata(_ displayNames: [GroupIdentity: String], in db: Database) throws {
        for (identity, name) in displayNames {
            let key = identity.stableKey
            guard persistedGroupNames[key] != name else { continue }
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO groups (group_id, name, category, project_root)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    key,
                    name,
                    identity.category.rawValue,
                    Self.projectRoot(of: identity),
                ]
            )
            persistedGroupNames[key] = name
        }
    }

    /// 项目组的项目根;其余类别为 NULL。
    private static func projectRoot(of identity: GroupIdentity) -> String? {
        if case .project(let root, _) = identity { return root }
        return nil
    }

    private static func persistedGroupNames(in db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT group_id, name FROM groups")
        var names: [String: String] = [:]
        for row in rows {
            names[row["group_id"]] = row["name"]
        }
        return names
    }

    // MARK: 行写入与卷积

    /// 分钟聚合 → sample_min + system_min 各一批行(组级磁盘两列本阶段恒空;
    /// 系统级 net/disk 四列随聚合写入增量合计——net 自工单 06,disk 与其同款
    /// 差分增量口径接线)。
    private static func insertMinute(_ aggregate: MinuteAggregate, in db: Database) throws {
        let ts = HistoryWindows.epochSeconds(of: aggregate.minuteStart)
        for group in aggregate.groups {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO sample_min
                        (ts, group_id, cpu_avg, cpu_max, mem_max, procs)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    ts,
                    group.identity.stableKey,
                    group.cpuAverage,
                    group.cpuPeak,
                    Int64(group.memoryPeak),
                    group.processPeak,
                ]
            )
        }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO system_min
                    (ts, load_avg, load_max, net_rx, net_tx, disk_read, disk_written)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                ts,
                aggregate.systemLoadAverage,
                aggregate.systemLoadPeak,
                Int64(bitPattern: aggregate.netRxBytes),
                Int64(bitPattern: aggregate.netTxBytes),
                Int64(bitPattern: aggregate.diskReadBytes),
                Int64(bitPattern: aggregate.diskWriteBytes),
            ]
        )
    }

    /// 小时卷积(两级口径的下半):sample_min/system_min 中 `[lower, upper)`
    /// 的完整小时,SQL 聚合进对应小时表。幂等(INSERT OR REPLACE),可重放;
    /// 小时边界按 epoch 对齐(HistoryWindows)。组级 cpu 取分钟均值的均值、
    /// 峰值取最大;mem/procs 取最大。
    private static func rollupHours(from lower: Int, through upper: Int, in db: Database) throws {
        guard upper > lower else { return }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO sample_hour
                    (ts, group_id, cpu_avg, cpu_max, mem_max, procs, disk_r, disk_w)
                SELECT ts / 3600 * 3600, group_id,
                       AVG(cpu_avg), MAX(cpu_max), MAX(mem_max), MAX(procs),
                       MAX(disk_r), MAX(disk_w)
                FROM sample_min
                WHERE ts >= ? AND ts < ?
                GROUP BY ts / 3600 * 3600, group_id
                """,
            arguments: [lower, upper]
        )
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO system_hour
                    (ts, load_avg, load_max, net_rx, net_tx, disk_read, disk_written)
                SELECT ts / 3600 * 3600,
                       AVG(load_avg), MAX(load_max),
                       SUM(net_rx), SUM(net_tx), SUM(disk_read), SUM(disk_written)
                FROM system_min
                WHERE ts >= ? AND ts < ?
                GROUP BY ts / 3600 * 3600
                """,
            arguments: [lower, upper]
        )
    }

    /// 留存清理:分钟 7 天、小时 30 天(截止见 HistoryRetention)。
    private static func runRetention(now: Date, in db: Database) throws {
        let minuteCutoff = HistoryWindows.epochSeconds(of: HistoryRetention.minuteCutoff(now: now))
        let hourCutoff = HistoryWindows.epochSeconds(of: HistoryRetention.hourCutoff(now: now))
        try db.execute(sql: "DELETE FROM sample_min WHERE ts < ?", arguments: [minuteCutoff])
        try db.execute(sql: "DELETE FROM system_min WHERE ts < ?", arguments: [minuteCutoff])
        try db.execute(sql: "DELETE FROM sample_hour WHERE ts < ?", arguments: [hourCutoff])
        try db.execute(sql: "DELETE FROM system_hour WHERE ts < ?", arguments: [hourCutoff])
    }
}
