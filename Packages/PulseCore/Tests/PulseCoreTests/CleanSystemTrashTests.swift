@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 系统级条目移进废纸篓(需要授权)——接缝 3(p7-cleaner/05;ADR-0012)。
/// 假授权接口 + 假废纸篓执行器:断言收到的路径集合、先后次序、取消时整批不动。
/// 真实提权路径不进自动化测试。
final class CleanSystemTrashTests: XCTestCase {
    private let reports = "/Library/Logs/DiagnosticReports"
    private let uid: UInt32 = 501
    private var systemPathA: String {
        reports + "/a.diag"
    }

    private var systemPathC: String {
        reports + "/c.ips"
    }

    private var userPath: String {
        "/Users/t/Library/Caches/Homebrew"
    }

    private func candidate(_ path: String, system: Bool) -> JunkCandidate {
        JunkCandidate(
            ruleID: system ? "system.crashReports" : "fixture.rule",
            group: system ? .systemLevel : .appCache,
            title: (path as NSString).lastPathComponent,
            path: path,
            tier: .safe,
            bytes: 100,
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: true,
            rationale: "夹具",
            symbolName: "folder",
            // 与假废纸篓的删前复核快照同一时刻(「扫描后没动过」)。
            modifiedAtScan: CleanFixture.directoryModified,
            flags: system ? [.requiresAuthorization] : []
        )
    }

    private func completedReport(
        _ termination: CleanRunTermination,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CleanRunReport? {
        guard case let .completed(report) = termination else {
            XCTFail("应走完,实际 \(termination)", file: file, line: line)
            return nil
        }
        return report
    }

    // MARK: 主路径

    /// 带「需要管理员权限」的条目只交给授权接口,用户态条目只交给废纸篓执行器;授权接口
    /// 收到的正是确认清单里的系统级路径与调用者身份。先做系统级,再作用户态。逐项去向进战报。
    func testSystemItemsGoToTheAuthorizedMoverFirstThenUserItemsToTrash() async throws {
        let trash = FakeCleanTrashExecutor(nextRecycleOutcome: recycled([userPath]))
        // 在授权接口被调用的那一刻看一眼废纸篓执行器:必须还没轮到它。
        let order = OrderLog()
        let mover = FakeCleanSystemTrashExecutor(handler: { request in
            let batchesSoFar = await trash.recycleCalls.count
            order.note("授权接口被调时,废纸篓执行器已收到的批次:\(batchesSoFar)")
            return .completed(recycled(request.paths, under: systemTrashRoot))
        })
        let plan = CleanPlan(items: [
            candidate(systemPathA, system: true),
            candidate(userPath, system: false),
            candidate(systemPathC, system: true),
        ])

        let termination = await CleanRunner.run(
            plan, using: trash, systemTrash: mover, requesterUID: uid
        )
        let report = try XCTUnwrap(completedReport(termination))

        XCTAssertEqual(mover.requests, [SystemTrashRequest(paths: [systemPathA, systemPathC], requesterUID: uid)])
        let calls = await trash.recycleCalls
        XCTAssertEqual(calls, [[userPath]], "用户态条目照旧走废纸篓执行器,系统级条目不混进去")
        XCTAssertEqual(order.entries, ["授权接口被调时,废纸篓执行器已收到的批次:0"])
        XCTAssertEqual(report.items.map(\.outcome), [
            .recycled(destination: systemTrashRoot + "/a.diag"),
            .recycled(destination: "/Users/t/.Trash/Homebrew"),
            .recycled(destination: systemTrashRoot + "/c.ips"),
        ])
        XCTAssertEqual(report.items.filter { $0.flags == [.requiresAuthorization] }.count, 2, "条目标志随战报行走")
        XCTAssertEqual(report.freedBytes, 300)
    }

    /// 没有系统级条目就不问授权:授权接口一次都不被调。
    func testNoSystemItemsNeverAsksForAuthorization() async throws {
        let mover = FakeCleanSystemTrashExecutor(handler: { _ in .authorizationCancelled })
        let plan = CleanPlan(items: [candidate(userPath, system: false)])

        let termination = await CleanRunner.run(
            plan, using: FakeCleanTrashExecutor(nextRecycleOutcome: recycled([userPath])),
            systemTrash: mover, requesterUID: uid
        )
        let report = try XCTUnwrap(completedReport(termination))

        XCTAssertTrue(mover.requests.isEmpty)
        XCTAssertEqual(report.recycledPaths, [userPath])
    }

    // MARK: 没开始就停:整批不动

    /// 用户在密码框点了取消:整批都没动——用户态条目也不交给废纸篓执行器。
    func testCancelledAuthorizationStartsNothing() async {
        let trash = FakeCleanTrashExecutor(nextRecycleOutcome: recycled([userPath]))
        let mover = FakeCleanSystemTrashExecutor(handler: { _ in .authorizationCancelled })
        let plan = CleanPlan(items: [candidate(systemPathA, system: true), candidate(userPath, system: false)])

        let termination = await CleanRunner.run(plan, using: trash, systemTrash: mover, requesterUID: uid)

        XCTAssertEqual(termination, .aborted(.authorizationCancelled))
        let calls = await trash.recycleCalls
        XCTAssertTrue(calls.isEmpty, "取消授权 = 这一批都不动")
    }

    /// 授权之后的通道用不了(脚本缺失、自身出错、系统拒绝运行):同样整批不动,原因原样带出。
    func testUnavailableChannelStartsNothing() async {
        let trash = FakeCleanTrashExecutor(nextRecycleOutcome: recycled([userPath]))
        let mover = FakeCleanSystemTrashExecutor(handler: { _ in .channelUnavailable(reason: "复核脚本缺失") })
        let plan = CleanPlan(items: [candidate(systemPathA, system: true), candidate(userPath, system: false)])

        let termination = await CleanRunner.run(plan, using: trash, systemTrash: mover, requesterUID: uid)

        XCTAssertEqual(termination, .aborted(.channelUnavailable(reason: "复核脚本缺失")))
        let calls = await trash.recycleCalls
        XCTAssertTrue(calls.isEmpty)
    }

    /// 装配点漏了授权接口而清单里有系统级条目:按通道不可用报,绝不把它们塞给废纸篓执行器。
    func testMissingMoverWithSystemItemsIsReportedUnavailable() async {
        let trash = FakeCleanTrashExecutor(nextRecycleOutcome: recycled([systemPathA]))
        let plan = CleanPlan(items: [candidate(systemPathA, system: true)])

        let termination = await CleanRunner.run(plan, using: trash, systemTrash: nil, requesterUID: uid)

        guard case let .aborted(.channelUnavailable(reason)) = termination else {
            return XCTFail("应按通道不可用停住,实际 \(termination)")
        }
        XCTAssertFalse(reason.isEmpty)
        let calls = await trash.recycleCalls
        XCTAssertTrue(calls.isEmpty, "系统级条目永远不走用户态的废纸篓执行器")
    }

    // MARK: 闸门照常

    /// 删前复核对系统级条目照常生效:扫描后动过的那一条不到授权接口,战报里如实记原因;
    /// 没动过的照走。系统级条目全被复核挡下时,不问授权。
    func testPreDeleteCheckGatesSystemItems() async throws {
        let changed = reports + "/changed.diag"
        let plan = CleanPlan(items: [candidate(changed, system: true), candidate(systemPathA, system: true)])
        let mover = FakeCleanSystemTrashExecutor(handler: { .completed(recycled($0.paths, under: systemTrashRoot)) })

        let first = await CleanRunner.run(
            plan,
            using: FakeCleanTrashExecutor(pathStates: [changed: .present(modifiedEpoch: CleanFixture
                    .directoryModified + 60)]),
            systemTrash: mover, requesterUID: uid
        )
        let report = try XCTUnwrap(completedReport(first))

        XCTAssertEqual(mover.requests.map(\.paths), [[systemPathA]])
        XCTAssertEqual(report.items.map(\.path), [changed, systemPathA], "战报与确认清单同序")
        XCTAssertEqual(report.failed.map(\.path), [changed])
        XCTAssertEqual(report.recycledPaths, [systemPathA])

        let quietMover =
            FakeCleanSystemTrashExecutor(handler: { .completed(recycled($0.paths, under: systemTrashRoot)) })
        let secondRun = await CleanRunner.run(
            plan,
            using: FakeCleanTrashExecutor(pathStates: [
                changed: .present(modifiedEpoch: CleanFixture.directoryModified + 60),
                systemPathA: .missing,
            ]),
            systemTrash: quietMover, requesterUID: uid
        )
        let second = try XCTUnwrap(completedReport(secondRun))

        XCTAssertTrue(quietMover.requests.isEmpty, "系统级条目全被复核挡下:不问授权")
        XCTAssertEqual(second.failed.count, 2)
    }

    /// 授权接口逐项回执:没动的条目带原因进战报(在用保护、属主不符、移动失败都走这里);
    /// 既没说成功也没说失败的按失败记,不默认成功。
    func testPerItemSkipReasonsAreReported() async throws {
        let pathA = systemPathA
        let pathC = systemPathC
        let plan = CleanPlan(items: [candidate(pathA, system: true), candidate(pathC, system: true)])

        let mover = FakeCleanSystemTrashExecutor(handler: { _ in
            .completed(TrashRecycleOutcome(
                recycled: [pathA: systemTrashRoot + "/a.diag"],
                failures: [pathC: "属主不是 root 或系统用户"]
            ))
        })
        let first = await CleanRunner.run(plan, using: FakeCleanTrashExecutor(), systemTrash: mover, requesterUID: uid)
        let report = try XCTUnwrap(completedReport(first))

        XCTAssertEqual(report.items.map(\.outcome), [
            .recycled(destination: systemTrashRoot + "/a.diag"),
            .failed(reason: "属主不是 root 或系统用户"),
        ])
        XCTAssertEqual(report.freedBytes, 100)

        let silent = FakeCleanSystemTrashExecutor()
        let second = await CleanRunner.run(
            plan,
            using: FakeCleanTrashExecutor(),
            systemTrash: silent,
            requesterUID: uid
        )
        let third = try XCTUnwrap(completedReport(second))
        XCTAssertEqual(third.items.map(\.outcome), [.failed(reason: "执行器未报告结果"), .failed(reason: "执行器未报告结果")])
    }
}

/// 系统级条目进废纸篓后的专属子目录(夹具路径)。
private let systemTrashRoot = "/Users/t/.Trash/Pulse 系统级"

/// 夹具回执:每个路径都移到 `<root>/<文件名>`。
private func recycled(_ paths: [String], under root: String = "/Users/t/.Trash") -> TrashRecycleOutcome {
    TrashRecycleOutcome(recycled: Dictionary(uniqueKeysWithValues: paths.map { (
        $0,
        root + "/" + ($0 as NSString).lastPathComponent
    ) }))
}

/// 调用次序记录(只在测试里读写)。
/// `@unchecked Sendable` 的前提:`stored` 的全部访问都经 `lock`(从 `@Sendable` 的处理闭包里写)。
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func note(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(entry)
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
