@testable import Pulse
import PulseCore
import XCTest

/// 通用发现接线(p7-cleaner/02):名单外的目录进清单、与规则表重叠让位、总览与地图同源、
/// 「所属应用在运行」读清单时现查、生成确认清单前重采。运行中应用与已装全集都注入
/// 固定结果——零真盘,不读系统的工作区应用列表。
@MainActor
final class CleanerGenericDiscoveryWiringTests: XCTestCase {
    private let home = "/Users/test"
    private var toolPath: String {
        home + "/Library/Caches/SomeTool"
    }

    private var runningAppPath: String {
        home + "/Library/Caches/com.running.app"
    }

    private var editorCachePath: String {
        home + "/Library/Application Support/SomeEditor/Cache"
    }

    private var swiftpmPath: String {
        home + "/Library/Caches/org.swift.swiftpm"
    }

    /// 运行中应用(测试中途切换 = 应用启动 / 退出)与采集次数。class 是刻意的:模型捕获
    /// 同一个实例。
    /// `@unchecked Sendable` 的前提:`apps` 与 `collections` 的全部访问都经 `lock`——采集
    /// 闭包是 `@Sendable`(模型在主线程调它),测试在主线程改 `apps`、读计数,彼此隔锁。
    private final class RunningAppsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var apps: [RunningAppIdentity]
        private var collections = 0

        init(_ apps: [RunningAppIdentity]) {
            self.apps = apps
        }

        func setRunning(_ apps: [RunningAppIdentity]) {
            lock.lock()
            defer { lock.unlock() }
            self.apps = apps
        }

        var collectionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return collections
        }

        var source: @Sendable () -> [RunningAppIdentity] {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                collections += 1
                return apps
            }
        }
    }

    /// 落盘缓存的替身(缓存装载用例)。
    /// `@unchecked Sendable` 的前提:`stored` 的读写全部经 `lock`——模型把 load / save 两个
    /// `@Sendable` 闭包交给扫描与缓存装载的后台任务调,与测试主线程的读写隔锁。
    private final class PayloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SpaceScanCachePayload?

        var payload: SpaceScanCachePayload? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }
    }

    /// 假家目录:两个名单外的缓存目录、一个应用数据目录(名字明确的缓存子目录 + 一个
    /// 数据库子目录)、一个规则表认领的缓存。
    private func makeEnumerator() -> FakeCleanDirectoryEnumerator {
        FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(home: home, directories: [
            "Library/Caches/SomeTool": 700_000,
            "Library/Caches/com.running.app": 300_000,
            "Library/Application Support/SomeEditor/Cache": 400_000,
            "Library/Application Support/SomeEditor/IndexedDB": 900_000,
            "Library/Caches/org.swift.swiftpm": 3_000_000,
        ]))
    }

    private func makeModel(
        running: RunningAppsBox,
        inventory: InstalledAppInventory = .complete(["com.running.app"]),
        trash: FakeCleanTrashExecutor = FakeCleanTrashExecutor(),
        scanCache: CleanScanResultStore? = nil
    ) -> CleanerModel {
        // 读数新鲜期给一小时:「不报信就沿用上一份」的断言不依赖机器快慢。
        CleanerModel.testing(
            trash: trash,
            scanCache: scanCache,
            homeDirectory: home,
            installedAppInventory: { _, _, _ in inventory },
            runningApps: running.source,
            runningAppsFreshness: 3600
        )
    }

    private func scannedModel(
        running: RunningAppsBox,
        inventory: InstalledAppInventory = .complete(["com.running.app"]),
        trash: FakeCleanTrashExecutor = FakeCleanTrashExecutor(),
        scanCache: CleanScanResultStore? = nil
    ) async -> CleanerModel {
        let model = makeModel(running: running, inventory: inventory, trash: trash, scanCache: scanCache)
        model.startScan(using: makeEnumerator(), roots: [home])
        await waitUntil(!model.isScanning)
        return model
    }

    private func generic(_ model: CleanerModel) -> [JunkCandidate] {
        model.candidates.filter { $0.ruleID == GenericDiscovery.ruleID }
    }

    private func genericEntry(_ model: CleanerModel, at path: String) throws -> JunkCandidate {
        try XCTUnwrap(generic(model).first { $0.path == path }, "清单里没有 \(path)")
    }

    private func isCleanFinished(_ model: CleanerModel) -> Bool {
        if case .finished = model.cleanPhase {
            return true
        }
        return false
    }

    // MARK: 主路径

    /// 名单外的目录进清单:缓存目录的一级条目、应用数据目录里名字明确的缓存子目录;一律
    /// 「先检查」+「未识别」,归应用缓存组。存放数据库的子目录不列;规则表认领的目录
    /// 只有规则表那一张卡。
    func testUnlistedEntriesAppearAsCheckFirstUnidentified() async {
        let model = await scannedModel(running: RunningAppsBox([]))

        let entries = generic(model)

        XCTAssertEqual(Set(entries.map(\.path)), [toolPath, runningAppPath, editorCachePath])
        XCTAssertTrue(entries.allSatisfy {
            $0.tier == .checkFirst && $0.flags == [.unidentified] && $0.group == .appCache
        })
        let swiftpm = model.candidates.filter { $0.path == swiftpmPath }
        XCTAssertEqual(swiftpm.count, 1, "同路径只有一张卡(重复会勾一联动二)")
        XCTAssertEqual(swiftpm.first?.ruleID, "swiftpm.cache", "规则表担保的说明与档位优先")
    }

    /// 通用发现不依赖已装全集:全集读不出来时卸载残留整组不出,名单外的缓存照列——
    /// 它只说「这是个没人认领的缓存」,不说「它的应用已卸载」。
    func testGenericEntriesDoNotDependOnInstalledInventory() async {
        let model = await scannedModel(
            running: RunningAppsBox([]),
            inventory: .unreadablePlist(bundlePath: "/Applications/Bad.app")
        )

        XCTAssertFalse(model.orphanDetectionActive)
        XCTAssertEqual(Set(generic(model).map(\.path)), [toolPath, runningAppPath, editorCachePath])
    }

    /// 重启后装载上次扫描的结果,清单里同样有名单外的条目(判定只依赖扫描树)。
    func testCachedScanListsGenericEntries() async {
        let box = PayloadBox()
        let cache = CleanScanResultStore(load: { box.payload }, save: { box.payload = $0 })
        _ = await scannedModel(running: RunningAppsBox([]), scanCache: cache)
        XCTAssertNotNil(box.payload)

        let second = makeModel(running: RunningAppsBox([]), scanCache: cache)
        second.loadCachedScan()
        await waitUntil(second.result != nil)

        XCTAssertEqual(Set(generic(second).map(\.path)), [toolPath, runningAppPath, editorCachePath])
    }

    // MARK: 所属应用在运行(读清单时现查)

    /// 所属应用在运行的条目不出现;应用退出后不重扫就回来——「谁在运行」是读清单时现查的,
    /// 不进扫描结果。
    func testRunningAppEntriesDisappearAndReturnWithoutRescan() async {
        let running = RunningAppsBox([RunningAppIdentity(bundleID: "com.running.app", names: [])])
        let model = await scannedModel(running: running)
        XCTAssertEqual(Set(generic(model).map(\.path)), [toolPath, editorCachePath])

        running.setRunning([])
        XCTAssertEqual(Set(generic(model).map(\.path)), [toolPath, editorCachePath], "还没人报信:沿用上一份读数")

        model.noteRunningAppsMayHaveChanged()
        XCTAssertEqual(Set(generic(model).map(\.path)), [toolPath, runningAppPath, editorCachePath], "报信后重采,不重扫")
    }

    /// 读清单要现查「谁在运行」,而一次渲染会读好几遍:新鲜期内、没人报信,重复读只采
    /// 一次;报信后下一次读重采。
    func testRepeatedReadsShareOneCollectionUntilNotified() async {
        let running = RunningAppsBox([])
        let model = await scannedModel(running: running)
        let afterScan = running.collectionCount
        XCTAssertGreaterThanOrEqual(afterScan, 1, "扫描落位时读过一次清单")

        _ = model.candidates
        _ = model.junkOverview
        _ = model.plan
        XCTAssertEqual(running.collectionCount, afterScan, "读了好几遍,没有再采")

        model.noteRunningAppsMayHaveChanged()
        _ = model.candidates
        XCTAssertEqual(running.collectionCount, afterScan + 1, "报信后重采一次")
    }

    /// 勾好之后、点「清理」之前应用才启动(还没人报信):生成确认清单前重采,它的缓存
    /// 不进清单。
    func testRequestCleanRechecksRunningApps() async throws {
        let running = RunningAppsBox([])
        let model = await scannedModel(running: running)
        try model.toggle(genericEntry(model, at: toolPath))
        try model.toggle(genericEntry(model, at: runningAppPath))
        XCTAssertEqual(model.plan.items.count, 2)

        running.setRunning([RunningAppIdentity(bundleID: "com.running.app", names: [])])
        model.requestClean()

        XCTAssertEqual(model.cleanPhase, .confirming)
        XCTAssertEqual(model.plan.items.map(\.path), [toolPath])
    }

    /// 确认单挂着的时候应用启动了:点「移入废纸篓」那一刻重采,它的缓存不跟着走。
    func testConfirmCleanRechecksRunningApps() async throws {
        let running = RunningAppsBox([])
        let spy = FakeCleanTrashExecutor()
        let model = await scannedModel(running: running, trash: spy)
        try model.toggle(genericEntry(model, at: toolPath))
        try model.toggle(genericEntry(model, at: runningAppPath))
        model.requestClean()
        guard case .confirming = model.cleanPhase else {
            return XCTFail("应到 confirming,实际 \(model.cleanPhase)")
        }

        running.setRunning([RunningAppIdentity(bundleID: "com.running.app", names: [])])
        model.confirmClean()
        await waitUntil(isCleanFinished(model))

        let calls = await spy.recycleCalls
        XCTAssertEqual(calls, [[toolPath]], "只移走仍不在运行的那一条")
    }

    // MARK: 自动勾选 / 总览 / 地图

    /// 空态说明要把「查了没有」与「有但此刻没显示」分开:有因应用在运行而不显示的条目时
    /// 报出有几项,没有时不提。
    func testHiddenRunningAppEntryCountFeedsEmptyStateCopy() async {
        let running = RunningAppsBox([])
        let model = await scannedModel(running: running)
        XCTAssertEqual(model.hiddenRunningAppEntryCount, 0)
        let plainCopy = CleanerEmptyStateCopy.nothingFoundDetail(hiddenRunningAppEntries: 0)
        XCTAssertTrue(plainCopy.contains("没有可回收项"))
        XCTAssertFalse(plainCopy.contains("正在运行"), "没有隐藏条目就不提这件事")

        running.setRunning([RunningAppIdentity(bundleID: "com.running.app", names: [])])
        model.noteRunningAppsMayHaveChanged()
        XCTAssertEqual(model.hiddenRunningAppEntryCount, 1, "所属目录是 com.running.app 的那一条;别的条目不算")
        XCTAssertTrue(
            CleanerEmptyStateCopy.nothingFoundDetail(hiddenRunningAppEntries: 1).contains("另有 1 项属于正在运行的应用")
        )
    }

    /// 「一键清理安全项」永远不勾通用发现的条目——它们不在安全档;规则表的安全项照常。
    func testSelectAllSafeNeverPicksGenericEntries() async {
        let model = await scannedModel(running: RunningAppsBox([]))

        model.selectAllSafeAndRequestClean()

        XCTAssertEqual(model.cleanPhase, .confirming)
        XCTAssertEqual(model.plan.items.map(\.ruleID), ["swiftpm.cache"])
    }

    /// 总览照常吃进名单外的条目:归应用缓存那一行,全部计入「先检查」。
    func testOverviewCountsGenericEntriesAsCheckFirst() async throws {
        let model = await scannedModel(running: RunningAppsBox([]))

        let row = try XCTUnwrap(model.junkOverview.row(for: .appCache))

        XCTAssertEqual(row.itemCount, 3)
        XCTAssertEqual(row.checkBytes, 1_400_000)
        XCTAssertEqual(row.safeBytes, 0)
    }

    /// 空间地图的「可清理」角标只标名单担保过的块:通用发现的条目在清单里,地图上不标。
    func testMapResolverLeavesGenericEntriesUnmarked() async {
        let model = await scannedModel(running: RunningAppsBox([]))
        let resolve = model.mapCleanableResolver()

        XCTAssertNil(resolve(toolPath))
        XCTAssertNil(resolve(editorCachePath))
        XCTAssertEqual(resolve(swiftpmPath), .globalToolCache, "规则表照旧")
    }
}
