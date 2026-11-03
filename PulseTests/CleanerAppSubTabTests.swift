@testable import Pulse
import XCTest

/// 清理页子药丸登记面(p4-uninstaller/01):四子药丸、apps 在轴、标题。
/// 登记面结构性断言(CODING_STANDARDS:直调 smoke 不背书装配可达性;
/// p2-audit 教训——容器 registry 漏登,功能上线即死而测试全绿)。
final class CleanerAppSubTabTests: XCTestCase {
    func testFourSubTabsOnAxis() {
        XCTAssertEqual(
            CleanerSubTab.allCases,
            [.junk, .map, .history, .apps],
            "spec:清理页四个子药丸,应用是第 4 个(顺序漂移会破坏用户肌肉记忆)"
        )
    }

    func testAppsTitle() {
        XCTAssertEqual(CleanerSubTab.apps.title, "应用")
    }
}
