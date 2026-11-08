@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 勾选态 → 确认清单 → 执行报告(p4-cleaner/04)。闸门语义:默认全不勾、排除在删除前
/// 二次判定且只收窄、执行器回执逐项核对(未报到按失败)。废纸篓执行用 spy,绝不真删。
final class CleanPlanTests: XCTestCase {
    private func candidate(
        _ path: String,
        bytes: Int64 = 100,
        tier: CleanSafetyTier = .safe,
        reclaimable: Bool = true,
        snapshot: Double? = CleanFixture.directoryModified
    ) -> JunkCandidate {
        JunkCandidate(
            ruleID: "rule." + (path as NSString).lastPathComponent,
            group: .globalToolCache,
            title: (path as NSString).lastPathComponent,
            path: path,
            tier: tier,
            bytes: bytes,
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: reclaimable,
            rationale: "",
            symbolName: "shippingbox",
            modifiedAtScan: snapshot
        )
    }

    private var candidates: [JunkCandidate] {
        [
            candidate("/Users/t/Library/Developer/Xcode/DerivedData", bytes: 28000),
            candidate("/Users/t/Library/Caches/Homebrew", bytes: 3100),
            candidate("/Users/t/Library/Containers/com.docker.docker/Data", bytes: 21600, tier: .checkFirst),
            candidate("/Users/t/.npm/_cacache", bytes: 1800, reclaimable: false),
        ]
    }

    // MARK: 勾选态

    /// spec Story 4:默认全不勾——先检查项也一样,没有任何项是用户没点过的。
    func testSelectionStartsEmptyAndPlanIsEmpty() {
        let selection = JunkSelection()
        XCTAssertTrue(selection.isEmpty)
        let plan = CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.totalBytes, 0)
    }

    func testToggleAndPlanKeepsListOrder() {
        var selection = JunkSelection()
        selection.toggle(candidates[2])
        selection.toggle(candidates[0])
        selection.toggle(candidates[1])
        selection.toggle(candidates[1]) // 再点一次取消

        let plan = CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: [])
        XCTAssertEqual(plan.items.map(\.path), [candidates[0].path, candidates[2].path], "确认清单与列表同序,不按点击先后")
        XCTAssertEqual(plan.totalBytes, 28000 + 21600)
        XCTAssertTrue(plan.allReclaimableAccounting)
    }

    func testPlanFlagsMixedAccountingAndPartialItems() {
        var selection = JunkSelection()
        selection.set(candidates[3], selected: true)
        let plan = CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: [])
        XCTAssertFalse(plan.allReclaimableAccounting, "混了 block 回退口径的项,确认清单须能标注")
    }

    func testRetainDropsVanishedPaths() {
        var selection = JunkSelection()
        for c in candidates {
            selection.set(c, selected: true)
        }
        selection.retain(in: Array(candidates.prefix(2)))
        XCTAssertEqual(selection.count, 2)
        XCTAssertTrue(selection.contains(candidates[0]))
        XCTAssertFalse(selection.contains(candidates[3]))
    }

    // MARK: 整组勾选(2026-10-30 拍板 B):三态 + 批量设置只动传入的候选

    /// 组三态:none → mixed → all 随勾选数变化;空集 = none。
    func testGroupStateTransitions() {
        let safe = [candidates[0], candidates[1]] // 两个 safe 档项
        var selection = JunkSelection()
        XCTAssertEqual(selection.state(of: safe), .none)
        XCTAssertEqual(selection.state(of: []), .none, "空集按 none 处理(组里没有可安全清理项)")

        selection.set(candidates[0], selected: true)
        XCTAssertEqual(selection.state(of: safe), .mixed)

        selection.set(candidates[1], selected: true)
        XCTAssertEqual(selection.state(of: safe), .all)

        selection.set(candidates[0], selected: false)
        XCTAssertEqual(selection.state(of: safe), .mixed)
    }

    /// 批量设置只动传入的候选:组内全勾不清组外的勾,组内全清也不碰组外。
    func testBulkSetOnlyTouchesGivenCandidates() {
        let safe = [candidates[0], candidates[1]]
        var selection = JunkSelection()
        selection.set(candidates[2], selected: true) // 组外(先检查项,用户手勾)

        selection.set(true, for: safe)
        XCTAssertEqual(selection.state(of: safe), .all)
        XCTAssertTrue(selection.contains(candidates[2]), "组勾选不碰组外的勾")

        selection.set(false, for: safe)
        XCTAssertEqual(selection.state(of: safe), .none)
        XCTAssertTrue(selection.contains(candidates[2]), "组全清也不碰组外的勾")
    }

    // MARK: 排除二次判定

    /// 票面"扫描与删除两处生效":已勾选的项若在删除前被排除,计划里不能有它。
    func testExcludedPathsAreDroppedFromPlanEvenIfSelected() {
        var selection = JunkSelection()
        for c in candidates {
            selection.set(c, selected: true)
        }
        let plan = CleanPlan.make(
            selection: selection,
            candidates: candidates,
            excludedPathPrefixes: ["/Users/t/Library/Caches"]
        )
        XCTAssertEqual(plan.items.map(\.path), [candidates[0].path, candidates[2].path, candidates[3].path])
    }

    /// 排除只收窄:任何排除前缀下的计划 ⊆ 无排除的计划。
    func testExclusionOnlyNarrowsThePlan() {
        var selection = JunkSelection()
        for c in candidates {
            selection.set(c, selected: true)
        }
        let full = Set(CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: []).items
            .map(\.path))
        for prefixes in [
            ["/Users/t/Library"],
            ["/Users/t/.npm"],
            ["/Users/t"],
            ["/Users/other"],
            ["/Users/t/Library/Caches/", "/Users/t/.npm/_cacache"],
        ] {
            let narrowed = Set(CleanPlan.make(
                selection: selection,
                candidates: candidates,
                excludedPathPrefixes: prefixes
            ).items.map(\.path))
            XCTAssertTrue(narrowed.isSubset(of: full), "排除 \(prefixes) 让计划多出了项")
        }
        XCTAssertTrue(CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: ["/Users/t"])
            .isEmpty)
    }

    // MARK: 执行

    func testRunnerHandsExactPathsToExecutorAndMapsOutcomes() async {
        let items = Array(candidates.prefix(3))
        let plan = CleanPlan(items: items)
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [items[0].path: "/Users/t/.Trash/DerivedData", items[1].path: "/Users/t/.Trash/Homebrew"],
            failures: [items[2].path: "Operation not permitted"]
        ))
        let ticker = Ticker()
        let clock: @Sendable () -> Date = { ticker.next() }

        let report = await CleanRunner.run(plan, using: spy, now: clock)

        let calls = await spy.recycleCalls
        XCTAssertEqual(calls, [items.map(\.path)], "一次调用、恰好计划里的路径、同序")
        XCTAssertEqual(report.items.count, 3)
        XCTAssertEqual(report.items[0].outcome, .recycled(destination: "/Users/t/.Trash/DerivedData"))
        XCTAssertEqual(report.items[2].outcome, .failed(reason: "Operation not permitted"))
        XCTAssertEqual(report.freedBytes, 28000 + 3100, "失败项不计释放量")
        XCTAssertEqual(report.recycledPaths, [items[0].path, items[1].path])
        XCTAssertEqual(report.failed.map(\.path), [items[2].path])
        XCTAssertEqual(report.startedAt, Date(timeIntervalSince1970: 1001))
        XCTAssertEqual(report.finishedAt, Date(timeIntervalSince1970: 1002))
        XCTAssertEqual(report.items[2].tier, .checkFirst)
    }

    /// 执行器漏报的项不默认成功。
    func testUnreportedItemsCountAsFailed() async {
        let plan = CleanPlan(items: [candidates[0]])
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome())
        let report = await CleanRunner.run(plan, using: spy)
        XCTAssertEqual(report.items[0].outcome, .failed(reason: "执行器未报告结果"))
        XCTAssertEqual(report.freedBytes, 0)
    }

    func testEmptyPlanNeverTouchesExecutor() async {
        let spy = FakeCleanTrashExecutor()
        let report = await CleanRunner.run(CleanPlan(items: []), using: spy)
        let calls = await spy.recycleCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(report.items.isEmpty)
    }

    // MARK: 删前复核(p5-cleaner/03)

    /// 四态混排:没动过的照删;动过 / 已不在 / 无快照的跳过如实报,且**不交给执行器**。
    func testPreDeleteCheckSkipsChangedMissingAndSnapshotlessItems() async {
        let unchanged = candidate("/Users/t/Library/Caches/Homebrew", bytes: 3100)
        let changed = candidate("/Users/t/Library/Developer/Xcode/DerivedData", bytes: 28000)
        let vanished = candidate("/Users/t/.npm/_cacache", bytes: 500)
        let oldCache = candidate("/Users/t/.gradle/caches", bytes: 700, snapshot: nil)
        let plan = CleanPlan(items: [unchanged, changed, vanished, oldCache])
        let spy = FakeCleanTrashExecutor(
            nextRecycleOutcome: TrashRecycleOutcome(recycled: [unchanged.path: "/Users/t/.Trash/Homebrew"]),
            pathStates: [
                changed.path: .present(modifiedEpoch: CleanFixture.directoryModified + 3600),
                vanished.path: .missing,
            ]
        )

        let report = await CleanRunner.run(plan, using: spy)

        let calls = await spy.recycleCalls
        XCTAssertEqual(calls, [[unchanged.path]], "只有复核通过的项进执行器批次")
        let queried = await spy.stateQueries
        XCTAssertEqual(queried, plan.items.map(\.path), "计划里每一项都现查一次,同序")
        XCTAssertEqual(report.items.map(\.path), plan.items.map(\.path), "战报保持计划顺序")
        XCTAssertEqual(report.items[0].outcome, .recycled(destination: "/Users/t/.Trash/Homebrew"))
        XCTAssertEqual(
            report.items[1].outcome,
            .failed(reason: PreDeleteCheck.skipReason(.changed, origin: .scan) ?? "")
        )
        XCTAssertEqual(
            report.items[2].outcome,
            .failed(reason: PreDeleteCheck.skipReason(.missing, origin: .scan) ?? "")
        )
        XCTAssertEqual(
            report.items[3].outcome,
            .failed(reason: PreDeleteCheck.skipReason(.noSnapshot, origin: .scan) ?? "")
        )
        XCTAssertEqual(report.freedBytes, 3100, "跳过项不计释放量")
        XCTAssertEqual(report.recycledPaths, [unchanged.path], "清单收敛只收真进了废纸篓的")
    }

    func testAllItemsSkippedNeverCallsRecycle() async {
        let item = candidate("/Users/t/Library/Caches/Homebrew")
        let spy = FakeCleanTrashExecutor(pathStates: [item.path: .unreadable])
        let report = await CleanRunner.run(CleanPlan(items: [item]), using: spy)
        let calls = await spy.recycleCalls
        XCTAssertTrue(calls.isEmpty, "全部复核不过 = 执行器零调用")
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.freedBytes, 0)
    }

    func testPlanCountsItemsWithoutSnapshotForConfirmSheet() {
        let plan = CleanPlan(items: [
            candidate("/a"),
            candidate("/b", snapshot: nil),
            candidate("/c", snapshot: nil),
        ])
        XCTAssertEqual(plan.itemsWithoutSnapshot.map(\.path), ["/b", "/c"], "确认单提前说明会被跳过的项")
    }
}

/// 注入钟:每次读取 +1 秒(1001, 1002, …)。NSLock 串行化唯一可变状态,锁内无 await。
private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        tick += 1
        return Date(timeIntervalSince1970: TimeInterval(1000 + tick))
    }
}
