@testable import PulseCore
import XCTest

/// meter 归一化(工单 P0.6-02,纯逻辑):占比条"按当前榜单榜首归一"的取值口径。
/// 像素渲染属预览 + 手动验收;这里钉死边界数学(榜首满条、空载不除零、越界夹紧)。
final class MeterBarTests: XCTestCase {
    func testLeaderGetsFullBar() {
        XCTAssertEqual(MeterNormalization.fraction(100, leader: 100), 1)
        XCTAssertEqual(MeterNormalization.fraction(445.2, leader: 445.2), 1, accuracy: 1e-9)
    }

    func testFractionProportionalToLeader() {
        XCTAssertEqual(MeterNormalization.fraction(50, leader: 100), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MeterNormalization.fraction(89.04, leader: 445.2), 0.2, accuracy: 1e-9)
    }

    /// 空载 / 空榜(榜首 ≤ 0):一律 0——不画填充,也不除零。
    func testZeroOrNegativeLeaderYieldsZero() {
        XCTAssertEqual(MeterNormalization.fraction(0, leader: 0), 0)
        XCTAssertEqual(MeterNormalization.fraction(30, leader: 0), 0)
        XCTAssertEqual(MeterNormalization.fraction(30, leader: -1), 0)
    }

    /// 越界夹紧:值不应超过榜首(调用方保证),越界时夹到满条而非溢出。
    func testValueBeyondLeaderClampsToOne() {
        XCTAssertEqual(MeterNormalization.fraction(150, leader: 100), 1)
        // 负值(异常输入)夹到 0,不画负条。
        XCTAssertEqual(MeterNormalization.fraction(-5, leader: 100), 0)
    }
}
