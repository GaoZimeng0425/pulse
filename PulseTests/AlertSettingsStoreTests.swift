import XCTest
@testable import Pulse

/// 接缝:告警规则配置持久层(UserDefaults 注入独立 suite,ProjectRootsStore 同款)。
/// 钉死:预设默认值、编解码往返、缺项/坏数据回落预设、改动即写即生效、
/// isAnyEnabled 的 0→1 迁移(授权时序锚点)与 hasRequestedAuthorization。
@MainActor
final class AlertSettingsStoreTests: XCTestCase {

    /// 每测独立的 UserDefaults suite;测试结束清理持久域,不留垃圾 plist。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AlertSettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    // MARK: - 预设默认值

    func testDefaultsArePresetsAllDisabled() {
        let store = AlertSettingsStore(defaults: makeDefaults())
        for kind in AlertKind.allCases {
            let config = store.config(for: kind)
            XCTAssertEqual(config.isEnabled, false, "\(kind) 默认关闭(首次开启才请求授权的前提)")
            XCTAssertEqual(config.threshold, kind.preset.threshold, "\(kind) 阈值默认 = 预设值")
        }
        XCTAssertFalse(store.isAnyEnabled)
    }

    // MARK: - 改动即写即持久

    func testSetThresholdPersistsAndTakesEffectImmediately() {
        let defaults = makeDefaults()
        let store = AlertSettingsStore(defaults: defaults)

        store.setThreshold(85, for: .systemLoad)

        XCTAssertEqual(store.config(for: .systemLoad).threshold, 85, "内存中即时生效")
        // 重开一读:落盘可恢复(键名即持久化契约)。
        let reloaded = AlertSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.config(for: .systemLoad).threshold, 85)
        // 其余种类不受影响。
        XCTAssertEqual(reloaded.config(for: .groupCPU).threshold, AlertKind.groupCPU.preset.threshold)
    }

    func testSetEnabledPersistsAndDrivesAnyEnabled() {
        let defaults = makeDefaults()
        let store = AlertSettingsStore(defaults: defaults)

        store.setEnabled(true, for: .diskAvailable)
        XCTAssertTrue(store.isAnyEnabled, "0→1 迁移:授权时序的触发点")
        XCTAssertEqual(AlertSettingsStore(defaults: defaults).config(for: .diskAvailable).isEnabled, true)

        store.setEnabled(true, for: .systemLoad)
        store.setEnabled(false, for: .diskAvailable)
        XCTAssertTrue(store.isAnyEnabled, "还有别条开着")
        store.setEnabled(false, for: .systemLoad)
        XCTAssertFalse(store.isAnyEnabled)
    }

    func testMarkAuthorizationRequestedPersistsOnce() {
        let defaults = makeDefaults()
        let store = AlertSettingsStore(defaults: defaults)
        XCTAssertFalse(store.hasRequestedAuthorization)

        store.markAuthorizationRequested()
        XCTAssertTrue(store.hasRequestedAuthorization)
        XCTAssertTrue(AlertSettingsStore(defaults: defaults).hasRequestedAuthorization, "跨启动持久(首次才请求的判定依据)")
    }

    // MARK: - 坏数据防御

    func testCorruptedPayloadFallsBackToPresets() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: AlertSettingsStore.storageKey)
        let store = AlertSettingsStore(defaults: defaults)
        XCTAssertEqual(store.config(for: .systemLoad).threshold, AlertKind.systemLoad.preset.threshold)
    }

    func testUnknownKindsInPayloadAreIgnored() {
        let defaults = makeDefaults()
        // 手写一份带未知 kind 的合法载荷:未知键忽略,已知键保留。
        let payload = """
        {"systemLoad":{"isEnabled":true,"threshold":60},"timeMachineFull":{"isEnabled":true,"threshold":1}}
        """
        defaults.set(Data(payload.utf8), forKey: AlertSettingsStore.storageKey)
        let store = AlertSettingsStore(defaults: defaults)
        XCTAssertEqual(store.config(for: .systemLoad).threshold, 60)
        XCTAssertFalse(store.config(for: .groupCPU).isEnabled, "缺项回落预设")
    }
}
