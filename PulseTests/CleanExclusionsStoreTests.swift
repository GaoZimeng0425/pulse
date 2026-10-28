@testable import Pulse
@testable import PulseCore
import XCTest

/// 排除目录的持久层(p4-cleaner/04):增删即落盘(UserDefaults 注入独立 suite 隔离),
/// 重启(新 store 读同一 defaults)后列表保留;语义(只收窄、覆盖去重)由 PulseCore
/// CleanExclusions 提供,这里只验持久化与"变了才落盘"。
///
/// 键名字面量 "cleanerExcludedPaths" 是独立事实来源:键名即持久化契约,改动会 orphan 旧数据。
@MainActor
final class CleanExclusionsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "CleanExclusionsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { [suiteName] in
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testInitLoadsPersistedPathsNormalizedAndDeduped() {
        let defaults = makeDefaults()
        defaults.set(["/Users/x/.gradle/", "/Users/x/.gradle", "/Users/x/.gradle/caches"], forKey: "cleanerExcludedPaths")

        XCTAssertEqual(CleanExclusionsStore(defaults: defaults).paths, ["/Users/x/.gradle"])
    }

    func testInitWithoutPersistedValueStartsEmpty() {
        XCTAssertTrue(CleanExclusionsStore(defaults: makeDefaults()).paths.isEmpty)
    }

    func testAddAndRemovePersistAcrossRestart() {
        let defaults = makeDefaults()
        let store = CleanExclusionsStore(defaults: defaults)
        store.add("/Users/x/Library/Caches/JetBrains/")
        store.add("/Users/x/.npm")
        XCTAssertEqual(CleanExclusionsStore(defaults: defaults).paths, ["/Users/x/Library/Caches/JetBrains", "/Users/x/.npm"])

        store.remove("/Users/x/.npm")
        XCTAssertEqual(CleanExclusionsStore(defaults: defaults).paths, ["/Users/x/Library/Caches/JetBrains"])
    }

    /// 变了才落盘:重复加 / 被覆盖 / 删不存在的,不写 defaults。
    func testPersistOnlyOnChange() {
        var writes: [[String]] = []
        let store = CleanExclusionsStore(load: { ["/Users/x/Library"] }, persist: { writes.append($0) })

        store.add("/Users/x/Library")
        store.add("/Users/x/Library/Caches")
        store.remove("/nope")
        XCTAssertTrue(writes.isEmpty)

        store.add("/Users/x/.npm")
        XCTAssertEqual(writes, [["/Users/x/Library", "/Users/x/.npm"]])
        store.remove("/Users/x/Library")
        XCTAssertEqual(writes.last, ["/Users/x/.npm"])
    }
}
