@testable import Pulse
import PulseCore
import XCTest

/// p7-cleaner/01 底座接线:系统级、安装包两组各自持有组内排序,不蹭别组、也不被别组影响。
/// 新组的总览卡文案登记完整性由 `CleanerAppSubTabTests` 的全组遍历钉住。
@MainActor
final class CleanerGroupFoundationTests: XCTestCase {
    func testNewGroupsKeepTheirOwnSortOrder() {
        let model = CleanerModel.testing(trash: FakeCleanTrashExecutor())

        XCTAssertEqual(model.sortOrder(for: .systemLevel), .size, "新组默认按大小")
        XCTAssertEqual(model.sortOrder(for: .installers), .size, "新组默认按大小")

        model.setSortOrder(.age, for: .systemLevel)

        XCTAssertEqual(model.sortOrder(for: .systemLevel), .age)
        XCTAssertEqual(model.sortOrder(for: .installers), .size, "两组互不影响")
        XCTAssertEqual(model.sortOrder(for: .uninstallLeftovers), .size, "前一组不受影响")
    }
}
