@testable import Pulse
import XCTest

/// 设置侧栏图标砖的渐变色令牌(`{colors.settings-icon-*}`):固定色、每页一对。
/// 期望值是 DESIGN.md 令牌表的原文(文档 = 独立事实源)。
final class SettingsIconTintTests: XCTestCase {
    /// 五个设置页的渐变起止色逐项对令牌表。
    func testSettingsIconTintsMatchTokenTable() {
        XCTAssertEqual(SettingsIconTint.general, .init(from: 0x9E9EA8, to: 0x6B6B78))
        XCTAssertEqual(SettingsIconTint.alerts, .init(from: 0xF29E33, to: 0xD9591A))
        XCTAssertEqual(SettingsIconTint.projectRoots, .init(from: 0x4D8CF2, to: 0x2659BF))
        XCTAssertEqual(SettingsIconTint.menuBar, .init(from: 0x9466EB, to: 0x6B38C7))
        XCTAssertEqual(SettingsIconTint.cleaner, .init(from: 0xFAB326, to: 0xD98500))
    }

    /// 每页起止色互异(否则渐变退成平色),页与页之间起色互异(侧栏靠它区分)。
    func testTintsAreDistinct() {
        let all = SettingsIconTint.all
        for tint in all {
            XCTAssertNotEqual(tint.from, tint.to)
        }
        XCTAssertEqual(Set(all.map(\.from)).count, all.count)
    }
}
