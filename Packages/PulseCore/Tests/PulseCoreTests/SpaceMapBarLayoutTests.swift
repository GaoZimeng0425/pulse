@testable import PulseCore
import XCTest

/// 分层条形图布局(p4-cleaner/07 v2:Canvas 替代扇形)。
final class SpaceMapBarLayoutTests: XCTestCase {
    private func node(
        _ name: String,
        _ path: String,
        bytes: Int64,
        sealed: Bool = false,
        children: [SpaceMapNode] = []
    ) -> SpaceMapNode {
        SpaceMapNode(name: name, path: path, bytes: bytes, isSealed: sealed, children: children)
    }

    func testLayoutProportionalAndContiguous() {
        let root = node("整卷", "/", bytes: 0, children: [
            node("a", "/a", bytes: 600),
            node("b", "/b", bytes: 300),
            node("c", "/c", bytes: 100),
        ])
        let bars = SpaceMapBarLayout.layout(root: root)
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars[0].node.name, "a")
        XCTAssertEqual(bars[0].height, 0.6, accuracy: 1e-9)
        XCTAssertEqual(bars[1].height, 0.3, accuracy: 1e-9)
        XCTAssertEqual(bars[2].height, 0.1, accuracy: 1e-9)
        // 首尾相接、铺满 [0,1]
        XCTAssertEqual(bars[0].y, 0)
        XCTAssertEqual(bars[1].y, bars[0].y + bars[0].height, accuracy: 1e-9)
        XCTAssertEqual(bars[2].y, bars[1].y + bars[1].height, accuracy: 1e-9)
        XCTAssertEqual(bars[2].y + bars[2].height, 1.0, accuracy: 1e-9)
    }

    func testSmallTailMergedIntoOther() {
        let children = (0 ..< 5).map { node("big\($0)", "/big\($0)", bytes: 100) }
            + (0 ..< 3).map { node("tiny\($0)", "/tiny\($0)", bytes: 1) }
        let root = node("整卷", "/", bytes: 0, children: children)
        let bars = SpaceMapBarLayout.layout(root: root, minBarFraction: 0.01)
        let other = bars.first { $0.node.isAggregate }
        XCTAssertNotNil(other, "低于阈值的尾部应合并")
        XCTAssertEqual(other?.node.bytes, 3)
        XCTAssertEqual(other?.node.mergedCount, 3)
        XCTAssertEqual(bars.count, 6, "5 个大头 + 1 个其他")
    }

    func testEmptyRootReturnsNoBars() {
        XCTAssertTrue(SpaceMapBarLayout.layout(root: SpaceMapNode(name: "整卷", path: "/", bytes: 0)).isEmpty)
        XCTAssertTrue(
            SpaceMapBarLayout
                .layout(root: SpaceMapNode(name: "整卷", path: "/", bytes: 10, children: []))
                .isEmpty
        )
    }

    func testSealedBlockStillListed() {
        let root = node("整卷", "/", bytes: 0, children: [
            node("Users", "/Users", bytes: 800),
            node("系统(密封)", "/System", bytes: 200, sealed: true),
        ])
        let bars = SpaceMapBarLayout.layout(root: root)
        XCTAssertEqual(bars.count, 2)
        XCTAssertNotNil(bars.first { $0.node.isSealed }, "密封块照常出现")
    }
}
