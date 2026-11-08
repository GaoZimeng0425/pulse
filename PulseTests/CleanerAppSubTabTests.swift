@testable import Pulse
import XCTest

/// 清理页子药丸登记面(p4-uninstaller/01 建、02 改序):四子药丸、apps 在轴、标题。
/// 登记面结构性断言(CODING_STANDARDS:直调 smoke 不背书装配可达性;
/// p2-audit 教训——容器 registry 漏登,功能上线即死而测试全绿)。
final class CleanerAppSubTabTests: XCTestCase {
    func testFourSubTabsOnAxis() {
        // 顺序 = 2026-11-04 拍板 Q13:三个动手门在前(垃圾/地图/应用)、档案门殿后。
        XCTAssertEqual(
            CleanerSubTab.allCases,
            [.junk, .map, .apps, .history],
            "Q13 顺序漂移会破坏用户肌肉记忆"
        )
    }

    func testAppsTitle() {
        XCTAssertEqual(CleanerSubTab.apps.title, "应用")
    }

    func testJunkTitle() {
        // 2026-11-08 用户拍板改名:装着卸载残留后「开发者垃圾」名不副实。
        XCTAssertEqual(CleanerSubTab.junk.title, "可清理")
    }
}
