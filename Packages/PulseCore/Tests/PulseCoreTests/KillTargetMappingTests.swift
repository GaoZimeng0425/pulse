import XCTest
@testable import PulseCore

/// 接缝:处置目标映射(工单 08)——下钻数据(RawProcess / ProcessGroup)
/// → KillTarget 清单。名称口径与下钻行一致(可执行 basename → argv[0] → "pid N"),
/// 保证确认对话框点名的对象与用户看到的行是同一个。
final class KillTargetMappingTests: XCTestCase {
    func testProcessKillTargetUsesExecutableBasename() {
        let process = RawProcess(
            pid: 100,
            parentPID: 11,
            executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
            argv: ["rustc", "--crate-name", "octok"]
        )

        XCTAssertEqual(process.killTarget, KillTarget(pid: 100, name: "rustc"))
    }

    /// 路径受限、argv[0] 可得:名字退 argv[0] basename(与下钻行同口径)。
    func testProcessKillTargetFallsBackToArgvThenPID() {
        let argvOnly = RawProcess(pid: 30, parentPID: 1, argv: ["vitest", "run"])
        let neither = RawProcess(pid: 31, parentPID: 1)

        XCTAssertEqual(argvOnly.killTarget, KillTarget(pid: 30, name: "vitest"))
        XCTAssertEqual(neither.killTarget, KillTarget(pid: 31, name: "pid 31"))
    }

    /// 整组:清单 = 组内全部成员,一进程一目标(引擎契约:成员来自最近一轮采样)。
    func testGroupKillTargetsCoverEveryMember() {
        let members = [
            RawProcess(pid: 100, parentPID: 11, executablePath: "/usr/local/bin/node", argv: ["node"]),
            RawProcess(pid: 101, parentPID: 100, executablePath: "/usr/bin/sleep", argv: ["sleep", "300"]),
        ]
        let group = ProcessGroup(
            id: .project(root: "octok", worktreeName: nil), name: "octok",
            processes: members, cpuPercent: 50, memoryBytes: 0
        )

        XCTAssertEqual(
            Set(group.killTargets),
            [KillTarget(pid: 100, name: "node"), KillTarget(pid: 101, name: "sleep")]
        )
    }
}
