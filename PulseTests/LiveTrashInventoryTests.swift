@testable import Pulse
import PulseCore
import XCTest

/// 废纸篓清点的 Live 失败语义(p6-review-fixes):读不到 ≠ 空——任一目录枚举失败
/// 整体交 nil(调用方走占位),不把读不到的卷记成 0 项。合成夹具 = 临时目录,
/// 不碰真实废纸篓(p4-uninstaller/04「fake 注入,绝不真删」同一条纪律,这里只读)。
final class LiveTrashInventoryTests: XCTestCase {
    /// 临时「废纸篓」:一个文件 + 一个含文件的子目录 + .DS_Store。
    private func makeTrashFixture() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-trash-inv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data(count: 4096).write(to: dir.appendingPathComponent("old.bin"))
        let nested = dir.appendingPathComponent("app.app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data(count: 4096).write(to: nested.appendingPathComponent("inner.bin"))
        try Data(count: 4).write(to: dir.appendingPathComponent(".DS_Store"))
        return dir.path
    }

    func testReadableTrashCountsItemsAndSkipsDSStore() throws {
        let path = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inventory = LiveCleanTrashExecutor.inventory(of: [("夹具卷", path)])
        let counted = try XCTUnwrap(inventory, "可读目录必须清点成功")
        XCTAssertEqual(counted.volumes.count, 1)
        XCTAssertEqual(counted.volumes[0].items, 2, "文件 + 目录;.DS_Store 不算项")
        XCTAssertEqual(counted.volumes[0].name, "夹具卷")
        XCTAssertGreaterThan(counted.volumes[0].bytes, 0, "分配大小求和(整树,含子目录)")
    }

    func testEmptyTrashCountsAsTrueZero() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-trash-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: dir.path) }

        let inventory = LiveCleanTrashExecutor.inventory(of: [("空卷", dir.path)])
        let counted = try XCTUnwrap(inventory)
        XCTAssertEqual(counted.totalItems, 0, "真空 = 0 是真读数,照常交付")
    }

    /// 核心:清单里混一个枚举失败的目录(不存在 / 无权限同路径)→ 整体 nil,
    /// 不产出「可读那卷 + 0」的部分结果。
    func testUnreadableDirectoryYieldsNilNotPartialZero() throws {
        let readable = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(atPath: readable) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-trash-missing-\(UUID().uuidString)").path

        XCTAssertNil(
            LiveCleanTrashExecutor.inventory(of: [("好卷", readable), ("读不到的卷", missing)]),
            "读不到 ≠ 空:整体 nil 上行,不把失败卷记成 0 项"
        )
        XCTAssertNil(
            LiveCleanTrashExecutor.inventory(of: [("读不到的卷", missing)]),
            "唯一卷读不到同样 nil,不交空清点"
        )
    }
}
