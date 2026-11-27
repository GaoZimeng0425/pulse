@testable import Pulse
import PulseCore
import XCTest

/// 运行时授权接线(p7-cleaner/05;ADR-0012):系统级条目进清单、勾选、确认后走授权接口;
/// 授权被取消或通道不可用时整批不动、勾选保留、如实提示;走完的进清理历史并带「需要管理员
/// 权限」。授权接口与废纸篓执行器都是假实现——不提权、不弹密码框、零真盘。
@MainActor
final class CleanerSystemTrashWiringTests: XCTestCase {
    private let home = "/Users/test"
    private let reports = "/Library/Logs/DiagnosticReports"
    private let day: TimeInterval = 86400
    private var oldReport: String {
        reports + "/old.diag"
    }

    private var youngReport: String {
        reports + "/young.diag"
    }

    private var userCache: String {
        home + "/Library/Caches/Homebrew"
    }

    /// 假家目录(一个用户态缓存)+ 系统崩溃报告目录(一个放满 8 天的、一个一小时前的)。
    private func makeEnumerator(now: TimeInterval) -> FakeCleanDirectoryEnumerator {
        var listings = CleanFixture.homeListings(home: home, directories: ["Library/Caches/Homebrew": 3_100_000])
        listings["/Library"] = .entries([CleanFixture.directory("Logs", fileID: 9_100_001)])
        listings["/Library/Logs"] = .entries([CleanFixture.directory("DiagnosticReports", fileID: 9_100_002)])
        listings[reports] = .entries([
            CleanFixture.file("old.diag", logical: 4096, allocated: 4096, reclaimable: 4096, modified: now - 8 * day),
            CleanFixture.file("young.diag", logical: 100, allocated: 512, reclaimable: 512, modified: now - 3600),
        ])
        return FakeCleanDirectoryEnumerator(listings: listings)
    }

    /// 假废纸篓:删前复核对两份报告都放行——探针读数就是扫描夹具里那份修改时间,所以
    /// 和夹具用同一个时刻造,差一微秒都会被判成「扫描后有变动」。
    private func makeTrash(now: TimeInterval, recycled: [String: String]) -> FakeCleanTrashExecutor {
        FakeCleanTrashExecutor(
            nextRecycleOutcome: TrashRecycleOutcome(recycled: recycled),
            pathStates: [
                oldReport: .present(modifiedEpoch: now - 8 * day),
                youngReport: .present(modifiedEpoch: now - 3600),
            ]
        )
    }

    private func scannedModel(
        mover: FakeCleanSystemTrashExecutor,
        history: CleanHistoryStore? = nil,
        recycled: [String: String] = [:]
    ) async -> (model: CleanerModel, trash: FakeCleanTrashExecutor) {
        let now = Date().timeIntervalSince1970
        let spy = makeTrash(now: now, recycled: recycled)
        let model = CleanerModel.testing(
            history: history,
            trash: spy,
            systemTrash: mover,
            homeDirectory: home,
            installedAppInventory: { _, _, _ in .complete([]) }
        )
        model.startScan(using: makeEnumerator(now: now), roots: ["/Library", home])
        await waitUntil(!model.isScanning)
        return (model, spy)
    }

    private func isSettled(_ model: CleanerModel) -> Bool {
        switch model.cleanPhase {
        case .idle, .finished, .notStarted: true
        case .confirming, .running: false
        }
    }

    private func entry(_ model: CleanerModel, at path: String) throws -> JunkCandidate {
        try XCTUnwrap(model.candidates.first { $0.path == path }, "清单里没有 \(path)")
    }

    private func systemEntries(_ model: CleanerModel) -> [JunkCandidate] {
        model.candidates.filter { $0.flags.contains(.requiresAuthorization) }
    }

    // MARK: 清单

    /// 扫描后系统级条目进清单:放满 7 天的报告一条一个,带「需要管理员权限」,归系统级组;
    /// 太新的不列。文件节点是扫描时按规则的目录定向保留的。
    func testExpiredSystemReportsAppearInListAfterScan() async {
        let fixture = await scannedModel(mover: FakeCleanSystemTrashExecutor())

        let entries = systemEntries(fixture.model)

        XCTAssertEqual(entries.map(\.path), [oldReport])
        XCTAssertEqual(entries.first?.group, .systemLevel)
        XCTAssertEqual(entries.first?.tier, .safe)
        XCTAssertEqual(entries.first?.bytes, 4096)
        XCTAssertEqual(fixture.model.candidates.filter { $0.path == userCache }.count, 1, "用户态条目照旧")
    }

    // MARK: 走完

    /// 授权通过:系统级条目经授权接口移进废纸篓子目录,用户态条目照旧走废纸篓执行器;
    /// 清理历史里系统级那一条带「需要管理员权限」、去向是废纸篓子目录。
    func testAuthorizedRunMovesThroughMoverAndRecordsHistory() async throws {
        let destination = "/Users/test/.Trash/Pulse 系统级/2026-11-27 22.03/old.diag"
        let mover = FakeCleanSystemTrashExecutor(handler: { request in
            .completed(TrashRecycleOutcome(
                recycled: Dictionary(uniqueKeysWithValues: request.paths.map { ($0, destination) })
            ))
        })
        let history = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let fixture = await scannedModel(
            mover: mover, history: history, recycled: [userCache: "/Users/test/.Trash/Homebrew"]
        )
        for path in [oldReport, userCache] {
            try fixture.model.toggle(entry(fixture.model, at: path))
        }
        fixture.model.requestClean()
        XCTAssertEqual(fixture.model.cleanPhase, .confirming)
        fixture.model.confirmClean()
        await waitUntil(isSettled(fixture.model))

        guard case let .finished(report, historyRecorded) = fixture.model.cleanPhase else {
            return XCTFail("应走完,实际 \(fixture.model.cleanPhase)")
        }
        XCTAssertTrue(historyRecorded)
        XCTAssertEqual(mover.requests.map(\.paths), [[oldReport]], "授权接口收到的正是确认清单里的系统级条目")
        let calls = await fixture.trash.recycleCalls
        XCTAssertEqual(calls, [[userCache]], "系统级条目不混进废纸篓执行器")
        XCTAssertEqual(report.recycledPaths, [oldReport, userCache])
        XCTAssertEqual(fixture.model.recycledPaths, [oldReport, userCache], "清单收敛")

        let runs = try await history.runs()
        let items = try await history.items(runID: XCTUnwrap(runs.first?.id))
        let systemItem = try XCTUnwrap(items.first { $0.path == oldReport })
        XCTAssertEqual(systemItem.flags, [.requiresAuthorization])
        XCTAssertEqual(systemItem.outcome, .recycled(destination: destination))
    }

    // MARK: 没开始就停

    /// 用户在密码框点了取消:这一批都没动(用户态条目也没动),勾选保留,不落历史,
    /// 如实停在「没开始」;关掉提示后可以重新发起。
    func testCancelledAuthorizationKeepsEverythingAndSelection() async throws {
        let history = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let fixture = await scannedModel(
            mover: FakeCleanSystemTrashExecutor(handler: { _ in .authorizationCancelled }),
            history: history,
            recycled: [userCache: "/Users/test/.Trash/Homebrew"]
        )
        for path in [oldReport, userCache] {
            try fixture.model.toggle(entry(fixture.model, at: path))
        }
        fixture.model.requestClean()
        fixture.model.confirmClean()
        await waitUntil(isSettled(fixture.model))

        XCTAssertEqual(fixture.model.cleanPhase, .notStarted(.authorizationCancelled))
        let calls = await fixture.trash.recycleCalls
        XCTAssertTrue(calls.isEmpty, "取消授权 = 这一批都不动")
        XCTAssertEqual(fixture.model.plan.items.count, 2, "勾选保留")
        let runs = try await history.runs()
        XCTAssertTrue(runs.isEmpty, "没动任何东西,不落历史")
        XCTAssertEqual(fixture.model.recycledPaths, [])

        fixture.model.dismissCleanReport()
        XCTAssertEqual(fixture.model.cleanPhase, .idle)
        fixture.model.requestClean()
        XCTAssertEqual(fixture.model.cleanPhase, .confirming, "可以直接重新发起")
    }

    /// 通道不可用:同样整批不动、勾选保留,原因原样带到界面。
    func testUnavailableChannelIsReportedWithItsReason() async throws {
        let fixture = await scannedModel(
            mover: FakeCleanSystemTrashExecutor(handler: { _ in .channelUnavailable(reason: "复核脚本缺失(应用包不完整)") })
        )
        try fixture.model.toggle(entry(fixture.model, at: oldReport))
        fixture.model.requestClean()
        fixture.model.confirmClean()
        await waitUntil(isSettled(fixture.model))

        XCTAssertEqual(fixture.model.cleanPhase, .notStarted(.channelUnavailable(reason: "复核脚本缺失(应用包不完整)")))
        let calls = await fixture.trash.recycleCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(fixture.model.plan.items.count, 1, "勾选保留")
    }

    /// 「清理进行中」的门卫信号在没开始时也要放开:发一次 true、一次 false,不卡住退出。
    func testActivityGateIsReleasedWhenRunDoesNotStart() async throws {
        let gate = ActivityGateLog()
        let observer = NotificationCenter.default.addObserver(
            forName: CleanerModel.cleanActivityNotification, object: nil, queue: nil
        ) { notification in
            gate.record(notification.userInfo?["running"] as? Bool)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let fixture = await scannedModel(mover: FakeCleanSystemTrashExecutor(handler: { _ in .authorizationCancelled }))
        try fixture.model.toggle(entry(fixture.model, at: oldReport))

        fixture.model.requestClean()
        fixture.model.confirmClean()
        await waitUntil(isSettled(fixture.model))

        XCTAssertEqual(gate.values, [true, false])
    }
}

/// 清理活动门卫信号的记录。
/// `@unchecked Sendable` 的前提:`stored` 的全部访问都经 `lock`(通知回调在发帖线程上调)。
private final class ActivityGateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []

    func record(_ value: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            stored.append(value)
        }
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
