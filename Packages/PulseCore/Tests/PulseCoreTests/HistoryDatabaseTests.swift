import GRDB
@testable import PulseCore
import XCTest

/// 历史库层(工单 03):真 SQLite 断言——文件库 WAL、六张表、迁移幂等、
/// 内存库同构。Testing Decisions:历史库不设缝,直接对真库测。
final class HistoryDatabaseTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("pulse-history-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(
            at: temporaryURL.deletingLastPathComponent()
                .appendingPathComponent(temporaryURL.deletingPathExtension().lastPathComponent + ".sqlite-wal")
        )
        try? FileManager.default.removeItem(
            at: temporaryURL.deletingLastPathComponent()
                .appendingPathComponent(temporaryURL.deletingPathExtension().lastPathComponent + ".sqlite-shm")
        )
    }

    /// 验收①:文件库以 WAL 模式打开(写不阻塞读的既定口径)。
    func testFileDatabaseOpensInWALMode() throws {
        let queue = try HistoryDatabase.open(at: temporaryURL)

        let journalMode = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode, "wal")
    }

    /// 六张 spec 表 + metadata(v2,项目根快照)落地(grdb_migrations 是迁移器自带的簿记表,不算)。
    func testAllTablesExist() throws {
        let queue = try HistoryDatabase.openInMemory()

        let tables = try queue.read { db in
            try Set(
                String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
                )
            )
        }
        XCTAssertEqual(tables, Set(HistoryDatabase.tableNames))
    }

    /// 组级磁盘两列、系统级 net/disk 四列本阶段恒空(spec 拍板):列在,
    /// 现阶段不写入任何值。
    func testGroupDiskAndSystemThroughputColumnsExistButStayEmpty() throws {
        let queue = try HistoryDatabase.openInMemory()
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO sample_min (ts, group_id, cpu_avg, cpu_max, mem_max, procs) VALUES (1, 'orphan', 1, 1, 1, 1)"
            )
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (1, 1, 1)"
            )
        }

        let diskR = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT disk_r FROM sample_min")
        }
        let netRx = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT net_rx FROM system_min")
        }
        XCTAssertNil(diskR)
        XCTAssertNil(netRx)
    }

    /// 重复打开同一文件:迁移幂等,表与数据俱在(重启 app 的常态路径)。
    func testReopeningSameFileIsIdempotent() throws {
        _ = try HistoryDatabase.open(at: temporaryURL)
        let reopened = try HistoryDatabase.open(at: temporaryURL)

        let tables = try reopened.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN (?,?,?,?,?,?,?)",
                arguments: StatementArguments(HistoryDatabase.tableNames)
            )
        }
        XCTAssertEqual(tables, HistoryDatabase.tableNames.count)
    }

    /// 内存库:同一套迁移,零磁盘副作用。
    func testInMemoryDatabaseHasTheSameSchema() throws {
        let queue = try HistoryDatabase.openInMemory()

        let tableCount = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
            )
        }
        XCTAssertEqual(tableCount, HistoryDatabase.tableNames.count)
    }
}
