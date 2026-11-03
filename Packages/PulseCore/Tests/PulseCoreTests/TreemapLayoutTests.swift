@testable import PulseCore
import XCTest

/// treemap 布局(p4-cleaner/07 v3):面积守恒、铺满、squarify 宽高比、尾部合并。
final class TreemapLayoutTests: XCTestCase {
    private func node(_ name: String, _ path: String, bytes: Int64, sealed: Bool = false) -> SpaceMapNode {
        SpaceMapNode(name: name, path: path, bytes: bytes, isSealed: sealed)
    }

    func testAreasSumToOneAndNoOverlap() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 0, children: [
            node("a", "/a", bytes: 500),
            node("b", "/b", bytes: 250),
            node("c", "/c", bytes: 150),
            node("d", "/d", bytes: 100),
        ])
        let rects = TreemapLayout.layout(root: root)
        XCTAssertEqual(rects.count, 4)

        // 面积守恒(±精度)
        let totalArea = rects.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(totalArea, 1.0, accuracy: 1e-6)

        // 全在 [0,1] 内
        for r in rects {
            XCTAssertGreaterThanOrEqual(r.rect.minX, -1e-9)
            XCTAssertGreaterThanOrEqual(r.rect.minY, -1e-9)
            XCTAssertLessThanOrEqual(r.rect.maxX, 1.0 + 1e-9)
            XCTAssertLessThanOrEqual(r.rect.maxY, 1.0 + 1e-9)
        }

        // 两两不重叠
        for i in 0 ..< rects.count {
            for j in i + 1 ..< rects.count {
                let a = rects[i].rect
                let b = rects[j].rect
                let overlapW = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let overlapH = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                XCTAssertLessThan(overlapW * overlapH, 1e-9, "矩形 \(i) 与 \(j) 不应重叠")
            }
        }
    }

    func testLargestGetsBiggestRect() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 0, children: [
            node("huge", "/huge", bytes: 900),
            node("small", "/small", bytes: 100),
        ])
        let rects = TreemapLayout.layout(root: root)
        XCTAssertEqual(rects.count, 2)
        let hugeArea = rects[0].rect.width * rects[0].rect.height
        let smallArea = rects[1].rect.width * rects[1].rect.height
        XCTAssertGreaterThan(hugeArea, smallArea)
        XCTAssertEqual(hugeArea, 0.9, accuracy: 1e-6)
    }

    func testSmallTailMerged() {
        let children = (0 ..< 5).map { node("big\($0)", "/big\($0)", bytes: 100) }
            + (0 ..< 4).map { node("tiny\($0)", "/tiny\($0)", bytes: 1) }
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 0, children: children)
        let rects = TreemapLayout.layout(root: root, minFraction: 0.01)
        let other = rects.first { $0.node.isAggregate }
        XCTAssertNotNil(other)
        XCTAssertEqual(other?.node.bytes, 4)
        XCTAssertEqual(other?.node.mergedCount, 4)
    }

    func testEmptyRoot() {
        XCTAssertTrue(TreemapLayout.layout(root: SpaceMapNode(name: "整卷", path: "/", bytes: 0)).isEmpty)
    }

    func testSingleChildFillsAll() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 0, children: [
            node("only", "/only", bytes: 100),
        ])
        let rects = TreemapLayout.layout(root: root)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].rect.width * rects[0].rect.height, 1.0, accuracy: 1e-6)
    }
}
