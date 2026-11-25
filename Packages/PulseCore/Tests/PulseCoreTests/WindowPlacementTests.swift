import CoreGraphics
@testable import PulseCore
import XCTest

/// 主窗口离屏拉回(arch-review-2026-11-24/13):屏 / 光标是 CG 坐标(左上原点 y 向下),
/// 窗口是 AppKit 坐标(左下原点 y 向上)。主屏 = 内建 1512×982,CG 原点在其左上角。
final class WindowPlacementTests: XCTestCase {
    private let mainHeight: CGFloat = 982
    private let builtin = WindowPlacement.Display(
        cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        isBuiltin: true
    )
    private let window = CGSize(width: 800, height: 600)

    private func frame(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: window)
    }

    private func relocate(_ windowFrame: CGRect, _ displays: [WindowPlacement.Display], cursor: CGPoint) -> CGPoint? {
        WindowPlacement.relocatedOrigin(
            windowFrame: windowFrame, displays: displays, cursor: cursor, mainDisplayHeight: mainHeight
        )
    }

    // MARK: 换算

    func testFlipMirrorsAroundMainDisplayHeight() {
        XCTAssertEqual(
            WindowPlacement.appKitRect(fromCG: builtin.cgBounds, mainDisplayHeight: mainHeight),
            builtin.cgBounds
        )
        let above = CGRect(x: -524, y: -1440, width: 2560, height: 1440)
        XCTAssertEqual(
            WindowPlacement.appKitRect(fromCG: above, mainDisplayHeight: mainHeight),
            CGRect(x: -524, y: 982, width: 2560, height: 1440)
        )
        XCTAssertEqual(
            WindowPlacement.appKitPoint(fromCG: CGPoint(x: 10, y: 0), mainDisplayHeight: mainHeight),
            CGPoint(x: 10, y: 982)
        )
    }

    // MARK: 单屏(行为与旧实现一致)

    func testSingleDisplayWindowOnScreenStays() {
        XCTAssertNil(relocate(frame(100, 100), [builtin], cursor: CGPoint(x: 500, y: 500)))
    }

    func testSingleDisplayWindowOffscreenIsCentered() {
        XCTAssertEqual(relocate(frame(5000, 100), [builtin], cursor: CGPoint(x: 500, y: 500)), CGPoint(x: 356, y: 191))
    }

    // MARK: 外接屏在上方(实犯场景)

    private let above = WindowPlacement.Display(
        cgBounds: CGRect(x: -524, y: -1440, width: 2560, height: 1440), isBuiltin: false
    )

    /// 探针(红):旧实现把 CG 屏矩形直接和 AppKit 窗口比——窗口明明在上方屏上,
    /// 也判成离屏要搬。新实现不搬。
    func testWindowOnUpperDisplayIsNotMoved() {
        let onUpper = frame(200, 1200)
        let cursorOnUpper = CGPoint(x: 100, y: -500)
        XCTAssertNotNil(
            Self.legacyRelocatedOrigin(windowFrame: onUpper, displays: [builtin, above], cursor: cursorOnUpper),
            "旧实现在上下排布时误判离屏(本测试的存在理由)"
        )
        XCTAssertNil(relocate(onUpper, [builtin, above], cursor: cursorOnUpper))
    }

    func testOffscreenWindowLandsOnUpperDisplayUnderCursor() {
        let origin = relocate(frame(9000, 9000), [builtin, above], cursor: CGPoint(x: 100, y: -500))
        XCTAssertEqual(origin, CGPoint(x: 356, y: 1402))
        // 落点整窗在上方屏(AppKit 系 y ∈ 982…2422)内。
        let upper = CGRect(x: -524, y: 982, width: 2560, height: 1440)
        XCTAssertTrue(upper.contains(CGRect(origin: origin ?? .zero, size: window)))
    }

    func testWindowOnMainBelowUpperDisplayStays() {
        XCTAssertNil(relocate(frame(100, 100), [builtin, above], cursor: CGPoint(x: 500, y: 500)))
    }

    // MARK: 左右并排(主屏在右,外接屏更高)

    private let leftTall = WindowPlacement.Display(
        cgBounds: CGRect(x: -2560, y: 0, width: 2560, height: 1440), isBuiltin: false
    )

    func testSideBySideOffscreenLandsOnLeftDisplayUnderCursor() {
        let origin = relocate(frame(9000, 100), [builtin, leftTall], cursor: CGPoint(x: -1000, y: 1200))
        XCTAssertEqual(origin, CGPoint(x: -1680, y: -38))
        let left = CGRect(x: -2560, y: -458, width: 2560, height: 1440)
        XCTAssertTrue(left.contains(CGRect(origin: origin ?? .zero, size: window)))
    }

    func testSideBySideWindowOnLeftDisplayStays() {
        XCTAssertNil(relocate(frame(-2000, -300), [builtin, leftTall], cursor: CGPoint(x: -1000, y: 1200)))
    }

    /// 既有口径(保留):窗口不在**光标所在屏**上就搬过去——幻影屏无 API 可辨,
    /// 光标是唯一骗不掉的锚点。光标在主屏、窗口在左屏 → 搬到主屏。
    func testWindowNotOnCursorDisplayMovesToCursorDisplay() {
        XCTAssertEqual(
            relocate(frame(-2000, -300), [builtin, leftTall], cursor: CGPoint(x: 500, y: 500)),
            CGPoint(x: 356, y: 191)
        )
    }

    // MARK: 回退链

    func testCursorOutsideAllDisplaysFallsBackToBuiltin() {
        let origin = relocate(frame(9000, 9000), [above, builtin], cursor: CGPoint(x: 99999, y: 99999))
        XCTAssertEqual(origin, CGPoint(x: 356, y: 191))
    }

    func testNoBuiltinFallsBackToWidestDisplay() {
        let small = WindowPlacement.Display(cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: false)
        let origin = relocate(frame(9000, 9000), [small, above], cursor: CGPoint(x: 99999, y: 99999))
        XCTAssertEqual(origin, CGPoint(x: 356, y: 1402))
    }

    func testNoDisplaysReturnsNil() {
        XCTAssertNil(relocate(frame(9000, 9000), [], cursor: .zero))
    }

    // MARK: 旧实现(仅供探针对照,逐字保留其坐标混用)

    private static func legacyRelocatedOrigin(
        windowFrame: CGRect, displays: [WindowPlacement.Display], cursor: CGPoint
    ) -> CGPoint? {
        let target = displays.first { $0.cgBounds.contains(cursor) }?.cgBounds
            ?? displays.first { $0.isBuiltin }?.cgBounds
        guard let target, !target.intersects(windowFrame) else { return nil }
        return CGPoint(x: target.midX - windowFrame.width / 2, y: target.midY - windowFrame.height / 2)
    }
}
