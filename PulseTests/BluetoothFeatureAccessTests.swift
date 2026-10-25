@testable import Pulse
@testable import PulseCore
import XCTest

/// 接缝:蓝牙授权原则(CODING_STANDARDS「权限 / TCC 纪律」,NemoNotch 同源)——
/// 默认关;设置开关 / 卡片按钮是唯一触发源;授权未决只在用户动作处请求一次;被拒
/// 绝不重试;启动路径与可见性切换绝不请求。闸 = 可见 ∧ 开启 ∧ 已授权,以 provider
/// 是否在采(`isCollecting`)钉死。假授权控制不碰蓝牙栈(测试纪律:外设栈不进单测)。
@MainActor
final class BluetoothFeatureAccessTests: XCTestCase {
    /// 假授权控制:记录显式请求次数;"系统答复"由测试调用挂起的回调触发。
    /// `@unchecked Sendable` 前提:测试全程在主线程串行调用。
    final class FakeAccess: BluetoothAccessControl, @unchecked Sendable {
        var state: BluetoothAuthorization
        private(set) var requestCount = 0
        private var pending: (@Sendable () -> Void)?

        init(_ state: BluetoothAuthorization) {
            self.state = state
        }

        func authorization() -> BluetoothAuthorization {
            state
        }

        func requestAccess(_ completion: @escaping @Sendable () -> Void) {
            requestCount += 1
            pending = completion
        }

        /// 模拟用户在系统弹窗上答复:落新状态并回调一次。
        func answer(_ newState: BluetoothAuthorization) {
            state = newState
            let completion = pending
            pending = nil
            completion?()
        }
    }

    /// 持久化盒:记录最后一次写入(nil = 从未写)。
    final class PersistBox {
        var last: Bool?
    }

    private let visible = MonitorVisibility(popover: true)
    private let hidden = MonitorVisibility()

    private func makeFeature(
        enabled: Bool,
        access: FakeAccess,
        persist: PersistBox = PersistBox()
    ) -> BluetoothFeature {
        BluetoothFeature(
            source: InertBluetoothSource(),
            access: access,
            probe: InertGattBatteryProbe(), // 闸关会调 cancel:惰性探针,不转蓝牙栈
            loadEnabled: { enabled },
            persistEnabled: { persist.last = $0 }
        )
    }

    /// 请求回调经 MainActor Task 落地,让出几拍等它跑完。
    private func settle() async {
        for _ in 0 ..< 5 {
            await Task.yield()
        }
    }

    // MARK: - 默认关

    func testDefaultDisabledNeverCollectsEvenWhenVisibleAndAuthorized() {
        let access = FakeAccess(.allowed)
        let feature = makeFeature(enabled: false, access: access)
        feature.visibilityChanged(visible)
        XCTAssertEqual(feature.accessState, .disabled)
        XCTAssertFalse(feature.isCollecting, "没开开关,可见 + 已授权也不采")
        XCTAssertEqual(access.requestCount, 0)
    }

    // MARK: - 开启 + 已授权:只随可见性采

    func testEnabledAndAuthorizedCollectsOnlyWhileVisible() {
        let feature = makeFeature(enabled: true, access: FakeAccess(.allowed))
        XCTAssertEqual(feature.accessState, .ready)
        XCTAssertFalse(feature.isCollecting, "不可见不采(常驻成本)")
        feature.visibilityChanged(visible)
        XCTAssertTrue(feature.isCollecting)
        feature.visibilityChanged(hidden)
        XCTAssertFalse(feature.isCollecting)
    }

    // MARK: - 用户动作处请求:开关是触发源,未决请求一次,授予即开闸

    func testEnablingWhenUndeterminedRequestsOnceAndOpensGateOnGrant() async {
        let access = FakeAccess(.notDetermined)
        let persist = PersistBox()
        let feature = makeFeature(enabled: false, access: access, persist: persist)
        feature.visibilityChanged(visible)
        XCTAssertEqual(access.requestCount, 0, "可见性切换绝不请求")

        feature.setEnabled(true)
        XCTAssertEqual(persist.last, true)
        XCTAssertEqual(access.requestCount, 1, "开关那一刻请求一次——弹窗只出现在用户动作处")
        XCTAssertEqual(feature.accessState, .needsAuthorization)
        XCTAssertFalse(feature.isCollecting, "系统未答复不采")

        access.answer(.allowed)
        await settle()
        XCTAssertEqual(feature.accessState, .ready)
        XCTAssertTrue(feature.isCollecting, "授予后自动开闸,无需再点")
    }

    func testUserDenyingInPromptYieldsDeniedStateAndNoRetry() async {
        let access = FakeAccess(.notDetermined)
        let feature = makeFeature(enabled: false, access: access)
        feature.visibilityChanged(visible)
        feature.setEnabled(true)
        access.answer(.denied)
        await settle()
        XCTAssertEqual(feature.accessState, .denied)
        XCTAssertFalse(feature.isCollecting)

        feature.requestAuthorization()
        feature.visibilityChanged(hidden)
        feature.visibilityChanged(visible)
        XCTAssertEqual(access.requestCount, 1, "被拒后任何路径都不再请求")
    }

    // MARK: - 启动路径绝不弹:重装(换 cdhash)后开关仍开、授权回到未决

    func testLaunchWithEnabledButUndeterminedDoesNotRequestUntilUserTaps() {
        let access = FakeAccess(.notDetermined)
        let feature = makeFeature(enabled: true, access: access)
        feature.visibilityChanged(visible)
        XCTAssertEqual(access.requestCount, 0, "启动 + 进场都只静默读,不弹")
        XCTAssertEqual(feature.accessState, .needsAuthorization)
        XCTAssertFalse(feature.isCollecting)

        feature.requestAuthorization() // 用户点卡片「授权蓝牙」
        XCTAssertEqual(access.requestCount, 1)
    }

    func testLaunchWithEnabledButDeniedNeverRequests() {
        let access = FakeAccess(.denied)
        let feature = makeFeature(enabled: true, access: access)
        feature.visibilityChanged(visible)
        feature.requestAuthorization()
        XCTAssertEqual(feature.accessState, .denied)
        XCTAssertEqual(access.requestCount, 0, "被拒态下按钮不请求——系统不会再弹,只能去系统设置")
        XCTAssertFalse(feature.isCollecting)
    }

    // MARK: - 关掉即停

    func testDisablingClosesGateAndPersists() {
        let persist = PersistBox()
        let feature = makeFeature(enabled: true, access: FakeAccess(.allowed), persist: persist)
        feature.visibilityChanged(visible)
        XCTAssertTrue(feature.isCollecting)

        feature.setEnabled(false)
        XCTAssertFalse(feature.isCollecting)
        XCTAssertEqual(feature.accessState, .disabled)
        XCTAssertEqual(persist.last, false)
    }

    // MARK: - 回前台静默刷新:用户在系统设置里改了

    func testRefreshPicksUpGrantMadeInSystemSettings() {
        let access = FakeAccess(.denied)
        let feature = makeFeature(enabled: true, access: access)
        feature.visibilityChanged(visible)
        XCTAssertEqual(feature.accessState, .denied)

        access.state = .allowed // 用户在 系统设置 › 隐私与安全性 › 蓝牙 里允许了
        feature.refreshAuthorization()
        XCTAssertEqual(feature.accessState, .ready)
        XCTAssertTrue(feature.isCollecting)
        XCTAssertEqual(access.requestCount, 0, "刷新是静默读,不请求")
    }
}
