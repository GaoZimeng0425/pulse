import XCTest
import Darwin
@testable import Pulse

/// 端到端(工单 08 验收锚点):自造一个真实 sleep 进程组(一个 zsh 宿主 +
/// 3 个 sleep 300 子进程),走**完全真实的代码路径**——LiveProcessSource 采样
/// 发现组员 → 下钻数据(RawProcess)构处置目标 → KillAction + LiveKillService
/// 发 SIGTERM → 进程真的死 → 复扫确认从进程表消失。
final class KillEndToEndTests: XCTestCase {
    private let source = LiveProcessSource()

    /// 按轮等待采样,直到谓词命中或超时;返回最后一张快照。
    private func sweepUntil(
        timeout: TimeInterval = 8,
        _ predicate: (ProcessSnapshot) -> Bool
    ) -> ProcessSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var snapshot = source.snapshot()
        while !predicate(snapshot) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            snapshot = source.snapshot()
        }
        return snapshot
    }

    func testRealSleepGroupReallyDiesThroughRealService() {
        // 1. 自造进程组:zsh 宿主 + 3 个 sleep 300 子进程(失控 dev 会话的最小形态)。
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", "sleep 300 & sleep 300 & sleep 300 & wait"]
        XCTAssertNoThrow(try shell.run())
        let shellPID = shell.processIdentifier
        defer {
            if shell.isRunning { shell.terminate() }
        }

        // 2. 等真实采样看到它们(Pulse 的 live 路径):宿主 + 以它为父的 3 个 sleep。
        let seen = sweepUntil { snapshot in
            let members = Self.groupMembers(of: shellPID, in: snapshot)
            return members.sleeps.count == 3
        }
        let members = Self.groupMembers(of: shellPID, in: seen)
        guard members.sleeps.count == 3, let host = members.host else {
            return XCTFail("真实采样应在 8s 内看到 zsh(pid \(shellPID))与 3 个 sleep 子进程,实际:\(members)")
        }
        XCTAssertEqual(host.parentPID, getpid(), "zsh 宿主的父是测试进程")

        // 3. 下钻数据构组目标:宿主 + 全部子进程(与组卡"结束整组"同一映射)。
        let targets = ([host] + members.sleeps).map(\.killTarget)
        XCTAssertEqual(targets.map(\.pid).sorted(), [shellPID] + members.sleeps.map(\.pid).sorted())

        // 4. 真实处置:KillAction 编排 + LiveKillService(kill(2)),排除自身 pid。
        let report = KillReport(outcomes: KillAction.terminate(
            targets,
            excluding: getpid(),
            service: LiveKillService()
        ))
        XCTAssertFalse(
            report.hasFailures,
            "全部 4 个真实进程都应投递成功,失败:\(report.failureAlertMessage)"
        )

        // 5. 它们真的死了:宿主由 SIGTERM 终止(sleep/zsh 无处理程序 → uncaughtSignal)。
        shell.waitUntilExit()
        XCTAssertEqual(
            shell.terminationReason,
            Process.TerminationReason.uncaughtSignal,
            "zsh 宿主应被信号终止,实际:\(shell.terminationReason) status \(shell.terminationStatus)"
        )

        // 6. 复扫:整个组(宿主 + 3 个 sleep)从进程表消失——"下轮刷新消失"。
        let after = sweepUntil(timeout: 8) { snapshot in
            let remaining = Self.groupMembers(of: shellPID, in: snapshot)
            return remaining.host == nil && remaining.sleeps.isEmpty
        }
        let remaining = Self.groupMembers(of: shellPID, in: after)
        XCTAssertTrue(
            remaining.host == nil && remaining.sleeps.isEmpty,
            "处置后复扫不应再见到任何组员,实际:宿主 \(String(describing: remaining.host?.pid)),sleeps \(remaining.sleeps.map(\.pid))"
        )
    }

    /// "组员"口径:宿主自身 + 以宿主为父的全部 sleep 子进程(真实采样数据)。
    private static func groupMembers(
        of hostPID: pid_t,
        in snapshot: ProcessSnapshot
    ) -> (host: RawProcess?, sleeps: [RawProcess]) {
        let host = snapshot.processes.first { $0.pid == hostPID }
        let sleeps = snapshot.processes.filter {
            $0.parentPID == hostPID && ($0.executablePath ?? "").hasSuffix("/sleep")
        }
        return (host, sleeps)
    }
}
