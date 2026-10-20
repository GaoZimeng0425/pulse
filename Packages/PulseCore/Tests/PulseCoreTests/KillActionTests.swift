import XCTest
import Darwin
@testable import PulseCore

/// 接缝:KillAction(工单 08)——确认后的处置编排(纯逻辑,注入假 KillService)。
/// 覆盖 spec 的三条硬约束:SIGTERM(优雅优先)/ 永不信号自身 pid(防自杀,
/// 即使它出现在组员里)/ 单个失败不中断其余且逐目标浮出可读结果。
final class KillActionTests: XCTestCase {
    /// 假服务:按 pid 记录每次调用(目标 + 信号),可注入逐 pid 的失败剧本。
    private final class FakeKillService: KillService, @unchecked Sendable {
        struct Call: Equatable {
            let pid: pid_t
            let signal: Int32
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _callsWhenMade: [Call] = [] // 每次调用即定格,判断"未提前放弃"
        /// pid → 该 pid 第 N 次调用时的失败剧本(下标耗尽后按 delivered)。
        private var failuresByPID: [pid_t: [KillSignalFailure]] = [:]

        func send(signal: Int32, to pid: pid_t) -> KillSignalResult {
            lock.lock()
            defer { lock.unlock() }
            let call = Call(pid: pid, signal: signal)
            _calls.append(call)
            _callsWhenMade.append(call)
            let script = failuresByPID[pid] ?? []
            if !script.isEmpty {
                failuresByPID[pid] = Array(script.dropFirst())
                return .failed(script[0])
            }
            return .delivered
        }

        func fail(_ pid: pid_t, with failures: KillSignalFailure...) {
            lock.lock()
            defer { lock.unlock() }
            failuresByPID[pid] = failures
        }

        /// 断言口径:目标集合无序比较(逐目标遍历顺序是实现细节)。
        var callPIDSet: Set<pid_t> {
            lock.lock()
            defer { lock.unlock() }
            return Set(_calls.map(\.pid))
        }

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }
    }

    private func target(_ pid: pid_t, name: String = "proc") -> KillTarget {
        KillTarget(pid: pid, name: name)
    }

    // MARK: 信号与目标

    /// 整组场景:组内全部成员都收到 SIGTERM(优雅退出优先,spec)。
    func testTerminatesEveryGroupMemberWithSIGTERM() {
        let fake = FakeKillService()
        let targets = [target(100, name: "rustc"), target(101, name: "cargo"), target(102, name: "node")]

        let outcomes = KillAction.terminate(targets, excluding: getpid(), service: fake)

        XCTAssertEqual(fake.callPIDSet, [100, 101, 102], "每个目标都应被发信号")
        XCTAssertTrue(fake.calls.allSatisfy { $0.signal == SIGTERM }, "信号必须是 SIGTERM,实际:\(fake.calls)")
        XCTAssertEqual(outcomes.map(\.target.pid).sorted(), [100, 101, 102])
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
    }

    // MARK: 自身 pid 守卫

    /// Pulse 自身 pid 出现在组员里(归组含自身属正常):必须被无条件排除,
    /// 其余目标照常处置——且排除发生在发信号之前(假服务不应见过自身 pid)。
    func testNeverSignalsOwnPIDEvenWhenListedInTargets() {
        let fake = FakeKillService()
        let ownPID = getpid()
        let targets = [target(501, name: "helper"), target(ownPID, name: "Pulse"), target(502, name: "sleep")]

        let outcomes = KillAction.terminate(targets, excluding: ownPID, service: fake)

        XCTAssertEqual(fake.callPIDSet, [501, 502], "自身 pid 绝不能被发信号")
        XCTAssertEqual(outcomes.map(\.target.pid).sorted(), [501, 502], "自身 pid 不出现在结果里")
    }

    /// 全部目标都是自身(极端):零调用、零结果。
    func testTargetsContainingOnlyOwnPIDDoNothing() {
        let fake = FakeKillService()
        let ownPID = getpid()

        let outcomes = KillAction.terminate([target(ownPID)], excluding: ownPID, service: fake)

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: 失败隔离

    /// root 进程(EPERM)、已退出进程(ESRCH)与成功对象混在一组:
    /// 后续目标继续处置(不因前者中断),每个目标各得其可读结果。
    func testPerTargetFailureDoesNotAbortTheRest() {
        let fake = FakeKillService()
        fake.fail(100, with: .permissionDenied) // root 属主
        fake.fail(101, with: .noSuchProcess) // 已退出
        let targets = [target(100, name: "launchd"), target(101, name: "gone"), target(102, name: "sleep")]

        let outcomes = KillAction.terminate(targets, excluding: getpid(), service: fake)

        XCTAssertEqual(fake.callPIDSet, [100, 101, 102], "失败不中断:三个目标都应被尝试")
        let byPID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.target.pid, $0) })
        XCTAssertEqual(byPID[100]?.result, .failed(.permissionDenied))
        XCTAssertEqual(byPID[100]?.message, "无权限结束(可能属于 root)")
        XCTAssertEqual(byPID[101]?.result, .failed(.noSuchProcess))
        XCTAssertEqual(byPID[101]?.message, "进程已退出")
        XCTAssertEqual(byPID[102]?.result, .delivered, "正常目标不受前两个失败影响")
        XCTAssertTrue(byPID[102]?.succeeded == true)
    }

    /// 空目标清单(组在确认对话框期间已消失):零调用、零结果。
    func testEmptyTargetsProduceEmptyOutcomes() {
        let fake = FakeKillService()

        let outcomes = KillAction.terminate([], excluding: getpid(), service: fake)

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertTrue(outcomes.isEmpty)
    }
}
