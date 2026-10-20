import XCTest
@testable import Pulse

/// 主干纯内核(RoundSpine,ADR-0003 扩展点兑现):每轮心跳「并入出生登记 → 归组 →
/// 下钻」,产出全部功能模块同轮共读的一份 RoundContext。合成快照按 Sampler 的组法
/// (快照 + 对前一张的差分)喂进来,只经公开接口断言;期望值全部为独立字面量。
final class RoundSpineTests: XCTestCase {
    private let octokRoot = "/Users/x/work/octok-client"
    private let projectGroupName = "octok-client @ skill-manage-read-and-index"
    private var worktree: String { octokRoot + "/.worktrees/skill-manage-read-and-index" }
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: 测试替身

    /// 一轮心跳产出:快照 + 对前一张的差分(Sampler 同款组法);系统负载 / 内存 /
    /// 网络 / 排行与主干无关,置空。
    private func round(_ snapshot: ProcessSnapshot, after previous: ProcessSnapshot? = nil) -> SamplingUpdate {
        SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: previous, current: snapshot),
            cpu: .zero,
            memory: nil,
            network: nil,
            rankings: .empty
        )
    }

    private func makeSpine(projectRoots: [String]) -> RoundSpine {
        RoundSpine(configuration: GroupingConfiguration(projectRoots: projectRoots))
    }

    // MARK: 外部出生登记先于同轮归组

    /// 两轮采样之间来去的短命父进程 cargo(12)与它的孩子 rustc(100)的出生记录
    /// (采样从未见到 cargo;登记来自出生扫描或历史回灌)。
    private var brokenChainBirths: LineageRegistry {
        LineageRegistry().registeringBirths(in: ProcessSnapshot(processes: [
            RawProcess(
                pid: 12,
                parentPID: 11,
                executablePath: "/Users/x/.cargo/bin/cargo",
                argv: ["cargo", "test"],
                cwd: worktree
            ),
            RawProcess(
                pid: 100,
                parentPID: 12,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree
            ),
        ]))
    }

    /// 采样见到的现场:node(11)仍在、cwd 可读;rustc(100)被重挂 launchd、cwd 失效。
    private func brokenChainLive(at takenAt: Date) -> ProcessSnapshot {
        ProcessSnapshot(takenAt: takenAt, processes: [
            RawProcess(
                pid: 11,
                parentPID: 1,
                executablePath: "/usr/local/bin/node",
                argv: ["node"],
                cwd: worktree
            ),
            RawProcess(
                pid: 100,
                parentPID: 1, // cargo(12)已死:被重挂 launchd
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"]
            ),
        ])
    }

    /// rustc(100)所在组的类别。
    private func categoryOfRustc(in context: RoundContext) -> GroupCategory? {
        context.groups.first { $0.processes.contains { $0.pid == 100 } }?.category
    }

    /// 并入的外部登记(历史回灌口径,即时并入):同一轮里断链 rustc 经 cargo 的出生
    /// 记录归项目组;不并入(对照组)则落孤儿。
    func testMergedBirthsAttributeBrokenChainInTheSameRound() {
        var unmerged = makeSpine(projectRoots: [octokRoot])
        let control = unmerged.advance(round(brokenChainLive(at: base)))
        XCTAssertEqual(categoryOfRustc(in: control), .orphan, "无出生记录的断链 rustc 应落孤儿(对照组)")

        var spine = makeSpine(projectRoots: [octokRoot])
        spine.restoreBirths(brokenChainBirths)
        let context = spine.advance(round(brokenChainLive(at: base)))

        let project = context.groups.first { $0.category == .project }
        XCTAssertEqual(project?.name, projectGroupName)
        XCTAssertEqual(project?.processes.map(\.pid), [11, 100])
        XCTAssertEqual(context.lineage.entries[12]?.parentPID, 11, "本轮登记表应含并入的 cargo 出生记录")
    }

    /// 出生扫描交付的累计表先暂存,下一次 advance 归组之前并入:同一轮即生效。
    func testStagedScannerBirthsAreMergedBeforeGroupingInTheNextAdvance() {
        var spine = makeSpine(projectRoots: [octokRoot])
        spine.stageScannerBirths(brokenChainBirths)
        let context = spine.advance(round(brokenChainLive(at: base)))

        XCTAssertEqual(categoryOfRustc(in: context), .project)
        XCTAssertEqual(context.groups.first { $0.category == .project }?.processes.map(\.pid), [11, 100])
    }

    /// 扫描说 rustc(100)生在 launchd 下(Pulse 重启时它早已被重挂),回灌说它生在
    /// cargo 下:同一进程(可执行路径与 argv 一致)→ 回灌的出生记录胜,与谁先进登记表
    /// 无关——扫描先并入、回灌晚到同样改得回来(验收锚点①:重启后断链进程仍归原宿主)。
    func testRestoredBirthOfTheSameProcessWinsOverLiveRecordInEitherOrder() {
        let scannerSaysLaunchd = LineageRegistry().registeringBirths(in: ProcessSnapshot(processes: [
            RawProcess(
                pid: 100,
                parentPID: 1,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"]
            ),
        ]))

        var restoreFirst = makeSpine(projectRoots: [octokRoot])
        restoreFirst.stageScannerBirths(scannerSaysLaunchd)
        restoreFirst.restoreBirths(brokenChainBirths)
        let restoredFirstRound = restoreFirst.advance(round(brokenChainLive(at: base)))
        XCTAssertEqual(categoryOfRustc(in: restoredFirstRound), .project)

        var scannerFirst = makeSpine(projectRoots: [octokRoot])
        scannerFirst.stageScannerBirths(scannerSaysLaunchd)
        let firstRound = scannerFirst.advance(round(brokenChainLive(at: base)))
        scannerFirst.restoreBirths(brokenChainBirths)
        let laterRound = scannerFirst.advance(round(
            brokenChainLive(at: base.addingTimeInterval(5)),
            after: brokenChainLive(at: base)
        ))
        XCTAssertEqual(categoryOfRustc(in: firstRound), .orphan, "回灌落地前只有活记录")
        XCTAssertEqual(categoryOfRustc(in: laterRound), .project, "晚到的回灌改得回同一进程的记录")
        XCTAssertEqual(laterRound.lineage.entries[100]?.parentPID, 12)
    }

    /// pid 复用:回灌说 pid 100 是 cargo 下的 rustc,现场 pid 100 却是另一个程序
    /// (zsh)→ 活记录胜,zsh 不被回灌的旧记录拉进项目组;无活记录的 cargo(12)照常
    /// 取回灌记录。回灌先到、活记录后到亦然。
    func testLiveRecordWinsOverRestoredBirthWhenThePidWasReused() {
        let reused = ProcessSnapshot(takenAt: base, processes: [
            RawProcess(pid: 100, parentPID: 1, executablePath: "/bin/zsh", argv: ["-zsh"]),
        ])

        var spine = makeSpine(projectRoots: [octokRoot])
        spine.restoreBirths(brokenChainBirths)
        let context = spine.advance(round(reused))

        XCTAssertNotEqual(categoryOfRustc(in: context), .project)
        XCTAssertEqual(context.lineage.entries[100]?.executablePath, "/bin/zsh")
        XCTAssertEqual(context.lineage.entries[100]?.parentPID, 1)
        XCTAssertEqual(context.lineage.entries[12]?.parentPID, 11, "无活记录的 pid 仍取回灌记录")
    }

    /// 路径读不到(受限进程)无从判别是否同一进程:按 pid 复用论,活记录胜——
    /// 上一会话的受限守护 812 不会把旧父 pid 套到今天复用 812 的另一个受限进程上。
    func testLiveRecordWinsWhenNeitherSideHasAReadablePath() {
        let restored = LineageRegistry().registeringBirths(in: ProcessSnapshot(processes: [
            RawProcess(pid: 812, parentPID: 300),
        ]))
        var spine = makeSpine(projectRoots: [])
        spine.restoreBirths(restored)
        let context = spine.advance(round(ProcessSnapshot(takenAt: base, processes: [
            RawProcess(pid: 812, parentPID: 1),
        ])))

        XCTAssertEqual(context.lineage.entries[812]?.parentPID, 1)
    }

    // MARK: 下钻与组同轮同源

    /// 第二轮:WaifuX(50)5s 内跑了 2.5s CPU(= 50%),其子进程 node(51)本轮新生。
    /// 下钻取本轮的快照、本轮的登记表(51 已登记)与本轮差分(行 CPU 50 / 0)。
    func testDrilldownIsBuiltFromTheSameRoundAsGroups() throws {
        let app = { (cpu: UInt64) in
            RawProcess(
                pid: 50,
                parentPID: 1,
                executablePath: "/Applications/WaifuX.app/Contents/MacOS/WaifuX",
                cpuTimeNanoseconds: cpu,
                physicalFootprintBytes: 512_000_000
            )
        }
        let first = ProcessSnapshot(takenAt: base, processes: [app(0)])
        let second = ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: [
            app(2_500_000_000),
            RawProcess(
                pid: 51,
                parentPID: 50,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "helper.js"],
                physicalFootprintBytes: 40_000_000
            ),
        ])
        var spine = makeSpine(projectRoots: [])

        _ = spine.advance(round(first))
        let context = spine.advance(round(second, after: first))

        XCTAssertEqual(context.takenAt, base.addingTimeInterval(5))
        XCTAssertEqual(context.drilldown.snapshot.takenAt, base.addingTimeInterval(5))
        XCTAssertEqual(context.drilldown.lineage.entries[51]?.parentPID, 50, "本轮新生的 51 应已在下钻登记表里")
        let group = try XCTUnwrap(context.groups.first { $0.name == "WaifuX" })
        XCTAssertEqual(context.drilldown.rows(for: group).map(\.pid), [50, 51])
        XCTAssertEqual(context.drilldown.rows(for: group).map(\.cpuPercent), [50, 0])
    }

    // MARK: 项目根热更新(设置窗增删 ≤1 轮生效)

    /// 无项目根:dev 链(node ← rustc,cwd 在 worktree)沿父链上溯归宿主 Zcode;
    /// 设根后**下一次** advance 即出项目组,成员从宿主组转移过去。
    func testProjectRootChangeTakesEffectOnTheNextAdvance() {
        let tree = [
            RawProcess(
                pid: 10,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode"
            ),
            RawProcess(
                pid: 11,
                parentPID: 10,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "server.js"],
                cwd: worktree
            ),
            RawProcess(
                pid: 100,
                parentPID: 11,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree
            ),
        ]
        let first = ProcessSnapshot(takenAt: base, processes: tree)
        let second = ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: tree)
        var spine = makeSpine(projectRoots: [])

        let before = spine.advance(round(first))
        spine.setProjectRoots([octokRoot])
        let after = spine.advance(round(second, after: first))

        XCTAssertEqual(before.groups.map(\.name), ["Zcode"])
        XCTAssertEqual(before.groups.first?.processes.map(\.pid), [10, 11, 100])
        XCTAssertEqual(Set(after.groups.map(\.name)), ["Zcode", projectGroupName])
        XCTAssertEqual(after.groups.first { $0.category == .project }?.processes.map(\.pid), [11, 100])
        XCTAssertEqual(after.groups.first { $0.name == "Zcode" }?.processes.map(\.pid), [10])
    }

    // MARK: 全部组,不截弹窗 Top-N

    /// 7 个互不相干的 App,第二轮 5s 内各跑 i×0.5s CPU(= i×10%):上下文带全部 7 组
    /// (弹窗 displayLimit 是 5),组 CPU% 降序。
    func testContextCarriesEveryGroupNotJustThePopoverTopFive() {
        let apps = { (round: UInt64) in
            (1...7).map { index in
                RawProcess(
                    pid: pid_t(200 + index),
                    parentPID: 1,
                    executablePath: "/Applications/A\(index * 10).app/Contents/MacOS/A\(index * 10)",
                    cpuTimeNanoseconds: round * UInt64(index) * 500_000_000
                )
            }
        }
        let first = ProcessSnapshot(takenAt: base, processes: apps(0))
        let second = ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: apps(1))
        var spine = makeSpine(projectRoots: [])

        _ = spine.advance(round(first))
        let context = spine.advance(round(second, after: first))

        XCTAssertEqual(context.groups.map(\.name), ["A70", "A60", "A50", "A40", "A30", "A20", "A10"])
        XCTAssertEqual(context.groups.map(\.cpuPercent), [70, 60, 50, 40, 30, 20, 10])
    }
}
