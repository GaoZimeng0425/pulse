import Observation
@testable import Pulse
import PulseCore
import XCTest

/// 菜单栏徽标显示快照模型(badge-hysteresis/01,app 薄壳):观察环
/// (withObservationTracking 自续)驱动折算,死区内不换、越死区换、网络直通。
/// 死区语义本身的逐例覆盖在 PulseCore 的 BadgeDisplayHysteresisTests,
/// 这里只钉"观察 → 折算 → 条件赋值"的连线。
@MainActor
final class MenuBarBadgeDisplayModelTests: XCTestCase {
    /// 首读整体采纳;死区内抖动显示不动;越死区换字(红线即时性由状态机测试钉死)。
    func testAppliesHysteresisToObservedChanges() async {
        let source = BadgeSourceStub()
        let model = MenuBarBadgeDisplayModel(raw: { source.value })
        model.start()
        XCTAssertEqual(model.data.cpuLoadPercent, 38.0)

        source.value = MenuBarBadgeData(cpuLoadPercent: 39.4)
        await drainMainActor()
        XCTAssertEqual(model.data.cpuLoadPercent, 38.0)

        source.value = MenuBarBadgeData(cpuLoadPercent: 41.0)
        await drainMainActor()
        XCTAssertEqual(model.data.cpuLoadPercent, 41.0)

        source.value = MenuBarBadgeData(cpuLoadPercent: 69.9)
        await drainMainActor()
        XCTAssertEqual(model.data.cpuLoadPercent, 69.9)
    }

    /// 网络速率槽直通:源每轮变,显示跟着每轮变(开网络槽的配置照旧逐轮刷新)。
    func testNetworkRatePassesThroughModel() async {
        let source = BadgeSourceStub()
        let model = MenuBarBadgeDisplayModel(raw: { source.value })
        model.start()

        let next = NetworkRates(upBytesPerSecond: 102, downBytesPerSecond: 2048)
        source.value = MenuBarBadgeData(cpuLoadPercent: 38.0, networkRate: next)
        await drainMainActor()
        XCTAssertEqual(model.data.networkRate, next)
    }

    /// onChange 经 MainActor Task 跳拍后重挂观察;yield 轮询让排队任务先跑。
    private func drainMainActor(_ iterations: Int = 50) async {
        for _ in 0 ..< iterations {
            await Task.yield()
        }
    }
}

/// 被观察的读数源:@Observable 桩,写入即触发模型的 onChange。
@MainActor
@Observable
private final class BadgeSourceStub {
    var value = MenuBarBadgeData(cpuLoadPercent: 38.0)
}
