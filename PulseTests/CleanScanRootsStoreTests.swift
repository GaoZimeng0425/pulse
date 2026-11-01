@testable import Pulse
@testable import PulseCore
import XCTest

/// 清理扫描根的持久层(p4-cleaner/05):增删即落盘、重启保留、"/" 拒收、重复幂等。
/// 与归组 ProjectRootsStore 的键("projectRoots")互不相同——两套配置零共享是
/// 用户拍板,这里把键名分开钉死。
///
/// 键名字面量 "cleanerScanRoots" 是独立事实来源:键名即持久化契约,改动会 orphan 旧数据。
@MainActor
final class CleanScanRootsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "CleanScanRootsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { [suiteName] in
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testInitLoadsPersistedRootsNormalized() {
        let defaults = makeDefaults()
        defaults.set(["/Users/x/Documents/Learn/macos/"], forKey: "cleanerScanRoots")
        XCTAssertEqual(
            CleanScanRootsStore(defaults: defaults).paths,
            ["/Users/x/Documents/Learn/macos"],
            "尾斜杠归一"
        )
    }

    func testInitDropsRootVolumePath() {
        let defaults = makeDefaults()
        defaults.set(["/", "/Users/x/code"], forKey: "cleanerScanRoots")
        XCTAssertEqual(
            CleanScanRootsStore(defaults: defaults).paths,
            ["/Users/x/code"],
            "\"/\" 是全卷扫描不是项目根,拒收"
        )
    }

    func testAddIsIdempotentAndPersistsAcrossRestart() {
        let defaults = makeDefaults()
        let store = CleanScanRootsStore(defaults: defaults)
        store.add("/Users/x/Documents/Learn/macos")
        store.add("/Users/x/Documents/Learn/macos/")
        XCTAssertEqual(store.paths.count, 1, "归一后重复幂等")
        XCTAssertEqual(
            CleanScanRootsStore(defaults: defaults).paths.count,
            1,
            "落盘可读回(重启语义)"
        )
    }

    func testRemoveUnknownPathIsNoop() {
        let defaults = makeDefaults()
        let store = CleanScanRootsStore(defaults: defaults)
        store.add("/Users/x/code")
        store.remove("/Users/x/nope")
        XCTAssertEqual(store.paths, ["/Users/x/code"])
    }

    func testStorageKeyIsDistinctFromAttributionRoots() {
        // 两套配置零共享(用户拍板):键名必须不同,谁也不读谁的。
        XCTAssertNotEqual(CleanScanRootsStore.storageKey, "projectRoots")
        XCTAssertNotEqual(CleanScanRootsStore.storageKey, CleanExclusionsStore.storageKey)
    }
}
