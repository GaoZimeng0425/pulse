@testable import Pulse
import PulseCore
import XCTest

/// 卸载残留接线(p5-cleaner/02):全集随 phase 落位、fail-closed 整组不出且如实说、
/// 与规则表重叠让位、地图角标同源、三组排序独立、缓存装载同样采集。
/// 采集器注入固定结果——零真盘、不读本机 /Applications。
@MainActor
final class CleanerOrphanWiringTests: XCTestCase {
    private let home = "/Users/test"

    private func makeEnumerator() -> FakeCleanDirectoryEnumerator {
        FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(home: home, directories: [
            "Library/Caches/com.gone.app": 4_000_000,
            "Library/Logs/com.gone.app": 1_000_000,
            "Library/Caches/com.still.here": 2_000_000,
            // 规则表认领的 CLI 缓存(无 .app):孤儿检测也会报,须让位
            "Library/Caches/org.swift.swiftpm": 3_000_000,
            "Library/Caches/Homebrew": 3_100_000,
        ]))
    }

    /// 采集器调用记录(扫描任务在后台调;锁保护)。
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(treeCount: Int, cancelled: Bool, home: String)] = []

        func append(_ entry: (Int, Bool, String)) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(entry)
        }

        var all: [(treeCount: Int, cancelled: Bool, home: String)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func scannedModel(
        _ inventory: InstalledAppInventory,
        log: CallLog = CallLog()
    ) async -> CleanerModel {
        let model = CleanerModel(
            trash: FakeCleanTrashExecutor(),
            homeDirectory: home,
            installedAppInventory: { trees, cancelled, home in
                log.append((trees.count, cancelled, home))
                return inventory
            }
        )
        model.startScan(using: makeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        return model
    }

    private func orphans(_ model: CleanerModel) -> [JunkCandidate] {
        model.candidates.filter { $0.group == .uninstallLeftovers }
    }

    // MARK: 主路径

    func testCompleteInventoryListsOrphansGroupedByFullBundleID() async {
        let log = CallLog()
        let model = await scannedModel(.complete(["com.still.here"]), log: log)
        // p6-cleaner/01:「应用日志」规则认领整个 Library/Logs,Logs 域孤儿让位
        // (同 swiftpm 让位先例——规则表逐条担保强于「不在已装清单」的推断)。
        XCTAssertEqual(Set(orphans(model).map(\.path)), [
            home + "/Library/Caches/com.gone.app",
        ], "已装的 com.still.here 不报;Logs 域被应用日志规则吃掉,只剩 Caches 孤儿")
        XCTAssertTrue(orphans(model).allSatisfy { $0.projectName == "com.gone.app" }, "大卡分组键 = 全 bundle id")
        XCTAssertTrue(model.orphanDetectionActive, "页头注记「含卸载残留检测」的判据")
        XCTAssertNil(model.orphanDetectionUnavailableReason)
        XCTAssertEqual(log.all.count, 1, "随结果一次采集,不随渲染重跑")
        XCTAssertEqual(log.all.first?.home, home, "与清单同一家目录口径")
        XCTAssertEqual(log.all.first?.cancelled, false)
        XCTAssertEqual(log.all.first?.treeCount, 1, "采集器拿到的是本次扫描树")
    }

    func testRuleTableOverlapKeepsSingleCard() async {
        let model = await scannedModel(.complete([]))
        let swiftpm = model.candidates.filter { $0.path == home + "/Library/Caches/org.swift.swiftpm" }
        XCTAssertEqual(swiftpm.count, 1, "同路径只有一张卡(Identifiable id = path,重复会勾一联动二)")
        XCTAssertEqual(swiftpm.first?.group, .globalToolCache, "规则表担保的说明与档位优先")
    }

    // MARK: fail-closed

    func testUnreadablePlistFailsClosedButOtherGroupsStay() async {
        let model = await scannedModel(.unreadablePlist(bundlePath: "/Applications/Bad.app"))
        XCTAssertTrue(orphans(model).isEmpty, "全集不完整无权判孤儿:整组不出")
        XCTAssertTrue(model.candidates.contains { $0.ruleID == "homebrew.cache" }, "其他组照常")
        XCTAssertFalse(model.orphanDetectionActive)
        XCTAssertTrue(
            model.orphanDetectionUnavailableReason?.contains("/Applications/Bad.app") == true,
            "「没查」如实说是哪个 app 读不了"
        )
    }

    func testIncompleteScanFailsClosed() async {
        let model = await scannedModel(.incompleteScan)
        XCTAssertTrue(orphans(model).isEmpty)
        XCTAssertNotNil(model.orphanDetectionUnavailableReason)
    }

    // MARK: 地图角标(轻桥同源)

    func testMapResolverMarksOrphanDirectoriesAndTheirInsides() async {
        let model = await scannedModel(.complete(["com.still.here"]))
        let resolve = model.mapCleanableResolver()
        XCTAssertEqual(resolve(home + "/Library/Caches/com.gone.app"), .uninstallLeftovers)
        XCTAssertEqual(resolve(home + "/Library/Caches/com.gone.app/deep/er"), .uninstallLeftovers, "孤儿内部同可清")
        XCTAssertEqual(resolve(home + "/Library/Caches/Homebrew"), .globalToolCache, "规则表照旧")
        XCTAssertEqual(resolve(home + "/Library/Caches/org.swift.swiftpm"), .globalToolCache, "让位后地图也认规则表")
        XCTAssertNil(resolve(home + "/Library/Caches/com.still.here"), "已装 app 的缓存零暗示")
        XCTAssertNil(resolve(home + "/Library/Caches"), "祖先块不标(不是整块能清)")
    }

    func testMapResolverSilentWhenDetectionUnavailable() async {
        let model = await scannedModel(.unreadablePlist(bundlePath: "/Applications/Bad.app"))
        XCTAssertNil(model.mapCleanableResolver()(home + "/Library/Caches/com.gone.app"), "清单没有的,地图也不标")
    }

    // MARK: 排序 / 缓存装载

    func testSortOrdersAreIndependentPerGroup() async {
        let model = await scannedModel(.complete([]))
        model.setSortOrder(.age, for: .uninstallLeftovers)
        XCTAssertEqual(model.sortOrder(for: .uninstallLeftovers), .age)
        XCTAssertEqual(model.sortOrder(for: .projectArtifacts), .size, "三组互不影响")
        XCTAssertEqual(model.sortOrder(for: .globalToolCache), .size)
    }

    func testCacheLoadCollectsInventoryAgain() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var payload: SpaceScanCachePayload?
            var value: SpaceScanCachePayload? {
                get { lock.lock()
                    defer { lock.unlock() }
                    return payload
                }
                set { lock.lock()
                    defer { lock.unlock() }
                    payload = newValue
                }
            }
        }
        let box = Box()
        let cache = CleanScanResultStore(load: { box.value }, save: { box.value = $0 })
        let first = CleanerModel(
            scanCache: cache,
            homeDirectory: home,
            installedAppInventory: { _, _, _ in .complete([]) }
        )
        first.startScan(using: makeEnumerator(), roots: [home])
        await waitUntil { !first.isScanning }
        XCTAssertNotNil(box.value)

        // 新会话装载缓存:全集按此刻现采(装机后新装的 app 立即受保护)。
        let log = CallLog()
        let second = CleanerModel(
            scanCache: cache,
            homeDirectory: home,
            installedAppInventory: { trees, cancelled, home in
                log.append((trees.count, cancelled, home))
                return .complete(["com.gone.app"])
            }
        )
        second.loadCachedScan()
        await waitUntil { second.result != nil }
        XCTAssertEqual(log.all.count, 1, "缓存装载同样采一次")
        XCTAssertEqual(
            Set(orphans(second).map(\.path)),
            [home + "/Library/Caches/com.still.here"],
            "判定跟此刻现采的全集走:重装的 com.gone.app 不再是孤儿,不在新全集的 com.still.here 成了孤儿"
        )
        XCTAssertTrue(second.orphanDetectionActive)
    }

    // MARK: 年龄人话(大卡头排恒「今天动过」的回归)

    func testAgeTextCountsPastDaysForward() {
        let now: TimeInterval = 1_700_000_000
        XCTAssertEqual(JunkAgeText.ago(sinceEpoch: now - 3 * 86400, now: now), "3 天前动过", "旧实现对过去时刻取负,恒落今天")
        XCTAssertEqual(JunkAgeText.ago(sinceEpoch: now - 3600, now: now), "今天动过")
        XCTAssertEqual(JunkAgeText.ago(sinceEpoch: now - 90 * 86400, now: now), "3 个月前动过")
        XCTAssertEqual(JunkAgeText.ago(sinceEpoch: now - 800 * 86400, now: now), "2 年前动过")
        XCTAssertEqual(JunkAgeText.idle(sinceEpoch: now - 45 * 86400, now: now), "1 个月未动")
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
