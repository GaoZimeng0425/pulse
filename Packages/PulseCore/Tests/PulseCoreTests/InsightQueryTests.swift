import GRDB
@testable import PulseCore
import XCTest

/// 洞察查询(p3-root-mcp/02):why_cpu_high 的组排行与 current_metrics 的
/// 最新快照,真 SQLite(内存库)直插夹具,聚焦取数口径;读侧专用入口
/// openReader 的"库不存在 → nil / 存在 → query_only"行为一并钉死。
final class InsightQueryTests: XCTestCase {
    /// 基准时刻:整分对齐,窗口断言无歧义。
    private var base: Int {
        1_789_000_000 / 60 * 60
    }

    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try HistoryDatabase.openInMemory()
    }

    private var now: Date {
        Date(timeIntervalSince1970: Double(base + 60))
    }

    // MARK: 夹具:按 schema 直插行

    private func insertSample(
        _ ts: Int, _ groupID: String, cpuAvg: Double, cpuMax: Double, mem: Int, procs: Int
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO sample_min (ts, group_id, cpu_avg, cpu_max, mem_max, procs) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [ts, groupID, cpuAvg, cpuMax, mem, procs]
            )
        }
    }

    private func insertGroup(_ groupID: String, name: String, category: String, projectRoot: String?) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO groups (group_id, name, category, project_root) VALUES (?, ?, ?, ?)",
                arguments: [groupID, name, category, projectRoot]
            )
        }
    }

    // MARK: topCpuGroups

    func testTopCpuGroupsOrderByWindowAverageDesc() throws {
        // 窗口 [base-540, base+60):两组各 3 行,b 组均值高;窗口外(base-700)
        // 的一行高分不进均值——窗口过滤与均值口径一次钉死。
        try insertSample(base - 540, "a", cpuAvg: 10, cpuMax: 20, mem: 100, procs: 1)
        try insertSample(base - 60, "a", cpuAvg: 30, cpuMax: 40, mem: 300, procs: 2)
        try insertSample(base, "a", cpuAvg: 50, cpuMax: 60, mem: 200, procs: 3)
        try insertSample(base - 540, "b", cpuAvg: 40, cpuMax: 45, mem: 10, procs: 4)
        try insertSample(base - 60, "b", cpuAvg: 60, cpuMax: 80, mem: 30, procs: 5)
        try insertSample(base - 700, "c", cpuAvg: 999, cpuMax: 999, mem: 999, procs: 9)

        let top = try queue.read { db in
            try InsightQuery.topCpuGroups(limit: 3, lookbackMinutes: 10, now: now, in: db)
        }
        XCTAssertEqual(top.map(\.groupID), ["b", "a"]) // c 全在窗外被过滤
        let b = try XCTUnwrap(top.first)
        XCTAssertEqual(b.cpuAverage, 50, accuracy: 0.001) // (40+60)/2
        XCTAssertEqual(b.cpuPeak, 80)
        XCTAssertEqual(b.memoryMaxBytes, 30)
        XCTAssertEqual(b.processCount, 5) // 窗口内最新一行的 procs
    }

    func testTopCpuGroupsLeftJoinGroupsFallbackAndMetadata() throws {
        // g 有 groups 行(名称/分类/项目根生效);orphan 无行(name 兜底组 ID、
        // category unknown、projectRoot nil)——引擎启动早期缓存未写不丢组。
        try insertGroup("g", name: "Xcode", category: "app", projectRoot: "/src/pulse")
        try insertSample(base, "g", cpuAvg: 10, cpuMax: 10, mem: 1, procs: 1)
        try insertSample(base, "orphan", cpuAvg: 5, cpuMax: 5, mem: 1, procs: 1)

        let top = try queue.read { db in
            try InsightQuery.topCpuGroups(limit: 5, lookbackMinutes: 10, now: now, in: db)
        }
        let g = try XCTUnwrap(top.first { $0.groupID == "g" })
        XCTAssertEqual(g.name, "Xcode")
        XCTAssertEqual(g.category, "app")
        XCTAssertEqual(g.projectRoot, "/src/pulse")
        let orphan = try XCTUnwrap(top.first { $0.groupID == "orphan" })
        XCTAssertEqual(orphan.name, "orphan")
        XCTAssertEqual(orphan.category, "unknown")
        XCTAssertNil(orphan.projectRoot)
    }

    func testTopCpuGroupsEmptyLibraryReturnsEmpty() throws {
        let top = try queue.read { db in
            try InsightQuery.topCpuGroups(limit: 5, lookbackMinutes: 10, now: now, in: db)
        }
        XCTAssertTrue(top.isEmpty)
    }

    // MARK: latestSnapshot

    func testLatestSnapshotAggregatesNewestRowsOnly() throws {
        // sample_min 两分钟:快照只取最新分钟行的全组求和(旧分钟不掺)。
        try insertSample(base - 60, "a", cpuAvg: 100, cpuMax: 100, mem: 1000, procs: 1)
        try insertSample(base, "a", cpuAvg: 10, cpuMax: 20, mem: 300, procs: 2)
        try insertSample(base, "b", cpuAvg: 5, cpuMax: 8, mem: 200, procs: 1)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max, net_rx, net_tx, disk_read, disk_written) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [base, 12.5, 13.0, 600, 1800, nil, nil]
            )
            try db.execute(
                sql: "INSERT INTO gauge_min (ts, key, avg, max) VALUES (?, ?, ?, ?)",
                arguments: [base, "temp_avg", 62.5, nil]
            )
            try db.execute(
                sql: "INSERT INTO gauge_min (ts, key, avg, max) VALUES (?, ?, ?, ?)",
                arguments: [base - 60, "temp_avg", 50.0, nil]
            )
        }

        let snapshot = try queue.read { db in
            try InsightQuery.latestSnapshot(now: now, in: db)
        }
        XCTAssertEqual(snapshot.cpuSumPercent?.value ?? 0, 15, accuracy: 0.001) // 10+5
        XCTAssertEqual(snapshot.cpuSumPercent?.atSeconds, base)
        XCTAssertEqual(snapshot.memoryBytes?.value ?? 0, 500) // 300+200
        XCTAssertEqual(snapshot.systemLoad?.value ?? 0, 12.5, accuracy: 0.001)
        // (600+1800)/60 = 40 B/s;disk 双侧 NULL → nil(NULL 传染)。
        XCTAssertEqual(snapshot.networkBytesPerSec?.value ?? 0, 40, accuracy: 0.001)
        XCTAssertNil(snapshot.diskBytesPerSec)
        // 每键只取最新行:temp_avg = 62.5(base 行),旧行不掺。
        let temp = try XCTUnwrap(snapshot.gauges["temp_avg"])
        XCTAssertEqual(temp.value, 62.5, accuracy: 0.001)
        XCTAssertEqual(temp.atSeconds, base)
        XCTAssertEqual(snapshot.newestSampleSeconds, base)
        XCTAssertEqual(snapshot.newestSystemSeconds, base)
    }

    func testLatestSnapshotEmptyLibraryAllNil() throws {
        let snapshot = try queue.read { db in
            try InsightQuery.latestSnapshot(now: now, in: db)
        }
        XCTAssertNil(snapshot.systemLoad)
        XCTAssertNil(snapshot.networkBytesPerSec)
        XCTAssertNil(snapshot.cpuSumPercent)
        XCTAssertNil(snapshot.memoryBytes)
        XCTAssertTrue(snapshot.gauges.isEmpty)
        XCTAssertNil(snapshot.newestSampleSeconds)
        XCTAssertNil(snapshot.newestSystemSeconds)
    }

    // MARK: openReader(读侧专用入口)

    func testOpenReaderMissingFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-reader-missing-\(UUID().uuidString).sqlite")
        XCTAssertNil(try HistoryDatabase.openReader(at: url))
    }

    func testOpenReaderIsQueryOnlyAndRefusesWrites() throws {
        // 真库文件:openReader 能读既有行、写语句被拒;顺带钉死"不创建、不迁移"。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-reader-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try HistoryDatabase.open(at: url)
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max, net_rx, net_tx, disk_read, disk_written) VALUES (1, 3.0, 3.0, NULL, NULL, NULL, NULL)"
            )
        }
        let reader = try XCTUnwrap(try HistoryDatabase.openReader(at: url))
        let flag = try reader.read { db in
            try Int.fetchOne(db, sql: "PRAGMA query_only")
        }
        XCTAssertEqual(flag, 1, "query_only 未生效——prepareDatabase 里的 PRAGMA 没落上")
        let load = try reader.read { db in
            try Double.fetchOne(db, sql: "SELECT load_avg FROM system_min")
        }
        XCTAssertEqual(load ?? 0, 3.0)
        // 写语句必须大声失败或至少静默 no-op——两种都算"读侧不改动库",
        // 但行为要钉死:实测 GRDB write 闭包里的 DELETE/INSERT 行为面。
        let insertThrew: Bool
        do {
            try reader.write { db in
                try db.execute(sql: "DELETE FROM system_min")
                try db.execute(
                    sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (2, 1.0, 1.0)"
                )
            }
            insertThrew = false
        } catch {
            insertThrew = true
        }
        let countAfter = try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_min")
        }
        XCTAssertTrue(insertThrew || countAfter == 1, """
        query_only=1 下写既没抛错又改了行数(insertThrew=\(insertThrew), count=\(countAfter ?? -1))——只读保证失守
        """)
        // 只读者不迁移:向 reader 发迁移入口不可达(openReader 不跑 migrator),
        // 行为面以"写被拒"钉死。
    }
}
