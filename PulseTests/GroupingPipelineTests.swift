import XCTest
@testable import Pulse
@testable import PulseCore

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
        pipeline: inout GroupingPipeline
    ) -> (groups: [ProcessGroup], snapshot: ProcessSnapshot) {
        let snapshot = source.snapshot()
        let diff = CPUDiffer.diff(previous: previous, current: snapshot)
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

    // MARK: 跨轮归属缓存(arch-review-2026-10-18/04)

    /// 同一 pid 下一轮换了身份(被复用 / exec 了别的程序):不能沿用上一轮缓存的归属。
    func testSamePIDWithANewIdentityIsReattributed() {
        let zed = RawProcess(pid: 50, parentPID: 1, executablePath: "/Applications/Zed.app/Contents/MacOS/zed")
        let xcode = RawProcess(pid: 50, parentPID: 1, executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode")
        var pipeline = GroupingPipeline()

        _ = pipeline.update(snapshot: ProcessSnapshot(takenAt: base, processes: [zed]), processCPU: [])
        let second = pipeline.update(
            snapshot: ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: [xcode]),
            processCPU: []
        )

        XCTAssertEqual(second.map(\.id), [.app(bundlePath: "/Applications/Xcode.app")])
    }

    /// 缓存命中的轮次与从头计算结果一致:同一棵进程树连续多轮,组完全相同。
    func testCachedRoundsMatchAFreshComputation() {
        let tree = gateTree(zcodeCPU: 0, nodeCPU: 0, cargoCPU: 0, rustcCPU: 0, windowServerCPU: 0)
        let configuration = GroupingConfiguration(projectRoots: [octokRoot])
        var cached = GroupingPipeline(configuration: configuration)
        for offset in 0..<3 {
            _ = cached.update(
                snapshot: ProcessSnapshot(takenAt: base.addingTimeInterval(Double(offset) * 5), processes: tree),
                processCPU: []
            )
        }
        var fresh = GroupingPipeline(configuration: configuration)
        _ = fresh.update(snapshot: ProcessSnapshot(takenAt: base, processes: tree), processCPU: [])

        XCTAssertEqual(cached.allGroups.map(\.id), fresh.allGroups.map(\.id))
        XCTAssertEqual(cached.allGroups.map { $0.processes.map(\.pid) }, fresh.allGroups.map { $0.processes.map(\.pid) })
    }

    // MARK: 项目根热更新(工单 07:设置窗增删 ≤1 轮采样生效)

    /// 项目根为空 → dev 门禁链走 03 降级路径(父链上溯归宿主 Zcode);
    /// 设根后**下一轮**即出"项目名 @ worktree"组——成员从宿主组转移到项目组。
    func testSettingProjectRootsRegroupsOnNextSweep() {
        let tree = { self.gateTree(
            zcodeCPU: 0, nodeCPU: 0, cargoCPU: 0, rustcCPU: 0, windowServerCPU: 0
        ) }
        let source = SyntheticProcessSource(snapshots: [
            ProcessSnapshot(takenAt: base, processes: tree()),
            ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: tree()),
        ])
        var pipeline = GroupingPipeline(configuration: GroupingConfiguration(projectRoots: []))

        // 首轮:无项目根 → 无项目组;dev 链沿父链上溯归宿主(散落的 rustc/node
        // 表现为"App 归属",spec 工单 07 的起点状态)。
        let (firstGroups, firstSnapshot) = sweep(source, previous: nil, pipeline: &pipeline)
        XCTAssertEqual(firstGroups.count, 2)
        XCTAssertFalse(firstGroups.contains { $0.category == .project })
        let firstHost = firstGroups.first { $0.name == "Zcode" }
        XCTAssertEqual(firstHost?.processes.count, 8) // 宿主 + node + cargo + rustc×5

        // 设置窗添加项目根(工单 07)。
        pipeline.setProjectRoots([octokRoot])

        // 下一轮(≤1 轮)即以新根归组:项目组出现,宿主组只剩宿主自己。
        let (secondGroups, _) = sweep(source, previous: firstSnapshot, pipeline: &pipeline)
        XCTAssertTrue(secondGroups.contains { $0.name == "octok-client @ \(worktreeName)" })
        let project = secondGroups.first { $0.category == .project }
        XCTAssertEqual(project?.processes.count, 7) // node + cargo + rustc×5
        XCTAssertEqual(secondGroups.first { $0.name == "Zcode" }?.processes.count, 1)
    }

    /// 删除全部项目根 → 下一轮项目组消失,dev 链降级回 03 路径(宿主组),不报错。
    func testRemovingProjectRootsDegradesOnNextSweep() {
        let tree = { self.gateTree(
            zcodeCPU: 0, nodeCPU: 0, cargoCPU: 0, rustcCPU: 0, windowServerCPU: 0
        ) }
        let source = SyntheticProcessSource(snapshots: [
            ProcessSnapshot(takenAt: base, processes: tree()),
            ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: tree()),
        ])
        var pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(projectRoots: [octokRoot])
        )

        // 首轮:有根 → 项目组在。
        let (firstGroups, firstSnapshot) = sweep(source, previous: nil, pipeline: &pipeline)
        XCTAssertTrue(firstGroups.contains { $0.name == "octok-client @ \(worktreeName)" })

        // 设置窗清空项目根(工单 07)。
        pipeline.setProjectRoots([])

        // 下一轮(≤1 轮):项目组消失,成员全部回到父链上溯的宿主组。
        let (secondGroups, _) = sweep(source, previous: firstSnapshot, pipeline: &pipeline)
        XCTAssertFalse(secondGroups.contains { $0.category == .project })
        XCTAssertEqual(secondGroups.count, 2) // Zcode + 系统
        XCTAssertEqual(secondGroups.first { $0.name == "Zcode" }?.processes.count, 8)
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

    // MARK: 出生扫描并入(评审 S1:独立 2s 扫描 ↔ 采样轮兜底)

    /// 采样间隙出生又退场的短命父进程(cargo):只有出生扫描捕捉到——
    /// mergeBirths 并入后,下一轮采样里被重挂 launchd 的子进程仍归项目组;
    /// 不并入(对照组)则归孤儿——正是扫描存在的意义。
    func testMergedScannerBirthsCoverParentsThatDiedBetweenSamples() {
        // 出生扫描捕捉到的快照:rustc 出生时父是 cargo,cargo 的 cwd 在 worktree。
        // (采样从未见到这两个进程——它们在两轮采样之间来去。)
        let scannerBirths = LineageRegistry().registeringBirths(
            in: ProcessSnapshot(processes: [
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
            ])
        )
        // 采样见到的是:node(仍在,cwd 可读)与被重挂 launchd 的 rustc(cwd 失效)。
        let live = ProcessSnapshot(takenAt: base, processes: [
            RawProcess(
                pid: 11,
                parentPID: 1,
                executablePath: "/usr/local/bin/node",
                argv: ["node"],
                cwd: worktree(worktreeName)
            ),
            RawProcess(
                pid: 100,
                parentPID: 1, // cargo(12)已死:被重挂 launchd
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"]
            ),
        ])

        // 对照组:不并入扫描登记 → rustc 断链无记录,落孤儿。
        var withoutMerge = GroupingPipeline(
            configuration: GroupingConfiguration(projectRoots: [octokRoot])
        )
        let unmergedGroups = withoutMerge.update(snapshot: live, processCPU: [])
        XCTAssertEqual(
            unmergedGroups.first { $0.processes.contains { $0.pid == 100 } }?.category,
            .orphan,
            "无出生记录的断链 rustc 应落孤儿(对照组)"
        )

        // 实验组:并入扫描登记 → 同一快照下 rustc 经 cargo 的出生记录归项目组。
        var withMerge = GroupingPipeline(
            configuration: GroupingConfiguration(projectRoots: [octokRoot])
        )
        withMerge.mergeBirths(scannerBirths)
        let mergedGroups = withMerge.update(snapshot: live, processCPU: [])

        let project = mergedGroups.first { $0.category == .project }
        XCTAssertNotNil(project, "扫描登记的 cargo 出生记录应让断链 rustc 归项目组")
        XCTAssertEqual(project?.name, "octok-client @ \(worktreeName)")
        XCTAssertEqual(project?.processes.map(\.pid), [11, 100])
    }
}
