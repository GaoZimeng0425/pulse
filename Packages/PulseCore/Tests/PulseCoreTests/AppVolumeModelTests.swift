@testable import PulseCore
import XCTest

// MARK: - 每应用音量纯逻辑测试(app-volume/01;合成夹具,零 CoreAudio)

final class AppVolumeModelTests: XCTestCase {
    // MARK: 曲线

    func testCurveSquareBelowUnity() {
        // 100% 以下滑块位平方:50% ≈ −12dB(0.25)、25% ≈ −24dB(0.0625)。
        XCTAssertEqual(AppVolumeCurve.gain(for: 0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(AppVolumeCurve.gain(for: 0.25), 0.0625, accuracy: 0.0001)
        XCTAssertEqual(AppVolumeCurve.gain(for: 0), 0)
        XCTAssertEqual(AppVolumeCurve.gain(for: 1), 1)
    }

    func testCurveLinearAboveUnity() {
        // 100% 以上线性(引擎保留 0–200%;UI 本期封顶 100%)。
        XCTAssertEqual(AppVolumeCurve.gain(for: 2), 2)
        XCTAssertEqual(AppVolumeCurve.gain(for: 1.5), 1.5)
    }

    func testCurveClampsAndSurvivesBadInput() {
        XCTAssertEqual(AppVolumeCurve.gain(for: 5), 2)
        XCTAssertEqual(AppVolumeCurve.gain(for: -1), 0)
        // 非有限值一律回直通 1(UI 滑只会给有限值,这是防御;mixbar 同款)。
        XCTAssertEqual(AppVolumeCurve.gain(for: .nan), 1)
        XCTAssertEqual(AppVolumeCurve.gain(for: .infinity), 1)
    }

    // MARK: 设置载荷

    func testSettingsDefaultsToUnity() {
        let settings = AppVolumeSettings()
        XCTAssertEqual(settings.volume(for: "com.apple.Music"), 1)
        XCTAssertFalse(settings.isMuted("com.apple.Music"))
    }

    func testSettingsVolumeDragClearsMute() {
        // 动滑块 = 要听:拖动即取消静音(mixbar 同款语义)。
        let muted = AppVolumeSettings().withMute(true, for: "key")
        XCTAssertTrue(muted.isMuted("key"))
        let dragged = muted.withVolume(0.5, for: "key")
        XCTAssertFalse(dragged.isMuted("key"))
        XCTAssertEqual(dragged.volume(for: "key"), 0.5)
        // 拖到 0 不取消**已有**静音(0 = 静音的另一种形态);但也不会给没静音的行重新静音。
        XCTAssertTrue(muted.withVolume(0, for: "key").isMuted("key"))
        XCTAssertFalse(dragged.withVolume(0, for: "key").isMuted("key"))
    }

    func testSettingsRejectsNonFinite() {
        let settings = AppVolumeSettings().withVolume(.nan, for: "key").withVolume(.infinity, for: "key2")
        XCTAssertEqual(settings.volume(for: "key"), 1)
        XCTAssertEqual(settings.volume(for: "key2"), 1)
    }

    func testSettingsCodecRoundTrip() {
        var settings = AppVolumeSettings()
        settings.volumes = ["com.apple.Music": 0.4, "pid:999": 0]
        settings.mutes = ["pid:999", "com.apple.Terminal"]
        let decoded = AppVolumeSettings.decode(settings.encode())
        XCTAssertEqual(decoded, settings)
    }

    func testSettingsDecodeBadDataFallsBackToEmpty() {
        XCTAssertEqual(AppVolumeSettings.decode(nil), AppVolumeSettings())
        // 坏数据 = 空设置,不抛、不半载。
        XCTAssertEqual(AppVolumeSettings.decode(Data("not json".utf8)), AppVolumeSettings())
    }

    func testSettingsDecodeClampsOutOfRangeValues() {
        let json = #"{"volumes":{"a":7.5,"b":-2,"c":0.5},"mutes":["z"]}"#
        let decoded = AppVolumeSettings.decode(Data(json.utf8))
        XCTAssertEqual(decoded.volume(for: "a"), 1)
        XCTAssertEqual(decoded.volume(for: "b"), 0)
        XCTAssertEqual(decoded.volume(for: "c"), 0.5)
        XCTAssertTrue(decoded.isMuted("z"))
    }

    // MARK: 归并

    private func client(_ objectID: UInt32, pid: Int32, bundle: String?, playing: Bool) -> AppVolumeClient {
        AppVolumeClient(objectID: objectID, pid: pid, bundleID: bundle, isPlaying: playing)
    }

    func testGroupingMergesSameAppClients() {
        // 浏览器多 helper:同 bundleID 归一行,processIDs 并集升序,任一播放即播放。
        let attributed = [
            AttributedVolumeClient(
                client: client(7, pid: 101, bundle: "org.mozilla.firefox", playing: false),
                appKey: "org.mozilla.firefox",
                appName: "Firefox",
                appBundleID: "org.mozilla.firefox"
            ),
            AttributedVolumeClient(
                client: client(3, pid: 102, bundle: "org.mozilla.firefox", playing: true),
                appKey: "org.mozilla.firefox",
                appName: "Firefox",
                appBundleID: "org.mozilla.firefox"
            ),
            AttributedVolumeClient(
                client: client(9, pid: 103, bundle: "com.apple.Music", playing: false),
                appKey: "com.apple.Music",
                appName: "音乐",
                appBundleID: "com.apple.Music"
            ),
        ]
        let entries = AppVolumeGrouping.entries(from: attributed, settings: AppVolumeSettings())
        XCTAssertEqual(entries.count, 2)
        let firefox = entries.first { $0.id == "org.mozilla.firefox" }
        XCTAssertEqual(firefox?.processIDs, [3, 7])
        XCTAssertEqual(firefox?.isPlaying, true)
        XCTAssertEqual(firefox?.volume, 1)
        // 排序按名称本地化排序实测口径钉死(本机 zh 排序「音乐」在 "Firefox" 前)。
        XCTAssertEqual(entries.map(\.id), ["com.apple.Music", "org.mozilla.firefox"])
    }

    /// 条目身份跟**宿主**走,不跟 helper 的 bundle 走——图标/身份查宿主才对。
    func testGroupingTakesOwnerBundleNotHelperForIdentity() {
        let attributed = [
            AttributedVolumeClient(
                client: client(5, pid: 50, bundle: "org.mozilla.firefox.helper", playing: true),
                appKey: "org.mozilla.firefox",
                appName: "Firefox",
                appBundleID: "org.mozilla.firefox"
            ),
            AttributedVolumeClient(
                client: client(6, pid: 51, bundle: nil, playing: false),
                appKey: "pid:51",
                appName: "无名音频进程",
                appBundleID: nil
            ),
        ]
        let entries = AppVolumeGrouping.entries(from: attributed, settings: AppVolumeSettings())
        XCTAssertEqual(entries.first { $0.id == "org.mozilla.firefox" }?.bundleID, "org.mozilla.firefox")
        XCTAssertNil(entries.first { $0.id == "pid:51" }?.bundleID)
    }

    func testGroupingAppliesSavedSettings() {
        let settings = AppVolumeSettings(volumes: ["com.apple.Music": 0.5], mutes: ["pid:42"])
        let attributed = [
            AttributedVolumeClient(
                client: client(1, pid: 10, bundle: "com.apple.Music", playing: true),
                appKey: "com.apple.Music",
                appName: "音乐",
                appBundleID: "com.apple.Music"
            ),
            AttributedVolumeClient(
                client: client(2, pid: 42, bundle: nil, playing: true),
                appKey: "pid:42",
                appName: "无名音频进程",
                appBundleID: nil
            ),
        ]
        let entries = AppVolumeGrouping.entries(from: attributed, settings: settings)
        XCTAssertEqual(entries.first { $0.id == "com.apple.Music" }?.volume, 0.5)
        XCTAssertEqual(entries.first { $0.id == "pid:42" }?.isMuted, true)
        // 静音行的期望增益 = 0;0.5 滑块位 = 0.25 增益;未配置 = 1(直通)。
        XCTAssertEqual(entries.first { $0.id == "pid:42" }?.desiredGain, 0)
        XCTAssertEqual(entries.first { $0.id == "com.apple.Music" }?.desiredGain ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(entries.first { $0.id == "com.apple.Music" }?.isControlled, false)
    }

    func testGroupingEmptyInput() {
        XCTAssertEqual(AppVolumeGrouping.entries(from: [], settings: AppVolumeSettings()), [])
    }
}
