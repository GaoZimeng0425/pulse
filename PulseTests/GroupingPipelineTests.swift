import XCTest
@testable import Pulse

/// 采样 → 组卡呈现的粘合逻辑(工单 05):合成快照序列按采样循环的组法
/// (source → CPUDiffer → pipeline.update)驱动,断言 Top 组的外部行为。
/// 期望值全部为独立字面量,不经实现同源计算。
final class GroupingPipelineTests: XCTestCase {
    private let octokRoot = "/Users/x/work/octok-client"
    private let worktreeName = "skill-manage-read-and-index"

    private func worktree(_ name: String) -> String {
        octokRoot + "/.worktrees/" + name
    }

    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: 测试替身:按采样循环的组法驱动一轮

    /// 一轮"采样":取快照 → 差分 → 推进管线。返回该轮 Top 组与快照(供下轮做前值)。
    private func sweep(
        _ source: SyntheticProcessSource,
        previous: ProcessSnapshot?,
        pipeline: inout GroupingPipeline,
        logicalCoreCount: Int = 4
    ) -> (groups: [ProcessGroup], snapshot: ProcessSnapshot) {
        let snapshot = source.snapshot()
        let diff = CPUDiffer.diff(
            previous: previous,
            current: snapshot,
            logicalCoreCount: logicalCoreCount
        )
        let groups = pipeline.update(snapshot: snapshot, processCPU: diff.processCPU)
        return (groups, snapshot)
    }

    // MARK: 夹具

    /// 门禁树:Zcode 宿主 + node ← cargo ← rustc×5,cwd 全在 octok-client 的 worktree;
    /// 外加 WindowServer(路径在 .app bundle 里但属系统组)。
    /// cpuTimeNanoseconds 是自开机累计 CPU(差分口径),首采全 0。
    private func gateTree(
        zcodeCPU: UInt64,
        nodeCPU: UInt64,
        cargoCPU: UInt64,
        rustcCPU: UInt64,
        windowServerCPU: UInt64
    ) -> [RawProcess] {
        var processes: [RawProcess] = [
            RawProcess(
                pid: 10,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode",
                cpuTimeNanoseconds: zcodeCPU,
                physicalFootprintBytes: 300_000_000
            ),
            RawProcess(
                pid: 11,
                parentPID: 10,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "server.js"],
                cwd: worktree(worktreeName),
                cpuTimeNanoseconds: nodeCPU,
                physicalFootprintBytes: 80_000_000
            ),
            RawProcess(
                pid: 12,
                parentPID: 11,
                executablePath: "/Users/x/.cargo/bin/cargo",
                argv: ["cargo", "test"],
                cwd: worktree(worktreeName),
                cpuTimeNanoseconds: cargoCPU,
                physicalFootprintBytes: 50_000_000
            ),
        ]
        for index in 0..<5 {
            processes.append(
                RawProcess(
                    pid: pid_t(100 + index),
                    parentPID: 12,
                    executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                    argv: ["rustc", "--crate-name", "octok"],
                    cwd: worktree(worktreeName),
                    cpuTimeNanoseconds: rustcCPU,
                    physicalFootprintBytes: 200_000_000
                )
            )
        }
        processes.append(
            RawProcess(
                pid: 128,
                parentPID: 1,
                executablePath:
                    "/System/Library/CoreServices/WindowServer.app/Contents/MacOS/WindowServer",
                cpuTimeNanoseconds: windowServerCPU,
                physicalFootprintBytes: 90_000_000
            )
        )
        return processes
    }

    // MARK: 门禁树全管线(验收锚点:octok 400%+ 级别读数)

    /// 两轮采样:首采全为新生儿(CPU nil → 组 0%);第二轮差分出真 CPU,
    /// 项目组 465%(5+10+90×5)居首,系统组参榜,App 宿主殿后。
    func testGateTreeFlowsThroughDifferToRankedTopGroups() {
        let source = SyntheticProcessSource(snapshots: [
            ProcessSnapshot(
                takenAt: base,
                processes: gateTree(
                    zcodeCPU: 0, nodeCPU: 0, cargoCPU: 0, rustcCPU: 0, windowServerCPU: 0
                )
            ),
            ProcessSnapshot(
                takenAt: base.addingTimeInterval(5),
                processes: gateTree(
                    zcodeCPU: 150_000_000, // 5s 墙钟烧 0.15s → 3%
                    nodeCPU: 250_000_000, // → 5%
                    cargoCPU: 500_000_000, // → 10%
                    rustcCPU: 4_500_000_000, // 每个 → 90%
                    windowServerCPU: 1_000_000_000 // → 20%
                )
            ),
        ])
        var pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(projectRoots: [octokRoot])
        )

        // 首采:所有进程 CPU 无前值(nil),组 CPU% 按 0 计,组照常归出。
        let (firstGroups, firstSnapshot) = sweep(source, previous: nil, pipeline: &pipeline)
        XCTAssertEqual(firstGroups.count, 3)
        XCTAssertTrue(firstGroups.allSatisfy { $0.cpuPercent == 0 })
        XCTAssertTrue(firstGroups.contains { $0.name == "octok-client @ \(worktreeName)" })

        // 第二轮:真差分,组 CPU% 降序——项目 465 / 系统 20 / Zcode 3。
        let (secondGroups, _) = sweep(source, previous: firstSnapshot, pipeline: &pipeline)
        XCTAssertEqual(secondGroups.count, 3)
        XCTAssertEqual(
            secondGroups.map(\.name),
            ["octok-client @ \(worktreeName)", "系统", "Zcode"]
        )
        XCTAssertEqual(secondGroups.map(\.category), [.project, .system, .app])

        let project = secondGroups[0]
        XCTAssertEqual(project.cpuPercent, 465, accuracy: 0.0001)
        // 验收锚点的读数形态:400%+ 级别,单核累加口径合法。
        XCTAssertEqual(PulseFormat.cpuPercent(project.cpuPercent), "465%")
        XCTAssertEqual(project.processes.count, 7) // node + cargo + rustc×5
        XCTAssertEqual(project.memoryBytes, 1_130_000_000) // 80M + 50M + 5×200M

        XCTAssertEqual(secondGroups[1].cpuPercent, 20, accuracy: 0.0001)
        XCTAssertEqual(secondGroups[2].cpuPercent, 3, accuracy: 0.0001)
        XCTAssertEqual(secondGroups[2].bundlePath, "/Applications/Zcode.app")
    }

    // MARK: Top-N 截取与排序

    /// 7 个互不相干的 App 组、CPU 各异:只保留 Top-5,严格按组 CPU% 降序。
    func testTopGroupsAreLimitedToFiveByDescendingCPU() {
        let apps = (1...7).map { index in
            RawProcess(
                pid: pid_t(200 + index),
                parentPID: 1,
                executablePath: "/Applications/A\(index * 10).app/Contents/MacOS/A\(index * 10)"
            )
        }
        let processCPU = (1...7).map { index in
            ProcessCPU(pid: pid_t(200 + index), cpuPercent: Double(index * 10))
        }
        var pipeline = GroupingPipeline()

        let groups = pipeline.update(
            snapshot: ProcessSnapshot(takenAt: base, processes: apps),
            processCPU: processCPU
        )

        XCTAssertEqual(groups.count, 5)
        XCTAssertEqual(groups.map(\.name), ["A70", "A60", "A50", "A40", "A30"])
        XCTAssertEqual(groups.map(\.cpuPercent), [70, 60, 50, 40, 30])
        XCTAssertFalse(groups.contains { $0.name == "A20" || $0.name == "A10" })
    }

    // MARK: 退化情形

    /// 极端空载(快照里一个进程都没有):无组可显示,不坏 UI、不崩。
    func testEmptySnapshotProducesNoGroups() {
        var pipeline = GroupingPipeline()
        let empty = ProcessSnapshot(takenAt: base, processes: [])

        let first = pipeline.update(snapshot: empty, processCPU: [])
        let second = pipeline.update(snapshot: empty, processCPU: [])

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    /// 新出生进程差分为 nil(无前值):显式按 0 计,组照常成立。
    func testNewbornProcessWithNilCPUCountsAsZero() {
        var pipeline = GroupingPipeline()
        let snapshot = ProcessSnapshot(takenAt: base, processes: [
            RawProcess(
                pid: 50,
                parentPID: 1,
                executablePath: "/Applications/WaifuX.app/Contents/MacOS/WaifuX",
                physicalFootprintBytes: 512_000_000
            ),
        ])

        let groups = pipeline.update(
            snapshot: snapshot,
            processCPU: [ProcessCPU(pid: 50, cpuPercent: nil)]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "WaifuX")
        XCTAssertEqual(groups[0].processes.count, 1)
        XCTAssertEqual(groups[0].cpuPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(groups[0].memoryBytes, 512_000_000)
    }

    // MARK: 出生登记跨轮持续

    /// 中间父进程(cargo/node)已死、rustc 被重挂 launchd 且 cwd 不可读:
    /// 首轮登记的出生父链让第二轮仍归"项目 @ worktree"(管线逐轮登记出生的证明)。
    func testBirthRegistrationPersistsAcrossSweepsForBrokenChain() {
        let source = SyntheticProcessSource(snapshots: [
            ProcessSnapshot(takenAt: base, processes: [
                RawProcess(
                    pid: 10,
                    parentPID: 1,
                    executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode"
                ),
                RawProcess(
                    pid: 11,
                    parentPID: 10,
                    executablePath: "/usr/local/bin/node",
                    argv: ["node"],
                    cwd: worktree(worktreeName)
                ),
                RawProcess(
                    pid: 12,
                    parentPID: 11,
                    executablePath: "/Users/x/.cargo/bin/cargo",
                    argv: ["cargo", "test"],
                    cwd: worktree(worktreeName)
                ),
                RawProcess(
                    pid: 100,
                    parentPID: 12,
                    executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                    argv: ["rustc", "--crate-name", "octok"],
                    cwd: worktree(worktreeName)
                ),
            ]),
            // 第二轮:node(11)/cargo(12) 已死,rustc 被重挂 launchd(不在快照)且 cwd 失效。
            ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: [
                RawProcess(
                    pid: 10,
                    parentPID: 1,
                    executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode"
                ),
                RawProcess(
                    pid: 100,
                    parentPID: 1,
                    executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                    argv: ["rustc", "--crate-name", "octok"]
                ),
            ]),
        ])
        var pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(projectRoots: [octokRoot])
        )

        let (_, firstSnapshot) = sweep(source, previous: nil, pipeline: &pipeline)
        let (secondGroups, _) = sweep(source, previous: firstSnapshot, pipeline: &pipeline)

        let project = secondGroups.first { $0.category == .project }
        XCTAssertNotNil(project, "出生登记回查应让断链 rustc 仍归项目组")
        XCTAssertEqual(project?.name, "octok-client @ \(worktreeName)")
        XCTAssertEqual(project?.processes.map(\.pid), [100])
    }
}
