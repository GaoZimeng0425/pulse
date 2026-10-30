@testable import Pulse
import PulseCore
import XCTest

/// 清理页状态机(p4-cleaner/03):生命周期 / 结果缓存 / FDA 判据来自台账 /
/// 重扫替换。枚举器走协议注入(TestSupport 假实现)——零真盘、零等待真扫描。
@MainActor
final class CleanerModelTests: XCTestCase {
    func testScanFinishesAndCachesResultWithFDAHint() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("a.bin", allocated: 512, reclaimable: 512),
                CleanFixture.directory("sub", fileID: 9),
                CleanFixture.directory("locked", fileID: 10),
            ]),
            "/r/sub": .entries([CleanFixture.file("b.bin", allocated: 256, reclaimable: 256)]),
            "/r/locked": .failure(.permissionDenied),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])

        await waitUntil { !model.isScanning }

        guard case let .finished(result) = model.phase else {
            XCTFail("应到 finished,实际 \(model.phase)")
            return
        }
        XCTAssertEqual(result.stats.files, 2)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(model.permissionDeniedCount, 1)
        XCTAssertTrue(model.permissionHint?.contains("1 个目录") == true, "FDA 判据来自台账,非预探测")
        // 结果缓存:不重扫 phase 不变,重进 tab 沿用
        XCTAssertEqual(model.result?.stats.files, 2)
        XCTAssertNotNil(model.scanFinishedAt)
    }

    func testRescanReplacesResult() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("v1.bin", allocated: 128, reclaimable: 128)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertEqual(model.result?.stats.files, 1)

        await fake.set("/r", .entries([
            CleanFixture.file("v2a.bin", allocated: 128, reclaimable: 128),
            CleanFixture.file("v2b.bin", allocated: 128, reclaimable: 128),
        ]))
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(model.result?.stats.files, 2, "重扫替换旧结果")
    }

    /// 零权限失败 → 无 FDA 横幅(不骚扰)。
    func testNoHintWhenNoPermissionFailures() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("a.bin", allocated: 64, reclaimable: 64)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertNil(model.permissionHint)
    }

    // MARK: 删除管线(p4-cleaner/04)——清单 → 勾选 → 确认 → spy 执行 → 历史 → 清单收敛

    private let home = "/Users/test"

    private func makeHomeEnumerator(extra: [String: Int64] = [:]) -> FakeCleanDirectoryEnumerator {
        var dirs: [String: Int64] = [
            "Library/Developer/Xcode/DerivedData": 28000,
            "Library/Caches/Homebrew": 3100,
            "Documents/DerivedData": 9999, // 似是而非:不在白名单
        ]
        dirs.merge(extra) { _, new in new }
        return FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(home: home, directories: dirs))
    }

    private func waitForCleanFinished(_ model: CleanerModel) async {
        await waitUntil {
            if case .finished = model.cleanPhase {
                true
            } else {
                false
            }
        }
    }

    /// 整条竖井:白名单清单(似是而非不出现)、默认全不勾、确认后 spy 收到恰好选中的路径、
    /// 历史落库与清单内容一致、已回收项从清单消失、勾选收敛。
    func testCleanPipelineEndToEndWithSpyAndInMemoryHistory() async throws {
        let derivedPath = home + "/Library/Developer/Xcode/DerivedData"
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [derivedPath: home + "/.Trash/DerivedData"]
        ))
        let history = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let model = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            history: history,
            trash: spy,
            homeDirectory: home
        )
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(
            model.candidates.map(\.ruleID),
            ["xcode.derivedData", "homebrew.cache"],
            "似是而非的 Documents/DerivedData 不出现"
        )
        XCTAssertTrue(model.selection.isEmpty, "默认全不勾")
        XCTAssertTrue(model.plan.isEmpty)
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .idle, "没选东西就没有确认清单")

        let derived = model.candidates[0]
        model.toggle(derived)
        XCTAssertTrue(model.isSelected(derived))
        XCTAssertEqual(model.plan.items.map(\.path), [derivedPath])
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .confirming)
        model.confirmClean()
        await waitForCleanFinished(model)

        guard case let .finished(report, historyRecorded) = model.cleanPhase else {
            XCTFail("应到 finished,实际 \(model.cleanPhase)")
            return
        }
        XCTAssertTrue(historyRecorded)
        XCTAssertEqual(report.freedBytes, 28000)
        XCTAssertTrue(report.failed.isEmpty)
        let calls = await spy.recycleCalls
        XCTAssertEqual(calls, [[derivedPath]], "spy 收到恰好选中的那一条,绝不多")
        XCTAssertEqual(model.candidates.map(\.ruleID), ["homebrew.cache"], "已回收项不再列")
        XCTAssertTrue(model.selection.isEmpty, "勾选随清单收敛")
        XCTAssertEqual(model.recycledPaths, [derivedPath])

        let runs = try await history.runs()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].freedBytes, 28000)
        let items = try await history.items(runID: runs[0].id)
        XCTAssertEqual(items.map(\.path), [derivedPath], "历史写入与清单内容一致")
        XCTAssertEqual(items[0].outcome, .recycled(destination: home + "/.Trash/DerivedData"))

        await model.loadHistory()
        XCTAssertEqual(model.historyRuns?.count, 1)
        await model.loadHistoryItems(runID: runs[0].id)
        XCTAssertEqual(model.historyItems[runs[0].id]?.count, 1)

        model.dismissCleanReport()
        XCTAssertEqual(model.cleanPhase, .idle)
    }

    /// 失败项如实报:仍留在清单里(没进废纸篓),战报与历史都记失败原因。
    func testFailedItemsStayListedAndAreReported() async throws {
        let derivedPath = home + "/Library/Developer/Xcode/DerivedData"
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            failures: [derivedPath: "Operation not permitted"]
        ))
        let history = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let model = CleanerModel(history: history, trash: spy, homeDirectory: home)
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        model.toggle(model.candidates[0])
        model.requestClean()
        model.confirmClean()
        await waitForCleanFinished(model)

        guard case let .finished(report, _) = model.cleanPhase else {
            XCTFail("应到 finished")
            return
        }
        XCTAssertEqual(report.failed.map(\.path), [derivedPath])
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertTrue(model.candidates.contains { $0.path == derivedPath }, "没删掉的仍在清单")
        let runs = try await history.runs()
        let items = try await history.items(runID: runs[0].id)
        XCTAssertEqual(items[0].outcome, .failed(reason: "Operation not permitted"))
    }

    /// 历史库缺席:照常清理,战报标"未记录"。
    func testHistoryUnavailableStillCleans() async {
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [home + "/Library/Caches/Homebrew": home + "/.Trash/Homebrew"]
        ))
        let model = CleanerModel(history: nil, trash: spy, homeDirectory: home)
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        XCTAssertFalse(model.historyAvailable)
        model.toggle(model.candidates[1])
        model.requestClean()
        model.confirmClean()
        await waitForCleanFinished(model)

        guard case let .finished(report, historyRecorded) = model.cleanPhase else {
            XCTFail("应到 finished")
            return
        }
        XCTAssertFalse(historyRecorded)
        XCTAssertEqual(report.recycled.count, 1)
    }

    /// 右键排除:清单即时收窄(不重扫)、勾选脱落、持久化;再扫描该目录不被碰。
    func testExcludeNarrowsImmediatelyPersistsAndSkipsOnRescan() async throws {
        var persisted: [[String]] = []
        let exclusions = CleanExclusionsStore(load: { [] }, persist: { persisted.append($0) })
        let model = CleanerModel(exclusions: exclusions, trash: FakeCleanTrashExecutor(), homeDirectory: home)
        let fake = makeHomeEnumerator()
        model.startScan(using: fake, roots: [home])
        await waitUntil { !model.isScanning }
        let homebrew = try XCTUnwrap(model.candidates.first { $0.ruleID == "homebrew.cache" })
        model.toggle(homebrew)
        XCTAssertEqual(model.plan.items.count, 1)

        model.exclude(homebrew.path)

        XCTAssertEqual(model.candidates.map(\.ruleID), ["xcode.derivedData"], "排除立即生效,不必重扫")
        XCTAssertTrue(model.plan.isEmpty, "被排除的项即使勾过也不进计划")
        XCTAssertEqual(persisted, [[homebrew.path]])
        XCTAssertEqual(model.excludedPathPrefixes, [homebrew.path])

        let requestsBefore = await fake.requestedPathCount(homebrew.path)
        model.startScan(using: fake, roots: [home])
        await waitUntil { !model.isScanning }
        let requestsAfter = await fake.requestedPathCount(homebrew.path)
        XCTAssertEqual(requestsAfter, requestsBefore, "重扫时排除目录不再被枚举(扫描侧生效)")
        XCTAssertEqual(model.candidates.map(\.ruleID), ["xcode.derivedData"])
    }

    func testCancelFromConfirmReturnsToIdle() async {
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), homeDirectory: home)
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        model.toggle(model.candidates[0])
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .confirming)
        model.cancelClean()
        XCTAssertEqual(model.cleanPhase, .idle)
        XCTAssertEqual(model.plan.items.count, 1, "取消确认不动勾选")
    }

    // MARK: 整组勾选(2026-10-30 拍板 B:只勾组内「可安全清理」项,先检查项单独勾)

    func testGroupToggleSelectsOnlySafeTierAndCyclesBack() async {
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), homeDirectory: home)
        model.startScan(
            using: makeHomeEnumerator(extra: ["Library/Caches/JetBrains": 5400]),
            roots: [home]
        )
        await waitUntil { !model.isScanning }

        let safe = model.candidates.filter { $0.tier == .safe }
        let checkFirst = model.candidates.filter { $0.tier == .checkFirst }
        XCTAssertEqual(Set(safe.map(\.ruleID)), ["xcode.derivedData", "homebrew.cache"])
        XCTAssertEqual(checkFirst.map(\.ruleID), ["jetbrains.caches"])

        // none → 一键全勾:只勾 safe 档,先检查项不被带上
        XCTAssertEqual(model.groupState(of: safe), .none)
        model.toggleGroup(safe)
        XCTAssertEqual(model.groupState(of: safe), .all)
        XCTAssertEqual(model.plan.items.count, 2)
        XCTAssertFalse(model.plan.items.contains { $0.tier == .checkFirst }, "先检查项必须逐个手勾")

        // all → 一键全清:用户手勾的先检查项保留
        model.toggle(checkFirst[0])
        model.toggleGroup(safe)
        XCTAssertEqual(model.groupState(of: safe), .none)
        XCTAssertEqual(model.plan.items.map(\.ruleID), ["jetbrains.caches"], "组全清不碰组外的勾")

        // mixed(手勾一个再点组头)→ 全勾
        model.toggleGroup(safe)
        model.toggle(safe[0])
        XCTAssertEqual(model.groupState(of: safe), .mixed)
        model.toggleGroup(safe)
        XCTAssertEqual(model.groupState(of: safe), .all)
        XCTAssertEqual(model.plan.items.count, 3)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待条件超时(10s)")
    }
}
