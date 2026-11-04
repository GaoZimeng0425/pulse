import GRDB
@testable import PulseCore
import XCTest

/// 一期闭环小件(p4-uninstaller/06):历史 run 的卸载类型标记(Q15)——
/// runs() 查询 EXISTS 判定,不落列;与记录构造的默认值兼容。
final class CleanRunTypeTests: XCTestCase {
    func testRunsFlagUninstallRuns() async throws {
        let queue = try DatabaseQueue()
        try HistoryDatabase.migrator().migrate(queue)
        let store = CleanHistoryStore(database: queue)

        // 垃圾 run(一期口径)
        try await store.record(CleanRunReport(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            items: [
                CleanRunItem(
                    path: "/x/dd",
                    title: "DerivedData",
                    bytes: 10,
                    tier: .safe,
                    ruleID: "xcode.derivedData",
                    outcome: .recycled(destination: "/Trash/dd")
                ),
            ]
        ))
        // 卸载 run(p4-uninstaller/03 口径:app-uninstall 项存在即卸载)
        try await store.record(CleanRunReport(
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 400),
            items: [
                CleanRunItem(
                    path: "/Applications/Demo.app",
                    title: "Demo",
                    bytes: 1000,
                    tier: .safe,
                    ruleID: "app-uninstall",
                    outcome: .permanentlyDeleted(route: .brew)
                ),
                CleanRunItem(
                    path: "/x/caches",
                    title: "缓存",
                    bytes: 50,
                    tier: .safe,
                    ruleID: "app-leftover",
                    outcome: .recycled(destination: "/Trash/caches")
                ),
            ]
        ))

        let runs = try await store.runs()
        XCTAssertEqual(runs.count, 2)
        // 新的在前(卸载 run 时戳晚)
        XCTAssertTrue(runs[0].isUninstall, "app-uninstall 项存在 → 卸载 run(Q15 标记)")
        XCTAssertFalse(runs[1].isUninstall, "纯垃圾 run 不标")
    }
}
