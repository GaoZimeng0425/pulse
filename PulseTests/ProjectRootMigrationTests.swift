import GRDB
import XCTest
@testable import Pulse
@testable import PulseCore

/// 改项目根后的历史迁移(arch-review-2026-10-18/03 乙3,用户拍板 2026-10-19:自动迁移,
/// 不文档化断史)。纯规则(ProjectRootMigration.plan)+ 真 SQLite 上的改写
/// (HistoryEngine.reconcileProjectRoots):改根前后同一项目的曲线连续;歧义保守跳过。
final class ProjectRootMigrationTests: XCTestCase {
    // MARK: 规则:旧根 → 新根的一对一配对

    /// 项目整体挪位置(末级目录名相同):迁。
    func testMovedProjectPairsByFolderName() {
        let plan = ProjectRootMigration.plan(
            previous: ["/Users/x/old/pulse", "/Users/x/keep"],
            current: ["/Users/x/new/pulse", "/Users/x/keep"]
        )
        XCTAssertEqual(plan.moves, [ProjectRootMigration.Move(from: "/Users/x/old/pulse", to: "/Users/x/new/pulse")])
        XCTAssertEqual(plan.skipped, [])
    }

    /// 收窄 / 放宽(路径互为前缀):迁;末尾斜杠按规范化处理。
    func testNarrowedOrWidenedRootPairsByPrefix() {
        XCTAssertEqual(
            ProjectRootMigration.plan(previous: ["/a/work/"], current: ["/a/work/pulse"]).moves,
            [ProjectRootMigration.Move(from: "/a/work", to: "/a/work/pulse")]
        )
        XCTAssertEqual(
            ProjectRootMigration.plan(previous: ["/a/work/pulse"], current: ["/a/work"]).moves,
            [ProjectRootMigration.Move(from: "/a/work/pulse", to: "/a/work")]
        )
    }

    /// 两个旧根都并进同一个新根(多对一):歧义,两个都跳过不迁。
    func testManyToOneIsAmbiguousAndSkipped() {
        let plan = ProjectRootMigration.plan(previous: ["/a/x", "/a/y"], current: ["/a"])
        XCTAssertEqual(plan.moves, [])
        XCTAssertEqual(plan.skipped, ["/a/x", "/a/y"])
    }

    /// 毫无关系的增删(换了个项目):不迁,也不算歧义。
    func testUnrelatedChangeMovesNothing() {
        let plan = ProjectRootMigration.plan(previous: ["/a/alpha"], current: ["/b/beta"])
        XCTAssertEqual(plan.moves, [])
        XCTAssertEqual(plan.skipped, [])
    }

    // MARK: 库上改写:曲线连续

    private let minute0 = HistoryWindows.minuteStart(of: Date(timeIntervalSince1970: 1_789_000_000))

    private func groupKeys(_ table: String, in queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT group_id FROM \(table) ORDER BY group_id")
        }
    }

    /// 先以旧根落两分钟(含 worktree 组),再改根:分钟表 / 小时表 / 组元数据里的旧键
    /// 全部换成新键(worktree 后缀保留),其他组不动。
    func testReconcileRewritesKeysOfAMovedRootAcrossTables() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let engine = HistoryEngine(database: queue, now: minute0)
        let oldRoot = "/Users/x/old/pulse"
        let main = GroupIdentity.project(root: oldRoot, worktreeName: nil)
        let worktree = GroupIdentity.project(root: oldRoot, worktreeName: "feat")
        let other = GroupIdentity.app(bundlePath: "/Applications/Zed.app")
        await engine.reconcileProjectRoots([oldRoot])
        for offset in [0.0, 65, 3_605] {
            await engine.ingest(
                at: minute0.addingTimeInterval(offset),
                systemLoad: 10,
                groups: [main, worktree, other].map { GroupSample(id: $0, cpuPercent: 5, memoryBytes: 1) },
                displayNames: [main: "pulse", worktree: "pulse @ feat", other: "Zed"],
                lineage: LineageRegistry()
            )
        }

        await engine.reconcileProjectRoots(["/Users/x/new/pulse"])

        let expected = ["bundle:/Applications/Zed.app", "project:/Users/x/new/pulse", "project:/Users/x/new/pulse@feat"]
        XCTAssertEqual(Set(try groupKeys("sample_min", in: queue)), Set(expected))
        XCTAssertEqual(Set(try groupKeys("sample_hour", in: queue)), Set(expected))
        XCTAssertEqual(try groupKeys("groups", in: queue), expected)
        let root = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT project_root FROM groups WHERE group_id = 'project:/Users/x/new/pulse@feat'")
        }
        XCTAssertEqual(root, "/Users/x/new/pulse")
    }

    /// 改根发生在一分钟中途:内存缓冲里这一分钟的旧键也一并换掉,冲刷时不留旧键行
    /// (审查 MEDIUM)。
    func testReconcileMidMinuteRekeysTheBufferedMinute() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let engine = HistoryEngine(database: queue, now: minute0)
        let old = GroupIdentity.project(root: "/a/old/pulse", worktreeName: "feat")
        await engine.reconcileProjectRoots(["/a/old/pulse"])
        await engine.ingest(
            at: minute0, systemLoad: 1,
            groups: [GroupSample(id: old, cpuPercent: 4, memoryBytes: 1)],
            displayNames: [old: "pulse @ feat"], lineage: LineageRegistry()
        )

        await engine.reconcileProjectRoots(["/a/new/pulse"])
        let renamed = GroupIdentity.project(root: "/a/new/pulse", worktreeName: "feat")
        await engine.ingest(
            at: minute0.addingTimeInterval(30), systemLoad: 1,
            groups: [GroupSample(id: renamed, cpuPercent: 8, memoryBytes: 1)],
            displayNames: [renamed: "pulse @ feat"], lineage: LineageRegistry()
        )
        await engine.ingest(
            at: minute0.addingTimeInterval(65), systemLoad: 1, groups: [], displayNames: [:], lineage: LineageRegistry()
        )

        XCTAssertEqual(try groupKeys("sample_min", in: queue), ["project:/a/new/pulse@feat"])
        let average = try await queue.read { db in
            try Double.fetchOne(db, sql: "SELECT cpu_avg FROM sample_min")
        }
        XCTAssertEqual(average ?? 0, 6, accuracy: 1e-9, "旧键与新键的两次采样合并成一行")
    }

    /// 歧义的改根不动库;首启(库里没有上一版快照)只记快照不迁。
    func testAmbiguousChangeAndFirstRunLeaveRowsUntouched() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let engine = HistoryEngine(database: queue, now: minute0)
        let x = GroupIdentity.project(root: "/a/x", worktreeName: nil)
        await engine.ingest(
            at: minute0, systemLoad: 1,
            groups: [GroupSample(id: x, cpuPercent: 1, memoryBytes: 1)],
            displayNames: [x: "x"], lineage: LineageRegistry()
        )
        await engine.ingest(
            at: minute0.addingTimeInterval(65), systemLoad: 1, groups: [], displayNames: [:], lineage: LineageRegistry()
        )

        await engine.reconcileProjectRoots(["/a/x", "/a/y"])   // 首启:只记快照
        await engine.reconcileProjectRoots(["/a"])             // 多对一:跳过

        XCTAssertEqual(try groupKeys("sample_min", in: queue), ["project:/a/x"])
        XCTAssertEqual(try groupKeys("groups", in: queue), ["project:/a/x"])
    }

    /// 快照随改根更新并持久:重开引擎后再改,以上一次的根为准。
    func testRootSnapshotPersistsAcrossRestarts() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let p = GroupIdentity.project(root: "/a/old/pulse", worktreeName: nil)
        let first = HistoryEngine(database: queue, now: minute0)
        await first.reconcileProjectRoots(["/a/old/pulse"])
        await first.ingest(
            at: minute0, systemLoad: 1,
            groups: [GroupSample(id: p, cpuPercent: 1, memoryBytes: 1)],
            displayNames: [p: "pulse"], lineage: LineageRegistry()
        )
        await first.ingest(
            at: minute0.addingTimeInterval(65), systemLoad: 1, groups: [], displayNames: [:], lineage: LineageRegistry()
        )

        let restarted = HistoryEngine(database: queue, now: minute0.addingTimeInterval(120))
        await restarted.reconcileProjectRoots(["/b/new/pulse"])

        XCTAssertEqual(try groupKeys("sample_min", in: queue), ["project:/b/new/pulse"])
    }
}
