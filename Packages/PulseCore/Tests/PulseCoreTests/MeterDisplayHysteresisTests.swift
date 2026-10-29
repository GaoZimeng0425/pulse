@testable import PulseCore
import XCTest

/// meter 条显示迟滞(popover-layout-loop/01,纯值判定):死区边界、对称性、锚在
/// 已显示值不累积、慢漂移不被卡死。阈值(0.03 归一占比)为死区口径与徽标 ±2pp
/// 同源拍板,末例把它钉死——改参数必须有意识地改测试。
final class MeterDisplayHysteresisTests: XCTestCase {
    let displayed = 0.20

    /// 抖动小于阈值:不追平(不进 SwiftUI 事务、不起 0.6s 缓动)。
    func testWithinDeadbandDoesNotRetarget() {
        XCTAssertFalse(MeterDisplayHysteresis.shouldRetarget(displayed: displayed, incoming: displayed + 0.029))
        XCTAssertFalse(MeterDisplayHysteresis.shouldRetarget(displayed: displayed, incoming: displayed - 0.029))
        XCTAssertFalse(MeterDisplayHysteresis.shouldRetarget(displayed: displayed, incoming: displayed))
    }

    /// 差恰为阈值即追,上行下行同阈值(对称死区)。
    func testAtDeadbandEdgeRetargetsInBothDirections() {
        XCTAssertTrue(MeterDisplayHysteresis.shouldRetarget(displayed: displayed, incoming: displayed + 0.03))
        XCTAssertTrue(MeterDisplayHysteresis.shouldRetarget(displayed: displayed, incoming: displayed - 0.03))
    }

    /// 锚在已显示值:1s 档读数在阈值内侧反复横跳,永远不追;离开 ≥ 阈值才追——
    /// 慢漂移(每轮 +0.01)不会被卡死,漂到第三轮即跨阈值。
    func testSlowRampEventuallyRetargets() {
        var shown = 0.20
        // 每轮 +0.01,前两轮在死区内。
        XCTAssertFalse(MeterDisplayHysteresis.shouldRetarget(displayed: shown, incoming: 0.21))
        XCTAssertFalse(MeterDisplayHysteresis.shouldRetarget(displayed: shown, incoming: 0.22))
        // 第三轮跨过 0.23 = 阈值,追平后锚点前移,误差不累积。
        XCTAssertTrue(MeterDisplayHysteresis.shouldRetarget(displayed: shown, incoming: 0.23))
        shown = 0.23
        XCTAssertFalse(MeterDisplayHysteresis.shouldRetarget(displayed: shown, incoming: 0.24))
    }

    /// 榜首条归一恒为 1.0,本身无变化;换榜首后归一跳变远超死区,立即追。
    func testLeaderNormalizationJumpsRetarget() {
        XCTAssertTrue(MeterDisplayHysteresis.shouldRetarget(displayed: 1.0, incoming: 0.5))
        XCTAssertTrue(MeterDisplayHysteresis.shouldRetarget(displayed: 0.1, incoming: 1.0))
    }

    /// 参数钉死:改死区必须有意识地改这里(口径与 GLOSSARY「显示迟滞」一致)。
    func testDeadbandConstantPinned() {
        XCTAssertEqual(MeterDisplayHysteresis.deadbandFraction, 0.03, accuracy: 1e-12)
    }
}
