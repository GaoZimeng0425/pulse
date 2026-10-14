import XCTest
import SwiftUI
@testable import Pulse

/// 组卡类别样式表(工单 05;评审 T6 收敛为每类别一份完整样式)。
/// 像素层面工单 09 手动验收;这里保障映射全且互不相同——
/// "系统/后台服务类有可辨识的类别标记"的最小前提,
/// 以及孤儿高亮是样式表中的一行而非视图特判。
final class GroupCategoryDisplayTests: XCTestCase {
    func testEveryCategoryHasDistinctNonEmptyCardSymbol() {
        let symbols = GroupCategory.allCases.map(\.cardStyle.symbolName)

        XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty }, "每个类别都应有符号图")
        XCTAssertEqual(Set(symbols).count, symbols.count, "各类别符号应互不相同(可辨识)")
    }

    /// 孤儿进程的样式表条目:橙色图标(GLOSSARY:橙色高亮,"它往往正是问题所在")。
    func testOrphanCardStyleIsOrangeHighlighted() {
        XCTAssertEqual(GroupCategory.orphan.cardStyle.iconColor, .orange)
    }
}
