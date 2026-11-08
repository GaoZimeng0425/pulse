@testable import Pulse
import PulseCore
import XCTest

/// 删前复核的 Live 换算一致性冒烟(p5-cleaner/03):扫描枚举器(getattrlistbulk
/// ATTR_CMN_MODTIME)与删前探针(lstat st_mtimespec)读同一 inode 字段、同一公式
/// (`FsTimestamp.epoch`)换算——对同一个真实目录必须逐位相等,否则闸会把没动过的
/// 目录全部误判成「有变动」。合成夹具:临时目录一个,只读对照,删后即清。
final class PreDeleteLiveConsistencyTests: XCTestCase {
    func testEnumeratorMtimeEqualsLstatSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-predelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 固定一个非整秒 mtime(验纳秒段):设 2001-01-01 00:00:01.234567 UTC。
        let stamp = Date(timeIntervalSince1970: 1 + 0.234_567)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp], ofItemAtPath: dir.path
        )

        let entries = try await LiveCleanDirectoryEnumerator()
            .entries(ofDirectory: dir.deletingLastPathComponent().path)
        let entry = try XCTUnwrap(entries.first { $0.name == dir.lastPathComponent }, "夹具目录应被枚举")
        let snapshot = await LiveCleanTrashExecutor().currentState(ofPath: dir.path)
        guard case let .present(lstatMtime) = snapshot else {
            return XCTFail("lstat 应读到夹具目录,得到 \(snapshot)")
        }
        XCTAssertEqual(
            entry.modifiedEpoch.map { ($0 * 1e6).rounded() },
            (lstatMtime * 1e6).rounded(),
            "枚举器与删前探针的 mtime 必须同一换算(µs 级对齐,APFS 纳秒截断容忍)"
        )
    }
}
