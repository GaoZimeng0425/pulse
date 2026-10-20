import XCTest
@testable import Pulse
@testable import PulseCore

/// 架构审查票 A 中6:nettop 子进程健壮性。
/// ①看门狗升级链(真实子进程,/bin/sh 扮 nettop):超时 SIGTERM → 宽限期后仍在跑
///   SIGKILL——吞 SIGTERM 的子进程不再让专用串行队列永久冻结;
/// ②状态沿日志(纯逻辑):收尾方式变化才记一条,持续同态静默
///   (transition-not-tick,沿 HistoryEngine.databaseHealthy 惯例)。
final class NettopWatchdogTests: XCTestCase {

    // MARK: - ① 看门狗升级链(真实子进程)

    /// Live 源:/bin/sh -c 脚本扮演 nettop。时限逐例给——只放宽不触发的那一级
    /// (进程一退出 run 即返回,放宽不增耗时),给 sh 启动留足高负载余量
    /// (代码审查 M2:压测下 sh 启动 13–133ms)。trap '' TERM 设的 SIG_IGN 跨
    /// exec 保留,exec 后的 sleep 因此吞掉 SIGTERM。
    private func source(
        script: String,
        timeout: TimeInterval,
        killGrace: TimeInterval
    ) -> LiveNettopCSVSource {
        LiveNettopCSVSource(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            timeout: timeout,
            killGrace: killGrace
        )
    }

    func testIgnoredSIGTERMEscalatesToSIGKILL() async {
        let started = Date()
        let run = await source(
            script: "trap '' TERM; echo header; exec sleep 30",
            timeout: 1,
            killGrace: 0.2
        ).run()
        XCTAssertEqual(run.outcome, .killed, "吞 SIGTERM 的子进程须被 SIGKILL 收尾")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "超时 + 宽限后即返回,不等子进程自然结束")
        XCTAssertEqual(run.text?.hasPrefix("header"), true, "收尾前已写出的输出照常交付(解析器逐行容错)")
    }

    func testCooperativeChildIsTerminatedBySIGTERM() async {
        let run = await source(script: "exec sleep 30", timeout: 0.2, killGrace: 5).run()
        XCTAssertEqual(run.outcome, .terminated)
    }

    func testGrandchildHoldingThePipeIsKilledWithTheGroup() async {
        // 孙进程继承管道写端:只杀子进程等不到 EOF;SIGKILL 发给整个进程组
        // (Process 让子进程自成一组),孙进程一并收尾。
        let started = Date()
        let run = await source(script: "trap '' TERM; sleep 30 & wait", timeout: 1, killGrace: 0.2).run()
        XCTAssertEqual(run.outcome, .killed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "孙进程不再占住管道")
    }

    func testChildThatClosesStdoutButLingersIsStillKilled() async {
        // 先关 stdout 再赖着不走:读端立即 EOF,随后阻塞在 waitUntilExit——
        // 它没有超时,只能靠看门狗兜底(看门狗不可在 EOF 后取消,代码审查 M3)。
        let started = Date()
        let run = await source(script: "exec >&-; trap '' TERM; exec sleep 30", timeout: 1, killGrace: 0.2).run()
        XCTAssertEqual(run.outcome, .killed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCompletedRunReturnsOutput() async {
        let run = await source(script: "echo header; echo app.42,10,20", timeout: 5, killGrace: 5).run()
        XCTAssertEqual(run.outcome, .completed)
        XCTAssertEqual(run.text, "header\napp.42,10,20\n")
    }

    func testNonZeroExitIsReportedAsAbnormal() async {
        // 系统更新改掉 -k 里某个列名时,nettop 立即以 64 退出、stdout 为空
        // (代码审查 M1 实测):不能当正常收尾静默吞掉,排行会永久空白而无日志。
        let run = await source(script: "exit 64", timeout: 5, killGrace: 5).run()
        XCTAssertEqual(run.outcome, .exitedAbnormally(status: 64))
        XCTAssertEqual(run.text, "", "文本照常交付(解析为空表)")
    }

    func testLaunchFailureReturnsNil() async {
        let missing = LiveNettopCSVSource(
            executablePath: "/nonexistent/nettop",
            arguments: [],
            timeout: 0.2,
            killGrace: 0.2
        )
        let run = await missing.run()
        XCTAssertNil(run.text, "起不来 = 读失败(消费方保 lastGood)")
        guard case .launchFailed = run.outcome else {
            return XCTFail("应为 launchFailed,实际 \(run.outcome)")
        }
    }

    func testLiveNettopCompletesWithinTimeout() async throws {
        // 真机冒烟:默认命令(/usr/bin/nettop -P -L 1)正常亚秒返回、不触发看门狗,
        // 首行是解析器约定的表头。
        let run = await LiveNettopCSVSource().run()
        if case .launchFailed(let reason) = run.outcome {
            throw XCTSkip("本机 nettop 起不来:\(reason)")
        }
        XCTAssertEqual(run.outcome, .completed)
        XCTAssertEqual(run.text?.split(whereSeparator: \.isNewline).first?.contains("bytes_in"), true)
    }

    // MARK: - ② 状态沿日志(纯逻辑)

    func testSteadySuccessStaysSilent() {
        var health = NettopHealthLog()
        XCTAssertNil(health.transition(to: .completed), "开机即正常:不记")
        XCTAssertNil(health.transition(to: .completed))
    }

    func testFailureLogsOnceThenStaysSilentUntilRecovery() {
        var health = NettopHealthLog()
        XCTAssertEqual(health.transition(to: .terminated)?.level, .error, "进入失败态记一条")
        XCTAssertNil(health.transition(to: .terminated), "持续同态静默(5s 一档不刷屏)")
        XCTAssertEqual(health.transition(to: .completed)?.level, .info, "恢复边记一条")
        XCTAssertNil(health.transition(to: .completed))
    }

    func testFailureKindChangeLogsAgain() {
        // 失败形态变化(SIGTERM 收得住 → 收不住)是新信号:再记一条。
        var health = NettopHealthLog()
        _ = health.transition(to: .terminated)
        let escalated = health.transition(to: .killed)
        XCTAssertEqual(escalated?.level, .error)
        XCTAssertEqual(escalated?.message.contains("SIGKILL"), true)
    }

    func testAbnormalExitMessageCarriesStatus() {
        var health = NettopHealthLog()
        let entry = health.transition(to: .exitedAbnormally(status: 64))
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.message.contains("64"), true)
    }

    func testLaunchFailureMessageCarriesReason() {
        var health = NettopHealthLog()
        let entry = health.transition(to: .launchFailed("找不到文件"))
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.message.contains("找不到文件"), true)
        XCTAssertNil(health.transition(to: .launchFailed("找不到文件")), "同因重复静默")
    }
}
