import XCTest
import Darwin
@testable import Pulse

/// 接缝:LiveProcessSource 冒烟测试(spec 测试决策:探针已验证的部分不重复深测,
/// 只证明采集在本机真实可用、降级路径安全、耗时毫秒级)。
final class LiveProcessSourceSmokeTests: XCTestCase {
    private let source = LiveProcessSource()

    private func firstProcess(where predicate: (RawProcess) -> Bool, in snapshot: ProcessSnapshot) -> RawProcess? {
        snapshot.processes.first(where: predicate)
    }

    func testSweepReturnsManyProcessesInMilliseconds() {
        let start = Date()
        let snapshot = source.snapshot()
        let coldMs = Date().timeIntervalSince(start) * 1000
        // 稳态口径:后续几轮(缓冲已热)取平均,这是采样循环每 1–5s 的真实开销。
        var warmMs = 0.0
        for _ in 0..<3 {
            let t = Date()
            _ = source.snapshot()
            warmMs += Date().timeIntervalSince(t) * 1000
        }
        warmMs /= 3
        print("[smoke] LiveProcessSource 一轮采集:\(snapshot.processes.count) 个进程,冷 \(String(format: "%.1f", coldMs)) ms / 热 \(String(format: "%.1f", warmMs)) ms")

        XCTAssertGreaterThan(snapshot.processes.count, 0, "本机进程数应 > 0")
        XCTAssertLessThan(warmMs, 500, "一轮采集应远低于半秒(目标毫秒级)")

        // Live 源确定性排序:pid 升序。
        let pids = snapshot.processes.map(\.pid)
        XCTAssertEqual(pids, pids.sorted(), "Live 快照应按 pid 升序")
    }

    func testRootProcessPID1DegradesSilently() {
        // pid 1(root 属主):受限字段允许为 nil/空,但进程必须在列、采集不崩不报错。
        let snapshot = source.snapshot()

        let launchd = firstProcess(where: { $0.pid == 1 }, in: snapshot)
        XCTAssertNotNil(launchd, "pid 1(launchd)应出现在快照里")
        XCTAssertEqual(launchd?.parentPID, 0, "launchd 的父进程是 0")
        XCTAssertNotNil(launchd?.startTime, "公开的 KERN_PROC 信息应能取到启动时刻")
    }

    func testOwnProcessArgvCwdAndMetricsAreReadable() {
        let snapshot = source.snapshot()

        // 测试宿主是 Pulse.app 自身:getpid() 即菜单栏应用的进程。
        let me = firstProcess(where: { $0.pid == getpid() }, in: snapshot)
        XCTAssertNotNil(me, "自身(测试宿主 Pulse.app)进程应在快照里")
        guard let me else { return }

        XCTAssertFalse(me.argv.isEmpty, "自身 argv 应可读,实际:\(me.argv.prefix(3))")
        XCTAssertTrue(me.argv.first?.hasSuffix("Pulse") == true, "argv[0] 应是宿主可执行文件,实际:\(me.argv.first ?? "nil")")
        XCTAssertEqual(me.cwd, FileManager.default.currentDirectoryPath, "自身 cwd 应与 Foundation 口径一致")
        XCTAssertNotNil(me.startTime, "自身启动时刻应可读")
        XCTAssertGreaterThan(me.cpuTimeNanoseconds, 0, "跑着测试的进程累计 CPU 时间应 > 0")
        XCTAssertGreaterThan(me.residentMemoryBytes, 0, "常驻内存应 > 0")
        XCTAssertGreaterThan(me.physicalFootprintBytes, 0, "物理足迹应 > 0")
    }

    func testChildShellExePathArgvAndCwdAreReadable() {
        // 跨进程读:子 zsh 带标记 argv、cwd 指向 /tmp(内核按 vnode 解析,可能是 /private/tmp)。
        // 脚本末尾放内建命令:若末尾是外部命令,zsh 会 exec 替换自身,pid 就不再是 zsh 了。
        let marker = "PULSE_TICKET_02_ARGV_MARKER"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-c", "sleep 10; echo done # \(marker)"]
        child.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        XCTAssertNoThrow(try child.run(), "子 zsh 应能启动")
        defer { child.terminate() }
        Thread.sleep(forTimeInterval: 1.0)

        let snapshot = source.snapshot()
        let shell = firstProcess(where: { $0.pid == child.processIdentifier }, in: snapshot)
        XCTAssertNotNil(shell, "子 zsh(pid \(child.processIdentifier))应出现在快照里")
        guard let shell else { return }

        XCTAssertEqual(shell.parentPID, getpid(), "子进程的父应是自己")
        XCTAssertTrue(shell.executablePath?.hasSuffix("zsh") == true, "应能读到 zsh 的可执行路径,实际:\(shell.executablePath ?? "nil")")
        XCTAssertTrue(shell.argv.contains("-c"), "argv 应含 -c,实际:\(shell.argv)")
        XCTAssertTrue(shell.argv.contains { $0.contains(marker) }, "argv 应含标记参数,实际:\(shell.argv)")
        XCTAssertTrue(shell.cwd == "/private/tmp" || shell.cwd == "/tmp", "应能读到子进程 cwd,实际:\(shell.cwd ?? "nil")")
        XCTAssertNotNil(shell.startTime, "子进程启动时刻应可读")
    }
}
