import AppKit
import PulseCore
import XCTest

/// 规则表登记的行首图标必须是系统里真有的 SF Symbol:名字写错不报错、编译器不拦,
/// 只是那一行没有图标(p7-cleaner/09 搬运一次新增二十多个图标名,钉住)。
final class JunkRuleSymbolTests: XCTestCase {
    func testEveryBuiltinRuleIconIsARealSystemSymbol() {
        let missing = JunkRuleTable.builtin.filter {
            NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) == nil
        }

        XCTAssertEqual(missing.map(\.symbolName), [], "这些图标名不是 SF Symbol,对应的规则是 \(missing.map(\.id))")
    }
}
