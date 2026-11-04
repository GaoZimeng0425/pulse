@testable import PulseCore
import XCTest

/// 清空废纸篓的纯值面(p4-uninstaller/04):防御闸边界、确认文案三条字样、
/// 清点汇总。删除本体在 Live(一期已交付),这里钉住「越界即红」的判定与文案。
final class TrashEmptyingTests: XCTestCase {
    // MARK: 防御闸(ADR-0008:删除只许落在废纸篓目录之内)

    func testInsideTrashAcceptsEntriesAndRoot() {
        let trash = NSHomeDirectory() + "/.Trash"
        XCTAssertTrue(TrashEmptying.isInsideTrash(trash, trashDirectories: [trash]))
        XCTAssertTrue(TrashEmptying.isInsideTrash(trash + "/Foo.app", trashDirectories: [trash]))
        XCTAssertTrue(TrashEmptying.isInsideTrash(trash + "/a/b.txt", trashDirectories: [trash]))
    }

    func testInsideTrashRejectsPrefixLookalikesAndOutside() {
        let trash = NSHomeDirectory() + "/.Trash"
        // 裸字符串前缀会误中的形状:兄弟目录 / 中间同名段。
        XCTAssertFalse(TrashEmptying.isInsideTrash(trash + "Old", trashDirectories: [trash]))
        XCTAssertFalse(TrashEmptying.isInsideTrash(trash + "-backup/x", trashDirectories: [trash]))
        XCTAssertFalse(TrashEmptying.isInsideTrash("/Applications/Demo.app", trashDirectories: [trash]))
        XCTAssertFalse(TrashEmptying.isInsideTrash(NSHomeDirectory() + "/Library/Caches/x", trashDirectories: [trash]))
    }

    func testInsideTrashMatchesAnyOfMultipleRoots() {
        let home = NSHomeDirectory() + "/.Trash"
        let external = "/Volumes/Backup/.Trashes/501"
        XCTAssertTrue(TrashEmptying.isInsideTrash(external + "/old.dmg", trashDirectories: [home, external]))
        XCTAssertFalse(TrashEmptying.isInsideTrash("/Volumes/Other/x", trashDirectories: [home, external]))
    }

    // MARK: 确认文案(票面三条:所有卷汇总 / 永久不可恢复 / 含其他 App 扔进的内容)

    func testConfirmationTextCarriesAllThreeClauses() {
        let inventory = TrashInventory(volumes: [
            .init(name: "启动卷", items: 3, bytes: 2_500_000_000),
        ])
        let text = TrashEmptying.confirmationText(for: inventory)
        XCTAssertTrue(text.contains("3 项"), "项数上屏:\(text)")
        XCTAssertTrue(text.contains("永久删除,不可恢复"), text)
        XCTAssertTrue(text.contains("包括其他 App 扔进废纸篓的内容"), text)
    }

    func testConfirmationTextListsVolumesWhenMultiple() {
        let inventory = TrashInventory(volumes: [
            .init(name: "启动卷", items: 3, bytes: 1000),
            .init(name: "Backup", items: 2, bytes: 2000),
        ])
        let text = TrashEmptying.confirmationText(for: inventory)
        XCTAssertTrue(text.contains("启动卷 3 项"), text)
        XCTAssertTrue(text.contains("Backup 2 项"), text)
        XCTAssertTrue(text.contains("5 项"), "总量:\(text)")
    }

    // MARK: 清点汇总

    func testInventoryAggregates() {
        let inventory = TrashInventory(volumes: [
            .init(name: "启动卷", items: 0, bytes: 0),
            .init(name: "Backup", items: 4, bytes: 1500),
        ])
        XCTAssertEqual(inventory.totalItems, 4)
        XCTAssertEqual(inventory.totalBytes, 1500)
        XCTAssertFalse(inventory.isEmpty, "有货卷在,不算空")
        XCTAssertTrue(TrashInventory(volumes: [.init(name: "启动卷", items: 0, bytes: 0)]).isEmpty)
    }
}
