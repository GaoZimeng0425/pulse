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
    static func open(at url: URL = defaultURL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // WAL:写不阻塞读。持久属性,但每次打开显式设置自证(验收①)。
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try migrator().migrate(queue)
        return queue
    }

    /// 内存库(单测用):同一套建表迁移,零磁盘副作用。
    public static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return queue
    }

    /// 六张表(spec 实现决策「存储」的表清单)。
    private static func migrator() -> DatabaseMigrator {
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
        return migrator
    }

    // MARK: 表名单(测试与自检共用)

    public static let tableNames = [
        "sample_min", "sample_hour", "system_min", "system_hour", "lineage", "groups", "metadata",
    ]
}
