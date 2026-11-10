@testable import Pulse
import PulseCore
import XCTest

/// 清理页子药丸登记面(p4-uninstaller/01 建、02 改序;p6-cleaner/03 总览居首):
/// 五子药丸、apps 在轴、标题。登记面结构性断言(CODING_STANDARDS:直调 smoke 不背书
/// 装配可达性;p2-audit 教训——容器 registry 漏登,功能上线即死而测试全绿)。
final class CleanerAppSubTabTests: XCTestCase {
    func testFiveSubTabsOnAxis() {
        // 顺序 = 2026-11-04 拍板 Q13(动手门在前、档案门殿后)+ p6-cleaner/03 总览居首
        // (丙案 v2:进清理页先看"能省多少")。顺序漂移会破坏用户肌肉记忆。
        XCTAssertEqual(
            CleanerSubTab.allCases,
            [.overview, .junk, .map, .apps, .history],
            "子页顺序漂移会破坏用户肌肉记忆"
        )
    }

    func testOverviewTitle() {
        // p6-cleaner/03 新子页:总览。
        XCTAssertEqual(CleanerSubTab.overview.title, "总览")
    }

    func testAppsTitle() {
        XCTAssertEqual(CleanerSubTab.apps.title, "应用")
    }

    func testJunkTitle() {
        // 2026-11-08 首改「可清理」;p6-cleaner/03 再改「全部清单」——总览承担
        // "能回收多少"的第一眼,清单页名回归"它是什么"。内部标识仍不动。
        XCTAssertEqual(CleanerSubTab.junk.title, "全部清单")
    }

    /// 总览模块大卡的文案登记完整性(p6-cleaner/03):六个品类 + 废纸篓一个不缺——
    /// 漏写 switch 会编译失败,漏整组(文案表换出处)在这里兜底。
    func testOverviewCardCopyCoversAllGroupsAndTrash() {
        for group in JunkGroup.allCases {
            XCTAssertFalse(
                group.overviewTagline.isEmpty,
                "\(group.rawValue) 缺总览一句人话"
            )
            XCTAssertFalse(
                group.overviewSymbolName.isEmpty,
                "\(group.rawValue) 缺总览图标瓦符号"
            )
        }
        XCTAssertFalse(JunkTrashCardCopy.title.isEmpty)
        XCTAssertFalse(JunkTrashCardCopy.tagline.isEmpty)
        XCTAssertFalse(JunkTrashCardCopy.symbolName.isEmpty)
    }
}
