import AppKit
@testable import Pulse
import XCTest

/// AppIconCache 预栅格化(resident-cost/01 3c):命中同实例、尺寸进键、
/// 产物是按显示尺寸栅格化的小位图(点尺寸 + 像素 = 点 × 屏幕缩放)。
/// LaunchServices / 解码单价见工单 comment 的真机探针;此处钉行为契约。
@MainActor
final class AppIconCacheTests: XCTestCase {
    private let finder = "/System/Library/CoreServices/Finder.app"

    private var screenScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    func testSamePathAndSizeReturnsCachedInstance() {
        let first = AppIconCache.icon(forBundle: finder, pointSize: 18)
        let second = AppIconCache.icon(forBundle: finder, pointSize: 18)
        XCTAssertTrue(first === second, "同路径同尺寸应命中缓存返回同实例")
    }

    func testDifferentSizesAreCachedSeparatelyWithOwnPixelDimensions() {
        let compact = AppIconCache.icon(forBundle: finder, pointSize: 18)
        let regular = AppIconCache.icon(forBundle: finder, pointSize: 22)

        XCTAssertFalse(compact === regular, "尺寸进缓存键,不同尺寸各自栅格化")
        for (icon, pointSize) in [(compact, 18.0), (regular, 22.0)] {
            let expectedPixels = Int((pointSize * screenScale).rounded())
            let reps = icon.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(reps.count, 1, "预栅格化产物应恰一个位图 rep")
            XCTAssertEqual(reps.first?.pixelsWide, expectedPixels)
            XCTAssertEqual(reps.first?.pixelsHigh, expectedPixels)
            XCTAssertEqual(icon.size.width, pointSize, accuracy: 0.5, "点尺寸 = 显示尺寸")
        }
    }

    /// 回归钉:产物不再是 NSWorkspace 原图(多档大表示)——那正是每次绘制
    /// 118µs 的来源;预栅格化后每次绘制 ~8µs。
    func testRasterizedOutputIsNotTheRawWorkspaceIcon() {
        let cached = AppIconCache.icon(forBundle: finder, pointSize: 16)
        let raw = NSWorkspace.shared.icon(forFile: finder)
        let rawWidest = raw.representations.map(\.pixelsWide).max() ?? 0
        XCTAssertFalse(cached === raw)
        XCTAssertLessThan(cached.representations.first?.pixelsWide ?? 0, rawWidest)
    }
}
