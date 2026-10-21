@testable import Pulse
@testable import PulseCore
import SwiftUI
import XCTest

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

    /// 孤儿进程的样式表条目:橙色外壳(GLOSSARY:橙色高亮,"它往往正是问题所在")。
    func testOrphanCardStyleIsOrangeHighlighted() {
        // 孤儿瓦片取类别身份色表(唯一出处),浅色外观下即系统橙 #ff9500。
        XCTAssertEqual(GroupCategory.orphan.cardStyle.tileColor, GroupCategory.orphan.identityColor)
        let resolved = GroupCategory.orphan.identityColor.resolve(in: EnvironmentValues())
        XCTAssertEqual(Int((resolved.red * 255).rounded()), 0xFF)
        XCTAssertEqual(Int((resolved.green * 255).rounded()), 0x95)
        XCTAssertEqual(Int((resolved.blue * 255).rounded()), 0x00)
    }

    /// 类别外壳底色互不相同(2026-10-16 外壳瓦片:非 bundle 组以"实心圆角方块 +
    /// 白符号"对齐 app logo 形态,底色是类别的可辨识标记)。
    func testEveryCategoryHasDistinctTileColor() {
        let tiles = GroupCategory.allCases.map(\.cardStyle.tileColor)
        let resolved = tiles.map { $0.resolve(in: .init()) }

        XCTAssertEqual(Set(resolved.map(\.description)).count, resolved.count, "各类别外壳底色应互不相同")
    }

    /// P0.6-02 强调色接入样式表后,孤儿一行的强调色仍是橙——
    /// "孤儿橙"语义不随指标色体系改变(其余类别用 CPU 指标强调色,视觉验收)。
    func testOrphanCardAccentStaysOrange() {
        XCTAssertEqual(GroupCategory.orphan.cardStyle.accentColor, GroupCategory.orphan.identityColor)
    }
}
