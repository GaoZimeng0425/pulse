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

// MARK: - 端点锚定网格(history-hover/02:主卡面积图)

final class HistoryCurveEdgeHoverTests: XCTestCase {
    func testEdgeIndexAtAnchors() {
        // count=56、width=110:x = i/55·110;首尾贴缘。
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: 0, width: 110, count: 56), 0)
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: 110, width: 110, count: 56), 55)
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: 40, width: 110, count: 56), 20)
    }

    func testEdgeIndexClampsOutOfRangeAndDegenerate() {
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: -3, width: 110, count: 56), 0)
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: 999, width: 110, count: 56), 55)
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: 50, width: 0, count: 56), 0)
        XCTAssertEqual(HistoryCurveHover.edgeIndex(atX: 50, width: 110, count: 1), 0)
    }

    func testWindowIndexExcludesPaddingSlots() {
        // 满窗(56/56)无垫底:槽即窗序号。
        XCTAssertEqual(HistoryCurveHover.windowIndex(forSlot: 0, paddingCount: 0), 0)
        // 半窗(30/56):左 26 槽是垫底假点,悬停不出读数。
        XCTAssertNil(HistoryCurveHover.windowIndex(forSlot: 25, paddingCount: 26))
        XCTAssertEqual(HistoryCurveHover.windowIndex(forSlot: 26, paddingCount: 26), 0)
        XCTAssertEqual(HistoryCurveHover.windowIndex(forSlot: 55, paddingCount: 26), 29)
    }
}
