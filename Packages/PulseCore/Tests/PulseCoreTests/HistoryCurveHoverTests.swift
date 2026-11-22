@testable import PulseCore
import XCTest

// history-hover/01:历史曲线悬停的反算与吸附。合成夹具,视图层不进测试
// (浮层/竖线条目归 DESIGN.md 与真机目验)。
final class HistoryCurveHoverTests: XCTestCase {
    // MARK: - x → 桶序号

    func testBucketIndexAtCenters() {
        // count=4、width=100:桶中心 x = 12.5 / 37.5 / 62.5 / 87.5。
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 12.5, width: 100, count: 4), 0)
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 37.5, width: 100, count: 4), 1)
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 62.5, width: 100, count: 4), 2)
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 87.5, width: 100, count: 4), 3)
    }

    func testBucketIndexClampsOutOfRange() {
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: -5, width: 100, count: 4), 0)
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 105, width: 100, count: 4), 3)
    }

    func testBucketIndexDegenerateInputs() {
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 50, width: 0, count: 4), 0)
        XCTAssertEqual(HistoryCurveHover.bucketIndex(atX: 50, width: 100, count: 0), 0)
    }

    // MARK: - 最近非空点吸附

    func testNearestFilledOnFilledBucketReturnsItself() {
        XCTAssertEqual(HistoryCurveHover.nearestFilled(anchor: 1, values: [1, 2, nil, 4]), 1)
    }

    func testNearestFilledSkipsEmptyToNearest() {
        // 锚在空桶:左邻也空,右邻有数 → 吸右。
        XCTAssertEqual(HistoryCurveHover.nearestFilled(anchor: 2, values: [1, nil, nil, 4, 5]), 3)
        // 左右等距都有数 → 取更早的(确定性)。
        XCTAssertEqual(HistoryCurveHover.nearestFilled(anchor: 1, values: [1, nil, 3]), 0)
    }

    func testNearestFilledAnchorOutOfRangeClamps() {
        XCTAssertEqual(HistoryCurveHover.nearestFilled(anchor: 99, values: [1, nil, 3]), 2)
    }

    func testNearestFilledAllEmptyYieldsNil() {
        XCTAssertNil(HistoryCurveHover.nearestFilled(anchor: 1, values: [nil, nil, nil]))
        XCTAssertNil(HistoryCurveHover.nearestFilled(anchor: 0, values: []))
    }
}
