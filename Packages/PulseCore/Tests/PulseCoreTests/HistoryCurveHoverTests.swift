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
}

// MARK: - 主卡定长窗口(chart-hover-partial:不足补 0,第 i 格 = list[i])

final class HistoryCurveEdgeWindowTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let count = 56

    private func ring(_ n: Int) -> (values: [Double], times: [Date]) {
        ((0 ..< n).map { Double($0) }, (0 ..< n).map { base.addingTimeInterval(Double($0)) })
    }

    /// 满环 60 点取最近 56(序号 4…59);第 i 格就是 list[i]——2026-11-24 回归
    /// (切片下标错位,GPU 折线 57% 浮层报 0%)在此仍守住。
    func testFullRingKeepsMostRecentAndIndexesDirectly() {
        let r = ring(60)
        let window = HistoryCurveHover.edgeWindow(values: r.values, times: r.times, count: count)
        XCTAssertEqual(window.count, count)
        XCTAssertEqual(window[0], .init(value: 4, time: base.addingTimeInterval(4)))
        XCTAssertEqual(window[3].value, 7)
        XCTAssertEqual(window[55], .init(value: 59, time: base.addingTimeInterval(59)))
    }

    /// 实犯(2026-11-25 用户报 GPU / 磁盘图无悬停线):未满窗时前面补 0、无时刻,
    /// 真实点紧随其后——右半段悬停必须拿得到真读数。
    func testPartialRingPadsFrontWithZero() {
        let r = ring(10)
        let window = HistoryCurveHover.edgeWindow(values: r.values, times: r.times, count: count)
        XCTAssertEqual(window.count, count)
        XCTAssertEqual(window[0], .init(value: 0, time: nil))
        XCTAssertEqual(window[45], .init(value: 0, time: nil))
        XCTAssertEqual(window[46], .init(value: 0, time: base))
        XCTAssertEqual(window[55], .init(value: 9, time: base.addingTimeInterval(9)))
    }

    func testMisalignedTimesDropAllTimesButKeepValues() {
        let window = HistoryCurveHover.edgeWindow(values: [1, 2, 3], times: [base], count: count)
        XCTAssertEqual(window.count, count)
        XCTAssertEqual(window[55], .init(value: 3, time: nil))
        XCTAssertTrue(window.allSatisfy { $0.time == nil })
    }

    func testEmptyValuesYieldEmptyWindow() {
        XCTAssertTrue(HistoryCurveHover.edgeWindow(values: [], times: [], count: count).isEmpty)
    }
}
