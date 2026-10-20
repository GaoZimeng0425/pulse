import XCTest
import Darwin
@testable import PulseCore

/// 接缝:处置文案(工单 08)——确认对话框与结果汇总的纯函数文案构造。
/// 单进程确认必须列出 name+pid、整组确认必须列出进程数(工单验收点);
/// 结果文案失败逐目标浮出、全成功保持安静(交给下轮采样,不假装成功也不报喜)。
final class KillCopyTests: XCTestCase {
    private func outcome(_ pid: pid_t, name: String, _ result: KillSignalResult) -> KillOutcome {
        KillOutcome(target: KillTarget(pid: pid, name: name), result: result)
    }

    // MARK: 确认对话框(单进程)

    /// 单进程:标题点名对象(name+pid),内容说明信号与后果。
    func testSingleProcessConfirmationListsNameAndPID() {
        let targets = [KillTarget(pid: 100, name: "rustc")]

        XCTAssertEqual(
            KillCopy.confirmationTitle(for: targets),
            "结束进程 rustc(pid 100)?"
        )
        XCTAssertEqual(
            KillCopy.confirmationMessage(for: targets),
            "将向 rustc(pid 100)发送结束信号(SIGTERM),进程可保存后退出。"
        )
    }

    /// 路径受限的进程:名字退 "pid N" 口径(与下钻行一致)。
    func testSingleProcessConfirmationFallsBackToPIDName() {
        let targets = [KillTarget(pid: 31, name: "pid 31")]

        XCTAssertEqual(KillCopy.confirmationTitle(for: targets), "结束进程 pid 31(pid 31)?")
    }

    // MARK: 确认对话框(整组)

    /// 整组:标题点组名,内容列出进程数(spec:对话框列出进程数)。
    func testGroupConfirmationListsProcessCount() {
        XCTAssertEqual(
            KillCopy.groupConfirmationTitle(groupName: "octok-client @ wt"),
            "结束整组 octok-client @ wt?"
        )
        XCTAssertEqual(
            KillCopy.groupConfirmationMessage(processCount: 3),
            "将结束该组的 3 个进程,每个都会收到结束信号(SIGTERM)。"
        )
        XCTAssertEqual(
            KillCopy.groupConfirmationMessage(processCount: 1),
            "将结束该组的 1 个进程,并发送结束信号(SIGTERM)。"
        )
    }

    // MARK: 结果汇总

    /// 全部成功:无失败——UI 安静,消失交给下轮采样(不弹窗、不假装)。
    func testAllDeliveredReportHasNoFailures() {
        let report = KillReport(outcomes: [
            outcome(100, name: "rustc", .delivered),
            outcome(101, name: "cargo", .delivered),
        ])

        XCTAssertFalse(report.hasFailures)
        XCTAssertTrue(report.failures.isEmpty)
    }

    /// 部分失败:标题"部分进程未能结束",内容逐目标列出失败原因。
    func testPartialFailureReportListsPerTargetReasons() {
        let report = KillReport(outcomes: [
            outcome(100, name: "rustc", .delivered),
            outcome(200, name: "mDNSResponder", .failed(.permissionDenied)),
            outcome(201, name: "gone", .failed(.noSuchProcess)),
        ])

        XCTAssertTrue(report.hasFailures)
        XCTAssertEqual(report.failureAlertTitle, "部分进程未能结束")
        XCTAssertEqual(
            report.failureAlertMessage,
            "已结束 1 个,2 个未能结束:\n"
                + "• mDNSResponder(pid 200):无权限结束(可能属于 root)\n"
                + "• gone(pid 201):进程已退出"
        )
    }

    /// 全部失败:标题明示"未能结束任何进程",内容逐目标列出。
    func testAllFailedReportSaysNothingEnded() {
        let report = KillReport(outcomes: [
            outcome(200, name: "mDNSResponder", .failed(.permissionDenied)),
        ])

        XCTAssertTrue(report.allFailed)
        XCTAssertEqual(report.failureAlertTitle, "未能结束任何进程")
        XCTAssertEqual(
            report.failureAlertMessage,
            "• mDNSResponder(pid 200):无权限结束(可能属于 root)"
        )
    }

    /// 空结果(组在确认期间已消失):无失败、不弹任何文案。
    func testEmptyReportIsQuiet() {
        let report = KillReport(outcomes: [])

        XCTAssertFalse(report.hasFailures)
        XCTAssertFalse(report.allFailed)
    }
}
