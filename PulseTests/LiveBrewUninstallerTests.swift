@testable import Pulse
import PulseCore
import XCTest

/// brew 子进程收尾(cleaner-hardening/03):替身脚本冒充 brew,不碰真 brew。
/// 回归钉:大量输出不得把子进程卡死在写管道上(旧实现 stdout 从不读,写满即挂到超时强杀)。
final class LiveBrewUninstallerTests: XCTestCase {
    private var scriptDir: URL!

    override func setUpWithError() throws {
        scriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scriptDir)
    }

    private func fakeBrew(_ body: String) throws -> String {
        let url = scriptDir.appendingPathComponent("brew")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testLargeOutputOnBothStreamsDoesNotHang() async throws {
        // 每路 ~512KB,远超管道缓冲;超时设 10s——卡死会以「超时」失败而非成功。
        let brew = try fakeBrew("""
        head -c 524288 /dev/zero | tr '\\0' 'o'
        head -c 524288 /dev/zero | tr '\\0' 'e' 1>&2
        exit 0
        """)
        var uninstaller = LiveBrewUninstaller()
        uninstaller.executableOverride = brew
        uninstaller.timeout = 10
        let result = await uninstaller.uninstall(cask: "foo", zap: false)
        XCTAssertEqual(result, .success)
    }

    func testFailureReportsLastStderrLine() async throws {
        let brew = try fakeBrew("""
        echo "Warning: noise" 1>&2
        echo "Error: Cask 'foo' is not installed." 1>&2
        exit 1
        """)
        var uninstaller = LiveBrewUninstaller()
        uninstaller.executableOverride = brew
        let result = await uninstaller.uninstall(cask: "foo", zap: true)
        XCTAssertEqual(result, .failed(message: "Error: Cask 'foo' is not installed."))
    }

    func testTimeoutTerminatesAndSaysSo() async throws {
        let brew = try fakeBrew("sleep 30")
        var uninstaller = LiveBrewUninstaller()
        uninstaller.executableOverride = brew
        uninstaller.timeout = 0.5
        let result = await uninstaller.uninstall(cask: "foo", zap: false)
        guard case let .failed(message) = result else {
            return XCTFail("应超时失败,实得 \(result)")
        }
        XCTAssertTrue(message.contains("未完成"), message)
    }
}
