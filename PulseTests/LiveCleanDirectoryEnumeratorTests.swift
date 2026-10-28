@testable import Pulse
import PulseCore
import XCTest

/// Live 目录枚举器(p4-cleaner/03):getattrlistbulk 真实现的解析正确性。
/// 在临时目录里造真文件/目录/符号链接/APFS 克隆(小、可清理——测试负载纪律),
/// 断言与探针 11 的结论逐条对上:布局解析、PRVATESIZE 克隆语义、错误分类。
final class LiveCleanDirectoryEnumeratorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p4cleaner-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testKindsSizesAndCloneSemanticsOnRealAPFS() async throws {
        let fileA = root.appendingPathComponent("a.bin")
        try Data(repeating: 0x41, count: 100_000).write(to: fileA)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: false
        )
        try Data(repeating: 0x42, count: 1000)
            .write(to: root.appendingPathComponent("sub/b.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"), withDestinationURL: fileA
        )
        // APFS 克隆:未改写的克隆 PRIVATESIZE = 0(字节困在克隆组,探针 11 ④)
        try fileA.path.withCString { src in
            root.appendingPathComponent("clone.bin").path.withCString { dst in
                XCTAssertEqual(clonefile(src, dst, 0), 0)
            }
        }

        let entries = try await LiveCleanDirectoryEnumerator().entries(ofDirectory: root.path)
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(byName["a.bin"]?.kind, .file)
        XCTAssertEqual(byName["a.bin"]?.logicalSize, 100_000)
        XCTAssertEqual(byName["a.bin"]?.fileID, try fileID(of: fileA.path), "FILEID 与 stat 对上(64 位)")
        XCTAssertEqual(byName["sub"]?.kind, .directory)
        XCTAssertEqual(byName["alias"]?.kind, .symlink)
        let clone = byName["clone.bin"]
        XCTAssertEqual(clone?.kind, .file)
        XCTAssertEqual(clone?.logicalSize, 100_000)
        XCTAssertEqual(clone?.reclaimableSize, 0, "未改写克隆:删它一个字节都回收不了(探针 11 ④)")
        XCTAssertEqual(byName["a.bin"]?.reclaimableSize, 0, "克隆在场:删原件同样回收 0(共享 extent 组互为保留)")
        // 无克隆伙伴的文件才持有全部私有字节:sub/b.txt(1000B)对照
        let subEntries = try await LiveCleanDirectoryEnumerator()
            .entries(ofDirectory: root.appendingPathComponent("sub").path)
        XCTAssertEqual(subEntries.first?.name, "b.txt")
        XCTAssertGreaterThan(subEntries.first?.reclaimableSize ?? 0, 0)
        // 身份键去重的前提:同目录内 fileID 各不相同
        let ids = Set(entries.filter { $0.kind == .file }.map(\.fileID))
        XCTAssertEqual(ids.count, entries.filter { $0.kind == .file }.count)
    }

    func testPermissionDeniedAndVanishedClassification() async throws {
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let enumerator = LiveCleanDirectoryEnumerator()
        // 父目录照常枚举(条目在,失败发生在下潜那一层)
        let parent = try await enumerator.entries(ofDirectory: root.path)
        XCTAssertTrue(parent.contains { $0.name == "locked" })

        do {
            _ = try await enumerator.entries(ofDirectory: locked.path)
            XCTFail("应抛权限错")
        } catch let error as CleanEnumerateError {
            XCTAssertEqual(error.reason, .permissionDenied)
        }
        do {
            _ = try await enumerator.entries(ofDirectory: root.path + "/nope")
            XCTFail("应抛 vanished")
        } catch let error as CleanEnumerateError {
            XCTAssertEqual(error.reason, .vanished)
        }
    }

    private func fileID(of path: String) throws -> UInt64 {
        var status = stat()
        guard stat(path, &status) == 0 else { throw NSError(domain: "stat", code: 1) }
        return status.st_ino
    }
}
