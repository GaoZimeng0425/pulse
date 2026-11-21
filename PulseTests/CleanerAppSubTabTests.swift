@testable import Pulse
import PulseCore
import SwiftUI
import XCTest

/// 清理页子药丸登记面(p4-uninstaller/01 建、02 改序;p6-cleaner/03 总览居首;
/// tab-regroup/03 空间地图迁磁盘页后缩编四项):子药丸、apps 在轴、标题 + 磁盘页
/// 地图块登记。登记面结构性断言(CODING_STANDARDS:直调 smoke 不背书装配可达性;
/// p2-audit 教训——容器 registry 漏登,功能上线即死而测试全绿)。
final class CleanerAppSubTabTests: XCTestCase {
    func testFourSubTabsOnAxis() {
        // 顺序 = 2026-11-04 拍板 Q13(动手门在前、档案门殿后)+ p6-cleaner/03 总览居首
        // (丙案 v2:进清理页先看"能省多少");tab-regroup/03 空间地图迁磁盘页,余序不动。
        // 顺序漂移会破坏用户肌肉记忆。
        XCTAssertEqual(
            CleanerSubTab.allCases,
            [.overview, .junk, .apps, .history],
            "子页顺序漂移会破坏用户肌肉记忆"
        )
    }

    /// 磁盘页空间地图块(tab-regroup/03):主窗口在轴且殿后(主卡 → 卷+快照 →
    /// 读写排行 → 地图);弹窗不画(360pt 塞不下旭日,传感器页派生卡例外同款)。
    @MainActor
    func testDiskPageSpaceMapBlockIsMainWindowOnly() {
        let monitor = SystemMonitor.preview()
        let model = DashboardModel(monitor: monitor)

        func diskBlockIDs(compact: Bool) -> [String] {
            MetricTabStack(
                tab: .disk,
                isCompact: compact,
                monitor: monitor,
                model: model,
                cleanerModel: compact ? nil : CleanerModel(trash: FakeCleanTrashExecutor()),
                content: MetricTabContent.build(groups: [], tab: .disk),
                onSelectTab: { _ in },
                overflowPolicy: .expandInPlace
            ) { EmptyView() }.blocks.map(\.id)
        }

        let mainWindowIDs = diskBlockIDs(compact: false)
        // 块序 = 主卡 → 空间地图 → 各卷+快照 → 读写排行(2026-11-16 用户目验改序:
        // 地图紧跟主卡折线图之下,容量总览与占用地图同族相邻)。
        XCTAssertEqual(mainWindowIDs.first, "disk-main")
        XCTAssertEqual(mainWindowIDs.dropFirst().first, "disk-spacemap", "空间地图应紧跟磁盘主卡")
        XCTAssertFalse(diskBlockIDs(compact: true).contains("disk-spacemap"), "弹窗磁盘页不画空间地图(tab-regroup/03 拍板例外)")
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
