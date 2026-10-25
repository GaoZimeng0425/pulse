import Foundation
import GRDB

/// 历史库(工单 03,spec 实现决策「存储」):GRDB 单连接 SQLite,
/// 库文件 `~/Library/Application Support/Pulse/history.sqlite`,WAL 模式。
///
/// 六张表(schema 按 spec;ts 一律整秒 epoch INTEGER,窗口口径见 HistoryWindows):
/// - `sample_min` / `sample_hour`:组级,分钟留 7 天、小时留 30 天;
///   磁盘两列(disk_r/disk_w)本阶段恒空(spec 拍板:每组 rusage 与采样成本
///   优化直接冲突且 P1 无消费界面——建表保留列位,推迟 ≠ 放弃);
/// - `system_min` / `system_hour`:系统级,同留存;net/disk 四列由工单 05
///   的吞吐探针接入,本阶段恒空(NULL),不伪造 0;
/// - `lineage`:出生登记持久化(GLOSSARY)——spec 草案的 parent_chain 落为
///   行间 parent_pid 链接(链由各进程自己的记录串联,与内存登记表同构);
///   uniqid 列暂缺:登记表按 pid 键、ProcessIdentity 不携带唯一号
///   ("pid 复用不做区分"为既知限制,与 P0 内存版同口径);
/// - `groups`:组展示元数据缓存(group_id = stableKey,读回可重建身份,
///   见 GroupIdentity(stableKey:))。**目前只写不读**(arch-review-2026-10-18/03 乙8
///   拍成「注释钉死」):历史页只有全组合计曲线,没有按组视图,唯一的读方是引擎启动
///   时预热改名缓存;表留给将来按组的历史视图(组名 / 类别 / 项目根不必再从键里猜),
///   改项目根迁移会同步改写它,保持与样本表同键;
/// - `gauge_min` / `gauge_hour`(p2-review/09):传感器仪表窄表,每类量一行
///   `(ts, key, avg, max)`,加新量零迁移(见 `GaugeKey`);同分钟 7 天/小时 30 天留存;
/// - `metadata`(v2):键值杂项——现存上一版项目根快照(改根时据此迁移组身份,
///   arch-review-2026-10-18/03 乙3)。
///
/// 测试不设缝(Testing Decisions):内存库 / 临时目录库直接对真 SQLite 断言。
public enum HistoryDatabase {
    /// 默认库文件:Application Support/Pulse/history.sqlite(目录自动创建)。
    public static var defaultURL: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Pulse/history.sqlite")
    }

    /// 打开(或创建)文件库:父目录自动创建、WAL、建表迁移(幂等)。
    /// p2-review-09 窄表迁移是单向门(宽表仪表列变换后即删):迁移首跑前自动
    /// 备份库文件(同目录三件套 `.pre-gauge-<epoch>.bak`,已有则不重复——
    /// 一次性保险,用户拍板「立即删旧列 + 迁移前备份」)。文件级复制 db/-wal/-shm:
    /// 启动期单进程无并发写者,快照一致。
    static func open(at url: URL = defaultURL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupBeforeGaugeMigrationIfNeeded(at: url)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // WAL:写不阻塞读。持久属性,但每次打开显式设置自证(验收①)。
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try migrator().migrate(queue)
        return queue
    }

    /// 窄表迁移首跑前的库文件备份。只读探测迁移状态(不动库);需备份 =
    /// 库文件在场 && 窄表迁移未应用 && 本秒备份缺席。
    private static func backupBeforeGaugeMigrationIfNeeded(at url: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        var readonly = Configuration()
        readonly.readonly = true
        guard let probe = try? DatabaseQueue(path: url.path, configuration: readonly),
              try probe.read({ db in try !migrator().completedMigrations(db).contains(gaugeMigrationID) })
        else { return }
        let stamp = HistoryWindows.epochSeconds(of: Date())
        for source in [url.path, url.path + "-wal", url.path + "-shm"] {
            let destination = source + ".pre-gauge-\(stamp).bak"
            if manager.fileExists(atPath: source), !manager.fileExists(atPath: destination) {
                try manager.copyItem(atPath: source, toPath: destination)
            }
        }
    }

    /// 内存库(单测用):同一套建表迁移,零磁盘副作用。
    public static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return queue
    }

    /// 窄表迁移标识(备份探测与测试造旧库共用)。
    static let gaugeMigrationID = "p2-review-09-gauges"

    /// 建表迁移(全量)。测试造窄表化**之前**的旧库:
    /// `try HistoryDatabase.migrator().migrate(queue, upTo: "p2-sensors-v2")`
    /// (GRDB 原生截断)。
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("p1-history-v1") { db in
            try db.execute(sql: """
            CREATE TABLE sample_min (
                ts       INTEGER NOT NULL,
                group_id TEXT    NOT NULL,
                cpu_avg  REAL    NOT NULL,
                cpu_max  REAL    NOT NULL,
                mem_max  INTEGER NOT NULL,
                procs    INTEGER NOT NULL,
                disk_r   INTEGER,
                disk_w   INTEGER,
                PRIMARY KEY (ts, group_id)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE sample_hour (
                ts       INTEGER NOT NULL,
                group_id TEXT    NOT NULL,
                cpu_avg  REAL    NOT NULL,
                cpu_max  REAL    NOT NULL,
                mem_max  INTEGER NOT NULL,
                procs    INTEGER NOT NULL,
                disk_r   INTEGER,
                disk_w   INTEGER,
                PRIMARY KEY (ts, group_id)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE system_min (
                ts           INTEGER PRIMARY KEY,
                load_avg     REAL    NOT NULL,
                load_max     REAL    NOT NULL,
                net_rx       INTEGER,
                net_tx       INTEGER,
                disk_read    INTEGER,
                disk_written INTEGER
            )
            """)
            try db.execute(sql: """
            CREATE TABLE system_hour (
                ts           INTEGER PRIMARY KEY,
                load_avg     REAL    NOT NULL,
                load_max     REAL    NOT NULL,
                net_rx       INTEGER,
                net_tx       INTEGER,
                disk_read    INTEGER,
                disk_written INTEGER
            )
            """)
            try db.execute(sql: """
            CREATE TABLE lineage (
                pid             INTEGER PRIMARY KEY,
                parent_pid      INTEGER NOT NULL,
                executable_path TEXT,
                cwd             TEXT,
                argv            TEXT,
                first_seen      REAL    NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE groups (
                group_id     TEXT PRIMARY KEY,
                name         TEXT NOT NULL,
                category     TEXT NOT NULL,
                project_root TEXT
            )
            """)
        }
        migrator.registerMigration("p1-history-v2-metadata") { db in
            try db.execute(sql: """
            CREATE TABLE metadata (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        }
        // P2 传感器趋势量(p2-sensors/08):温度派生/GPU 利用率/五路功率平均瓦数。
        // 全部可空列——传感器缺席的分钟为 NULL,查询层如实空段不伪造 0;
        // 历史档(不可见 30s)采样进分钟聚合,小时卷积取 AVG。
        migrator.registerMigration("p2-sensors-v2") { db in
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN temp_avg REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN temp_max REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN gpu_util REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN pow_cpu REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN pow_gpu REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN pow_ane REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN pow_ram REAL")
            try db.execute(sql: "ALTER TABLE system_min ADD COLUMN pow_soc REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN temp_avg REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN temp_max REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN gpu_util REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN pow_cpu REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN pow_gpu REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN pow_ane REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN pow_ram REAL")
            try db.execute(sql: "ALTER TABLE system_hour ADD COLUMN pow_soc REAL")
        }
        // 仪表窄表(p2-review/09):宽表 8 仪表列变换进窄表后删除——单向门,
        // 迁移首跑前 open 已备份库文件。均值类列的值进 avg 列,temp_max 进
        // max 列(口径见 GaugeKey.aggregation);NULL 列不产生行。GRDB 迁移
        // 事务性:任一步失败整体回滚,库停在宽表态。
        migrator.registerMigration(gaugeMigrationID) { db in
            try db.execute(sql: """
            CREATE TABLE gauge_min (
                ts  INTEGER NOT NULL,
                key TEXT    NOT NULL,
                avg REAL,
                max REAL,
                PRIMARY KEY (ts, key)
            )
            """)
            try db.execute(sql: """
            CREATE TABLE gauge_hour (
                ts  INTEGER NOT NULL,
                key TEXT    NOT NULL,
                avg REAL,
                max REAL,
                PRIMARY KEY (ts, key)
            )
            """)
            // 查询按 key 过滤 + 时间窗:key 前置索引。
            try db.execute(sql: "CREATE INDEX gauge_min_key_ts ON gauge_min(key, ts)")
            try db.execute(sql: "CREATE INDEX gauge_hour_key_ts ON gauge_hour(key, ts)")
            for table in ["system_min", "system_hour"] {
                let target = table == "system_min" ? "gauge_min" : "gauge_hour"
                // 均值类:值进 avg 列。
                for column in ["temp_avg", "gpu_util", "pow_cpu", "pow_gpu", "pow_ane", "pow_ram", "pow_soc"] {
                    try db.execute(sql: """
                    INSERT INTO \(target) (ts, key, avg, max)
                    SELECT ts, '\(column)', \(column), NULL
                    FROM \(table) WHERE \(column) IS NOT NULL
                    """)
                }
                // 最热类:值进 max 列。
                try db.execute(sql: """
                INSERT INTO \(target) (ts, key, avg, max)
                SELECT ts, 'temp_max', NULL, temp_max
                FROM \(table) WHERE temp_max IS NOT NULL
                """)
                for column in [
                    "temp_avg",
                    "temp_max",
                    "gpu_util",
                    "pow_cpu",
                    "pow_gpu",
                    "pow_ane",
                    "pow_ram",
                    "pow_soc",
                ] {
                    try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column)")
                }
            }
        }

        return migrator
    }

    // MARK: 表名单(测试与自检共用)

    public static let tableNames = [
        "sample_min", "sample_hour", "system_min", "system_hour",
        "gauge_min", "gauge_hour", "lineage", "groups", "metadata",
    ]
}
