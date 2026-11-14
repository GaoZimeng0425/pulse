import CoreGraphics
@testable import PulseCore
import XCTest

// MARK: - 图表悬停几何(agent-tab/07:浮层定位 / 轴标签抽稀 / 最近点吸附)

final class ChartHoverGeometryTests: XCTestCase {
    private let bounds = CGSize(width: 400, height: 200)
    private let size = CGSize(width: 100, height: 40)

    // MARK: 浮层定位

    func testTooltipSitsCenteredAboveAnchor() {
        let anchor = CGRect(x: 190, y: 100, width: 20, height: 20)
        let origin = ChartHoverGeometry.tooltipOrigin(anchor: anchor, size: size, bounds: bounds, gap: 8)
        XCTAssertEqual(origin.x, 150) // midX 200 − 50
        XCTAssertEqual(origin.y, 52) // minY 100 − 8 − 40
    }

    func testTooltipFlipsBelowWhenNoRoomAbove() {
        let anchor = CGRect(x: 190, y: 10, width: 20, height: 20)
        let origin = ChartHoverGeometry.tooltipOrigin(anchor: anchor, size: size, bounds: bounds, gap: 8)
        XCTAssertEqual(origin.y, 38) // maxY 30 + 8
    }

    func testTooltipClampsHorizontallyInsideBounds() {
        let left = ChartHoverGeometry.tooltipOrigin(
            anchor: CGRect(x: 0, y: 100, width: 10, height: 10), size: size, bounds: bounds, gap: 8
        )
        XCTAssertEqual(left.x, 0)
        let right = ChartHoverGeometry.tooltipOrigin(
            anchor: CGRect(x: 395, y: 100, width: 5, height: 5), size: size, bounds: bounds, gap: 8
        )
        XCTAssertEqual(right.x, 300) // 400 − 100
    }

    func testTooltipWiderThanBoundsPinsToLeadingEdge() {
        let origin = ChartHoverGeometry.tooltipOrigin(
            anchor: CGRect(x: 50, y: 100, width: 0, height: 0),
            size: CGSize(width: 500, height: 40),
            bounds: bounds,
            gap: 8
        )
        XCTAssertEqual(origin.x, 0)
    }

    // MARK: 轴标签抽稀

    func testLabelStrideIsOneWhenEveryLabelFits() {
        XCTAssertEqual(ChartHoverGeometry.labelStride(count: 7, width: 600, minSpacing: 44), 1)
    }

    func testLabelStrideThinsDenseAxis() {
        // 30 个标签挤 600pt,每个只有 20pt < 44 → 每 3 个标一个。
        XCTAssertEqual(ChartHoverGeometry.labelStride(count: 30, width: 600, minSpacing: 44), 3)
    }

    func testLabelStrideGuardsDegenerateInput() {
        XCTAssertEqual(ChartHoverGeometry.labelStride(count: 0, width: 600, minSpacing: 44), 1)
        XCTAssertEqual(ChartHoverGeometry.labelStride(count: 30, width: 0, minSpacing: 44), 30)
    }

    func testLabelIndicesAlwaysIncludeLastAndStepBackward() {
        XCTAssertEqual(ChartHoverGeometry.labelIndices(count: 7, stride: 3), [0, 3, 6])
        XCTAssertEqual(ChartHoverGeometry.labelIndices(count: 8, stride: 3), [1, 4, 7])
        XCTAssertEqual(ChartHoverGeometry.labelIndices(count: 0, stride: 3), [])
        XCTAssertEqual(ChartHoverGeometry.labelIndices(count: 3, stride: 0), [0, 1, 2]) // 步长兜底 1
    }

    // MARK: 最近点

    func testNearestIndexSnapsToClosestValue() {
        let xs: [Double] = [0, 10, 20, 30]
        XCTAssertEqual(ChartHoverGeometry.nearestIndex(of: 14, in: xs), 1)
        XCTAssertEqual(ChartHoverGeometry.nearestIndex(of: 16, in: xs), 2)
        XCTAssertEqual(ChartHoverGeometry.nearestIndex(of: -50, in: xs), 0)
        XCTAssertEqual(ChartHoverGeometry.nearestIndex(of: 99, in: xs), 3)
        XCTAssertNil(ChartHoverGeometry.nearestIndex(of: 1, in: []))
    }
}
