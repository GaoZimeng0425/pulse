import GRDB
@testable import PulseCore
import XCTest

/// 卸载执行编排(p4-uninstaller/03):brew 三分支、改道核对、失败跳过、
/// 重查拒绝、zap 覆盖判定、回执防御。全 spy 注入,零真盘零真 brew。
final class AppUninstallRunnerTests: XCTestCase {
    private func plan(
        appPath: String = "/Applications/Demo.app",
        caskName: String? = nil,
        permanent: Bool = false,
        leftovers: [(path: String, checkFirst: Bool, bytes: Int64)] = [],
        zap: [String] = []
    ) -> AppUninstallPlan {
        AppUninstallPlan(
            appPath: appPath,
            appName: "Demo",
            appBytes: 1000,
            caskName: caskName,
            permanent: permanent,
            leftoverItems: leftovers.map {
                AppLeftoverRow(
                    path: $0.path, site: .caches, matchKey: "k",
                    source: .generic, isCheckFirst: $0.checkFirst, sizeBytes: $0.bytes,
                    modifiedAtProbe: Self.probedModified
                )
            },
            receiptZapPaths: zap
        )
    }

    /// 残留探测快照与删前探针默认一致(「列出后没动过」);复核用例逐路径改写。
    private static let probedModified: Double = 1_600_000_000
    private static let unchangedState: @Sendable (String) async -> PathSnapshot = { _ in
        .present(modifiedEpoch: probedModified)
    }

    private struct Spies {
        var recycled: [String] = []
        var deleted: [String] = []
        var brewCalls: [(cask: String, zap: Bool)] = []
        var recycleOutcome = TrashRecycleOutcome()
        var deleteOutcome = PermanentDeletionOutcome()
        var brewResult: BrewUninstallResult = .success
    }

    private func makeRunner(spies: Spies) -> (
        recycle: @Sendable ([String]) async -> TrashRecycleOutcome,
        delete: @Sendable ([String]) async -> PermanentDeletionOutcome,
        brew: @Sendable (String, Bool) async -> BrewUninstallResult
    ) {
        let box = SpyBox(spies)
        return (
            recycle: { paths in
                await box.appendRecycled(paths)
                return await box.recycleOutcome()
            },
            delete: { paths in
                await box.appendDeleted(paths)
                return await box.deleteOutcome()
            },
            brew: { cask, zap in
                await box.appendBrew(cask, zap: zap)
                return await box.brewResult()
            }
        )
    }

    /// spies 需跨 @Sendable 闭包读写 → actor 盒(锁与 actor 二选一,测试用 actor)。
    private actor SpyBox {
        var spies: Spies
        init(_ spies: Spies) {
            self.spies = spies
        }

        func appendRecycled(_ paths: [String]) {
            spies.recycled.append(contentsOf: paths)
        }

        func appendDeleted(_ paths: [String]) {
            spies.deleted.append(contentsOf: paths)
        }

        func appendBrew(_ cask: String, zap: Bool) {
            spies.brewCalls.append((cask, zap))
        }

        func recycleOutcome() -> TrashRecycleOutcome {
            spies.recycleOutcome
        }

        func deleteOutcome() -> PermanentDeletionOutcome {
            spies.deleteOutcome
        }

        func brewResult() -> BrewUninstallResult {
            spies.brewResult
        }

        func snapshot() -> Spies {
            spies
        }
    }

    // MARK: 删除前重查

    func testRunningAppRejectedBeforeAnyAction() async {
        var spies = Spies()
        spies.brewResult = .success
        let runner = makeRunner(spies: spies)
        let termination = await AppUninstallRunner.run(
            plan(),
            recycle: runner.recycle, deletePermanently: runner.delete, brewUninstall: runner.brew,
            isAppRunning: { _ in true },
            crossCheckCask: { _ in nil },
            leftoverState: Self.unchangedState
        )
        guard case .rejectedRunning = termination else {
            return XCTFail("应被运行重查拒绝,得到 \(termination)")
        }
    }

    // MARK: 非 brew

    func testNonBrewDefaultRecyclesAppAndLeftovers() async {
        let termination = await runNonBrew(permanent: false, spySeed: Spies(), outcome: .recycledAll)
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.items.filter(\.isRecycled).count, 2, "app + 残留全进废纸篓")
        XCTAssertEqual(report.freedBytes, 1000 + 50)
    }

    func testNonBrewPermanentDeletesAll() async {
        let termination = await runNonBrew(permanent: true, spySeed: Spies(), outcome: .deletedAll)
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(
            report.items.map(\.outcome),
            [
                .permanentlyDeleted(route: .direct),
                .permanentlyDeleted(route: .direct),
            ]
        )
        XCTAssertEqual(report.freedBytes, 1050, "永久删除也计入释放(Q14 口径)")
    }

    func testNonBrewFailureSkipsAndReportsHonestly() async {
        // 残留失败、app 成功:跳过失败项,战报如实(Q9)。
        let termination = await runNonBrew(permanent: false, spySeed: Spies(), outcome: .partial)
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(report.items.filter(\.isReleased).count, 1)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(report.freedBytes, 1000, "失败项不计释放")
    }

    func testNonBrewExecutorSilenceCountsAsFailure() async {
        // 执行器对某路径既没报成功也没报失败 → 按失败记(一期同款防御)。
        let termination = await runNonBrew(permanent: false, spySeed: Spies(), outcome: .silent)
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(report.failed.count, 2)
    }

    /// 非 brew 分支共用装配(回执按 outcome 形态喂)。
    private enum NonBrewOutcome { case recycledAll, deletedAll, partial, silent }

    private func runNonBrew(permanent: Bool, spySeed: Spies, outcome: NonBrewOutcome) async -> AppUninstallTermination {
        var spies = spySeed
        let paths = ["/Applications/Demo.app", NSHomeDirectory() + "/Library/Caches/k"]
        switch outcome {
        case .recycledAll:
            spies.recycleOutcome = TrashRecycleOutcome(recycled: Dictionary(uniqueKeysWithValues: paths.map { (
                $0,
                "/Users/x/.Trash/x"
            ) }))
        case .deletedAll:
            spies.deleteOutcome = PermanentDeletionOutcome(deleted: Set(paths))
        case .partial:
            spies.recycleOutcome = TrashRecycleOutcome(
                recycled: [paths[0]: "/Users/x/.Trash/x"],
                failures: [paths[1]: "权限不足"]
            )
        case .silent:
            break // 全部沉默
        }
        let runner = makeRunner(spies: spies)
        return await AppUninstallRunner.run(
            plan(permanent: permanent, leftovers: [(path: paths[1], checkFirst: false, bytes: 50)]),
            recycle: runner.recycle, deletePermanently: runner.delete, brewUninstall: runner.brew,
            isAppRunning: { _ in false },
            crossCheckCask: { _ in nil },
            leftoverState: Self.unchangedState
        )
    }

    // MARK: 改道核对(Q11)

    func testCrossCheckFindBrewYieldsRerouteAndAcknowledgedRerunProceeds() async {
        let spies = Spies()
        let runner = makeRunner(spies: spies)
        let p = plan()
        let first = await AppUninstallRunner.run(
            p,
            recycle: runner.recycle, deletePermanently: runner.delete, brewUninstall: runner.brew,
            isAppRunning: { _ in false },
            crossCheckCask: { _ in "demo-cask" },
            leftoverState: Self.unchangedState
        )
        guard case let .needsReroute(cask) = first else {
            return XCTFail("应触发改道,得到 \(first)")
        }
        XCTAssertEqual(cask, "demo-cask")

        // 用户「仍要直接删文件」→ rerouteAcknowledged 重跑,不再核对,直接执行。
        var okSeed = Spies()
        okSeed.recycleOutcome = TrashRecycleOutcome(recycled: [p.appPath: "/Users/x/.Trash/Demo.app"])
        let okRunner = makeRunner(spies: okSeed)
        let second = await AppUninstallRunner.run(
            p,
            recycle: okRunner.recycle, deletePermanently: okRunner.delete, brewUninstall: okRunner.brew,
            isAppRunning: { _ in false },
            crossCheckCask: { _ in "demo-cask" }, // 核对仍会命中,但 acknowledged 跳过
            leftoverState: Self.unchangedState,
            rerouteAcknowledged: true
        )
        guard case .completed = second else {
            return XCTFail("确认后应执行,得到 \(second)")
        }
    }

    // MARK: brew 分支

    private func runBrew(
        permanent: Bool,
        zap: [String],
        brewResult: BrewUninstallResult,
        deleteOutcome: PermanentDeletionOutcome = PermanentDeletionOutcome(),
        recycleOutcome: TrashRecycleOutcome = TrashRecycleOutcome()
    ) async -> AppUninstallTermination {
        var spies = Spies()
        spies.brewResult = brewResult
        spies.deleteOutcome = deleteOutcome
        spies.recycleOutcome = recycleOutcome
        let runner = makeRunner(spies: spies)
        return await AppUninstallRunner.run(
            plan(caskName: "demo", permanent: permanent, leftovers: [
                (path: NSHomeDirectory() + "/Library/Application Support/Demo", checkFirst: false, bytes: 90),
                (path: NSHomeDirectory() + "/Library/Caches/k", checkFirst: false, bytes: 50),
            ], zap: zap),
            recycle: runner.recycle, deletePermanently: runner.delete, brewUninstall: runner.brew,
            isAppRunning: { _ in false },
            crossCheckCask: { _ in nil },
            leftoverState: Self.unchangedState
        )
    }

    func testBrewMissingAbortsBeforeAnyFileAction() async {
        let termination = await runBrew(permanent: false, zap: [], brewResult: .brewMissing)
        guard case let .aborted(reason) = termination else {
            return XCTFail("缺 brew 应中止,得到 \(termination)")
        }
        XCTAssertTrue(reason.contains("Homebrew") || reason.contains("brew"))
    }

    func testBrewFailureAbortsBeforeAnyFileAction() async {
        let termination = await runBrew(permanent: false, zap: [], brewResult: .failed(message: "cask 不存在"))
        guard case .aborted = termination else {
            return XCTFail("brew 失败应中止,得到 \(termination)")
        }
    }

    func testBrewDefaultUninstallAppPermanentAndLeftoversRecycled() async {
        let leftoverPaths = [
            NSHomeDirectory() + "/Library/Application Support/Demo",
            NSHomeDirectory() + "/Library/Caches/k",
        ]
        let termination = await runBrew(
            permanent: false, zap: [], brewResult: .success,
            recycleOutcome: TrashRecycleOutcome(recycled: Dictionary(uniqueKeysWithValues: leftoverPaths.map { (
                $0,
                "/Users/x/.Trash/x"
            ) }))
        )
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(report.items.first?.outcome, .permanentlyDeleted(route: .brew), "app 本体恒 brew 路由")
        XCTAssertEqual(report.items.first?.ruleID, "app-uninstall")
        XCTAssertEqual(report.items.dropFirst().filter(\.isRecycled).count, 2, "残留默认进废纸篓")
        XCTAssertEqual(report.freedBytes, 1000 + 90 + 50)
    }

    func testBrewZapCoversReceiptDeclaredLeftoversRestDeletedDirectly() async {
        let declared = NSHomeDirectory() + "/Library/Application Support/Demo" // zap 声明
        let undeclared = NSHomeDirectory() + "/Library/Caches/k" // 通用位置,zap 没写
        let termination = await runBrew(
            permanent: true, zap: [declared], brewResult: .success,
            deleteOutcome: PermanentDeletionOutcome(deleted: [undeclared])
        )
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(
            report.items.map(\.outcome),
            [
                .permanentlyDeleted(route: .brew), // app
                .permanentlyDeleted(route: .brew), // zap 声明域 → brew 带走
                .permanentlyDeleted(route: .direct), // 未覆盖 → 我们直删
            ]
        )
    }

    // MARK: 历史(去向新枚举落库)

    func testHistoryRoundTripsPermanentRoutes() async throws {
        let queue = try DatabaseQueue()
        try HistoryDatabase.migrator().migrate(queue)
        let store = CleanHistoryStore(database: queue)
        let report = CleanRunReport(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
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
                    path: "/x/a",
                    title: "缓存",
                    bytes: 50,
                    tier: .safe,
                    ruleID: "app-leftover",
                    outcome: .permanentlyDeleted(route: .direct)
                ),
                CleanRunItem(
                    path: "/x/b",
                    title: "设置",
                    bytes: 4,
                    tier: .safe,
                    ruleID: "app-leftover",
                    outcome: .recycled(destination: "/Users/x/.Trash/b")
                ),
            ]
        )
        let runID = try await store.record(report)
        let items = try await store.items(runID: XCTUnwrap(runID))
        XCTAssertEqual(items.map(\.outcome), [
            .permanentlyDeleted(route: .brew),
            .permanentlyDeleted(route: .direct),
            .recycled(destination: "/Users/x/.Trash/b"),
        ], "新去向经库往返不丢路由(迁移列 permanent_route)")
        let runs = try await store.runs()
        XCTAssertEqual(runs.first?.freedBytes, 1054, "永久删除计入释放")
    }
}
