import XCTest
import Darwin
@testable import Pulse

/// 接缝:KillService(工单 08)——处置的 OS 边界适配器(LiveKillService → kill(2))。
/// errno → 可读失败原因的映射用真实内核结果验证:刚 reap 的 pid = ESRCH、
/// launchd(root 属主)= EPERM、对自身发信号 0 = 成功且无害。
/// 编排逻辑(SIGTERM / 排除自身 / 失败隔离)见 KillActionTests。
final class KillServiceTests: XCTestCase {
    /// 刚退出并被 reap 的 pid:macOS pid 顺序递增分配,短期内不会被复用。
    private func reapedChildPID() -> pid_t {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0"]
        XCTAssertNoThrow(try child.run())
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        return child.processIdentifier
    }

    /// 已退出的进程:kill(2) 返回 ESRCH → 映射为 noSuchProcess("进程已退出")。
    func testDeadPIDMapsToNoSuchProcess() {
        let deadPID = reapedChildPID()

        let result = LiveKillService().send(signal: SIGTERM, to: deadPID)

        XCTAssertEqual(result, .failed(.noSuchProcess))
    }

    /// root 属主进程(launchd,pid 1):普通用户无权 → EPERM → permissionDenied
    /// ("无权限")。发的是信号 0(存在性探测),即使有权限也不会杀,测试绝对安全。
    func testRootOwnedPIDMapsToPermissionDenied() {
        let result = LiveKillService().send(signal: 0, to: 1)

        XCTAssertEqual(result, .failed(.permissionDenied))
    }

    /// 存活且有权发信号:kill(2) 返回 0 → delivered。用信号 0 验证成功路径,
    /// 不会真的给测试宿主发任何信号。
    func testLiveSelfPIDWithSignalZeroDelivers() {
        let result = LiveKillService().send(signal: 0, to: getpid())

        XCTAssertEqual(result, .delivered)
    }
}
