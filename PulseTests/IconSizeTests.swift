@testable import Pulse
import XCTest

/// 图标尺寸档位(IconSize)是自由摆放的符号图标的字号单一出处:同类图标全 app
/// 一个大小。期望值是 DESIGN.md 令牌表的原文(文档 = 独立事实源)。
final class IconSizeTests: XCTestCase {
    /// 五档钉死:箭头 9 / 行内 11 / 行首 13·16(随行紧凑·舒适档)/ 空态 26。
    func testIconSizeTiersArePinned() {
        XCTAssertEqual(IconSize.chevron, 9)
        XCTAssertEqual(IconSize.inline, 11)
        XCTAssertEqual(IconSize.leading(compact: true), 13)
        XCTAssertEqual(IconSize.leading(compact: false), 16)
        XCTAssertEqual(IconSize.emptyState, 26)
    }
}
