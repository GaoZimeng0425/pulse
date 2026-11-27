import GRDB
@testable import PulseCore
import XCTest

/// 清理历史(p4-cleaner/04):内存库上真 SQLite 断言——落库与清单内容一致、去向 / 失败
/// 原因往返不丢、新的在前、空报告不落。Testing Decisions:历史库不设缝。
final class CleanHistoryStoreTests: XCTestCase {
    private func makeReport(start: TimeInterval = 1000, items: [CleanRunItem]) -> CleanRunReport {
        CleanRunReport(
            startedAt: Date(timeIntervalSince1970: start),
            finishedAt: Date(timeIntervalSince1970: start + 3),
            items: items
        )
    }

    private let recycledItem = CleanRunItem(
        path: "/Users/t/Library/Developer/Xcode/DerivedData",
        title: "Xcode DerivedData",
        bytes: 28000,
        tier: .safe,
        ruleID: "xcode.derivedData",
        outcome: .recycled(destination: "/Users/t/.Trash/DerivedData")
    )
    private let failedItem = CleanRunItem(
        path: "/Users/t/Library/Containers/com.docker.docker/Data",
        title: "Docker Desktop 数据",
        bytes: 21600,
        tier: .checkFirst,
        ruleID: "docker.desktopData",
        outcome: .failed(reason: "Operation not permitted")
    )

    func testRecordThenReadBackMatchesReport() async throws {
        let store = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let report = makeReport(items: [recycledItem, failedItem])

        let runID = try await store.record(report)
        let runs = try await store.runs()

        XCTAssertNotNil(runID)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].id, runID)
        XCTAssertEqual(runs[0].startedAt, report.startedAt)
        XCTAssertEqual(runs[0].finishedAt, report.finishedAt)
        XCTAssertEqual(runs[0].itemCount, 2)
        XCTAssertEqual(runs[0].freedBytes, 28000, "失败项不计释放量")
        XCTAssertEqual(runs[0].failedCount, 1)

        let items = try await store.items(runID: XCTUnwrap(runID))
        XCTAssertEqual(items.map(\.path), [recycledItem.path, failedItem.path], "与确认清单同序")
        XCTAssertEqual(items[0].outcome, .recycled(destination: "/Users/t/.Trash/DerivedData"))
        XCTAssertEqual(items[0].tier, .safe)
        XCTAssertEqual(items[0].bytes, 28000)
        XCTAssertEqual(items[0].ruleID, "xcode.derivedData")
        XCTAssertEqual(items[0].title, "Xcode DerivedData")
        XCTAssertEqual(items[1].outcome, .failed(reason: "Operation not permitted"))
        XCTAssertEqual(items[1].tier, .checkFirst)
    }

    func testEmptyReportIsNotRecorded() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let store = CleanHistoryStore(database: queue)

        let runID = try await store.record(makeReport(items: []))

        XCTAssertNil(runID)
        let count = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM clean_run") }
        XCTAssertEqual(count, 0)
    }

    func testRunsListNewestFirstAndItemsScopedToRun() async throws {
        let store = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let first = try await store.record(makeReport(start: 1000, items: [recycledItem]))
        let second = try await store.record(makeReport(start: 2000, items: [failedItem]))

        let runs = try await store.runs()
        XCTAssertEqual(runs.map(\.id), [second, first])
        let firstItems = try await store.items(runID: XCTUnwrap(first))
        XCTAssertEqual(firstItems.map(\.path), [recycledItem.path])
        let secondItems = try await store.items(runID: XCTUnwrap(second))
        XCTAssertEqual(secondItems.count, 1)
        let limited = try await store.runs(limit: 1)
        XCTAssertEqual(limited.count, 1)
    }

    /// p7-cleaner/01:标记随明细行落库、读回不丢;没带标记的行读回是空清单。两个标记各给
    /// 一行——只验一个的话,另一列写错或读漏照样全绿。
    func testMarkersRoundTrip() async throws {
        let store = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let authorized = CleanRunItem(
            path: "/Library/Logs/DiagnosticReports/x.ips",
            title: "x.ips",
            bytes: 1,
            tier: .checkFirst,
            ruleID: "fixture.system",
            outcome: .recycled(destination: "/Users/t/.Trash/x.ips"),
            markers: [.requiresAuthorization]
        )
        let unidentified = CleanRunItem(
            path: "/Users/t/Library/Caches/SomeTool",
            title: "SomeTool",
            bytes: 2,
            tier: .checkFirst,
            ruleID: "fixture.generic",
            outcome: .recycled(destination: "/Users/t/.Trash/SomeTool"),
            markers: [.unidentified]
        )
        let runID = try await store.record(makeReport(items: [authorized, unidentified, recycledItem]))

        let items = try await store.items(runID: XCTUnwrap(runID))
        XCTAssertEqual(items.map(\.markers), [[.requiresAuthorization], [.unidentified], []])
    }

    /// 登记面:每个已登记的标记都能经「落库 → 读回」原样回来。历史库的列映射在落库与读库
    /// 两处各手写一份——新增标记若忘了接,不报错、只是静默不进历史;这里按全 case 遍历兜底。
    func testEveryMarkerSurvivesHistoryRoundTrip() async throws {
        let store = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let items = JunkCandidateMarker.allCases.enumerated().map { index, marker in
            CleanRunItem(
                path: "/fixture/\(marker.rawValue)",
                title: marker.rawValue,
                bytes: Int64(index + 1),
                tier: .checkFirst,
                ruleID: "fixture.\(marker.rawValue)",
                outcome: .recycled(destination: "/Users/t/.Trash/\(marker.rawValue)"),
                markers: [marker]
            )
        }

        let runID = try await store.record(makeReport(items: items))

        let readBack = try await store.items(runID: XCTUnwrap(runID))
        XCTAssertEqual(readBack.map(\.markers), items.map(\.markers), "有标记没接进历史库的列映射")
    }

    /// 迁移幂等:p7-cleaner/01 之前的库(有清理表、没有标记列)补跑迁移即得两列,旧行读回无标记。
    func testMigrationAddsMarkerColumnsToExistingDatabase() async throws {
        let queue = try DatabaseQueue()
        try HistoryDatabase.migrator().migrate(queue, upTo: "p4-uninstaller-03-uninstall-history")
        try await queue.write { db in
            try db
                .execute(
                    sql: "INSERT INTO clean_run (started_at, finished_at, item_count, freed_bytes, failed_count) VALUES (1, 2, 1, 3, 0)"
                )
            try db.execute(sql: """
            INSERT INTO clean_item (run_id, path, title, bytes, tier, rule_id, destination)
            VALUES (1, '/Users/t/.npm/_cacache', 'npm 缓存', 3, 'safe', 'npm.cache', '/Users/t/.Trash/_cacache')
            """)
        }

        try HistoryDatabase.migrator().migrate(queue)

        let items = try await CleanHistoryStore(database: queue).items(runID: 1)
        XCTAssertEqual(items.map(\.markers), [[]])
    }

    /// 迁移幂等:老库(窄表之后、清理表之前)补跑迁移即得两张表,旧数据不动。
    func testMigrationAddsTablesToExistingDatabase() throws {
        let queue = try DatabaseQueue()
        try HistoryDatabase.migrator().migrate(queue, upTo: HistoryDatabase.gaugeMigrationID)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (1, 1, 1)")
        }

        try HistoryDatabase.migrator().migrate(queue)

        let tables = try queue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(tables.isSuperset(of: ["clean_run", "clean_item"]))
        XCTAssertEqual(try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM system_min") }, 1)
    }
}
