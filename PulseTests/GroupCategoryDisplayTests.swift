import XCTest
@testable import Pulse

/// 组卡类别标记(工单 05):类别 → SF Symbol 的呈现映射。
/// 像素层面工单 09 手动验收;这里保障映射全且互不相同——
/// "系统/后台服务类有可辨识的类别标记"的最小前提。
final class GroupCategoryDisplayTests: XCTestCase {
    func testEveryCategoryHasDistinctNonEmptyCardSymbol() {
        let symbols = GroupCategory.allCases.map(\.cardSymbolName)

        XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty }, "每个类别都应有符号图")
        XCTAssertEqual(Set(symbols).count, symbols.count, "各类别符号应互不相同(可辨识)")
    }
}
