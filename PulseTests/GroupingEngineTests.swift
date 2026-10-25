@testable import Pulse
@testable import PulseCore
import XCTest

/// 归组引擎(工单 03):三层归属 + 兜底三分类,全部以合成进程树为夹具(spec 测试决策)。
/// 断言只看外部行为——"这棵树归出这些组";期望值全部为独立字面量,不经实现同源计算。
final class GroupingEngineTests: XCTestCase {
    private let octokRoot = "/Users/x/work/octok-client"

    private func worktree(_ name: String) -> String {
        octokRoot + "/.worktrees/" + name
    }

    /// 工单 03 验收锚点:rustc×4 ← cargo ← node ← Zcode,cwd 全在 octok-client 的 worktree 里。
    private func octokGateTree() -> [RawProcess] {
        [
            RawProcess(
                pid: 10,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode",
                physicalFootprintBytes: 300_000_000
            ),
            RawProcess(
                pid: 11,
                parentPID: 10,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "server.js"],
                cwd: worktree("skill-manage-read-and-index"),
                physicalFootprintBytes: 80_000_000
            ),
            RawProcess(
                pid: 12,
                parentPID: 11,
                executablePath: "/Users/x/.cargo/bin/cargo",
                argv: ["cargo", "test"],
                cwd: worktree("skill-manage-read-and-index"),
                physicalFootprintBytes: 50_000_000
            ),
            RawProcess(
                pid: 100,
                parentPID: 12,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree("skill-manage-read-and-index"),
                physicalFootprintBytes: 200_000_000
            ),
            RawProcess(
                pid: 101,
                parentPID: 12,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree("skill-manage-read-and-index"),
                physicalFootprintBytes: 200_000_000
            ),
            RawProcess(
                pid: 102,
                parentPID: 12,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree("skill-manage-read-and-index"),
                physicalFootprintBytes: 200_000_000
            ),
            RawProcess(
                pid: 103,
                parentPID: 12,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree("skill-manage-read-and-index"),
                physicalFootprintBytes: 200_000_000
            ),
        ]
    }

    /// 各进程 CPU%(工单 04 差分器的输出,按 pid 传入引擎)。
    private func octokGateCPU() -> [pid_t: Double] {
        [10: 3, 11: 5, 12: 10, 100: 90, 101: 92, 102: 88, 103: 91]
    }

    // MARK: - 组身份类型(工单 00)

    /// 种类 → 类别 1:1:展示口径(图例/图标)继续吃 GroupCategory,不另设第二份映射。
    func testGroupIdentityMapsEachCaseToItsCategory() {
        XCTAssertEqual(GroupIdentity.app(bundlePath: "/Applications/X.app").category, .app)
        XCTAssertEqual(GroupIdentity.project(root: "/r", worktreeName: nil).category, .project)
        XCTAssertEqual(GroupIdentity.system.category, .system)
        XCTAssertEqual(GroupIdentity.backgroundService.category, .backgroundService)
        XCTAssertEqual(GroupIdentity.orphan.category, .orphan)
    }

    /// 规范字符串与 P0 前缀约定的组 id 逐字节一致:升级前后同组的稳定键不变,
    /// 排序与(未来的)持久化键因此零漂移。期望值为独立字面量。
    func testStableKeyReproducesLegacyPrefixedIDs() {
        XCTAssertEqual(
            GroupIdentity.app(bundlePath: "/Applications/Zcode.app").stableKey,
            "bundle:/Applications/Zcode.app"
        )
        XCTAssertEqual(
            GroupIdentity.project(root: "/Users/x/work/octok-client", worktreeName: "wt").stableKey,
            "project:/Users/x/work/octok-client@wt"
        )
        XCTAssertEqual(
            GroupIdentity.project(root: "/Users/x/work/octok-client", worktreeName: nil).stableKey,
            "project:/Users/x/work/octok-client"
        )
        XCTAssertEqual(GroupIdentity.system.stableKey, "system")
        XCTAssertEqual(GroupIdentity.backgroundService.stableKey, "background-service")
        XCTAssertEqual(GroupIdentity.orphan.stableKey, "orphan")
    }

    /// Comparable = stableKey 字典序:与升级前纯字符串 id 的次键排序逐位一致
    /// (background-service < bundle: < orphan < project: < system),同值并列时
    /// 榜单次序零行为变化。
    func testComparableFollowsLegacyStringOrder() {
        let ordered: [GroupIdentity] = [
            .backgroundService,
            .app(bundlePath: "/Applications/A.app"),
            .orphan,
            .project(root: "/r", worktreeName: nil),
            .system,
        ]
        XCTAssertEqual(ordered.sorted(), ordered)

        // 同种类内部按原始值排序(旧的 bundle:/project: 字典序)。
        let sameKind: [GroupIdentity] = [
            .app(bundlePath: "/Applications/B.app"),
            .app(bundlePath: "/Applications/A.app"),
        ]
        XCTAssertEqual(
            sameKind.sorted(),
            [.app(bundlePath: "/Applications/A.app"), .app(bundlePath: "/Applications/B.app")]
        )
    }

    /// 相等性按种类 + 原始值判定:平行 worktree 是不同身份(旧约定里
    /// "project:<root>@alpha" ≠ "project:<root>@beta" 的口径,由类型承载)。
    func testEqualityDistinguishesWorktreesAndPayloads() {
        XCTAssertEqual(
            GroupIdentity.project(root: "/r", worktreeName: "alpha"),
            GroupIdentity.project(root: "/r", worktreeName: "alpha")
        )
        XCTAssertNotEqual(
            GroupIdentity.project(root: "/r", worktreeName: "alpha"),
            GroupIdentity.project(root: "/r", worktreeName: "beta")
        )
        XCTAssertNotEqual(
            GroupIdentity.project(root: "/r", worktreeName: nil),
            GroupIdentity.project(root: "/r", worktreeName: "alpha")
        )
        XCTAssertNotEqual(GroupIdentity.system, GroupIdentity.orphan)
    }

    // MARK: - 三层归属

    /// 验收锚点:整棵门禁链归"项目 @ worktree",组 CPU% 为各进程之和(超过 100% 合法)。
    func testOctokGateTreeGroupsIntoWorktreeProjectWithSummedCPU() {
        let snapshot = ProcessSnapshot(processes: octokGateTree())
        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: octokGateCPU()
        )

        XCTAssertEqual(groups.count, 2)
        let project = groups[0]
        XCTAssertEqual(project.name, "octok-client @ skill-manage-read-and-index")
        XCTAssertEqual(project.category, .project)
        XCTAssertEqual(
            project.id,
            GroupIdentity.project(root: octokRoot, worktreeName: "skill-manage-read-and-index")
        )
        XCTAssertEqual(project.processes.count, 6)
        // 组 CPU% = 5 + 10 + 90 + 92 + 88 + 91:单核 100% 累加,超过 100% 合法
        XCTAssertEqual(project.cpuPercent, 376, accuracy: 0.0001)
        XCTAssertEqual(project.memoryBytes, 930_000_000)
        // 组内进程按 CPU% 降序:92% 的 rustc(101)排最前
        XCTAssertEqual(project.processes.first?.pid, 101)

        // 拉起链顶端的 Zcode 单独成 App 组,组列表按组 CPU% 降序排在项目组之后
        let app = groups[1]
        XCTAssertEqual(app.name, "Zcode")
        XCTAssertEqual(app.category, .app)
        XCTAssertEqual(app.bundlePath, "/Applications/Zcode.app")
        XCTAssertEqual(app.processes.map(\.pid), [10])
        XCTAssertEqual(app.cpuPercent, 3, accuracy: 0.0001)
    }

    /// 嵌套 Helper.app(Renderer / GPU)与路径受限的 Helper 全部跟随宿主,应用仅一组。
    func testChromeHelpersAllFollowHostBundleIntoOneGroup() {
        let helperNested =
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 200,
                parentPID: 1,
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                physicalFootprintBytes: 400_000_000
            ),
            RawProcess(
                pid: 201,
                parentPID: 200,
                executablePath: helperNested,
                argv: ["Google Chrome Helper", "--type=renderer"],
                physicalFootprintBytes: 900_000_000
            ),
            RawProcess(
                pid: 202,
                parentPID: 200,
                executablePath: helperNested,
                argv: ["Google Chrome Helper", "--type=gpu-process"],
                physicalFootprintBytes: 150_000_000
            ),
            // 路径受限(proc_pidpath 失败)的 Helper:靠父链上溯跟随宿主
            RawProcess(
                pid: 203,
                parentPID: 200,
                argv: ["Google Chrome Helper", "--type=utility"],
                physicalFootprintBytes: 50_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            cpuPercentByPID: [200: 15, 201: 120, 202: 30, 203: 8]
        )

        XCTAssertEqual(groups.count, 1)
        let chrome = groups[0]
        XCTAssertEqual(chrome.name, "Google Chrome")
        XCTAssertEqual(chrome.category, .app)
        XCTAssertEqual(chrome.bundlePath, "/Applications/Google Chrome.app")
        XCTAssertEqual(chrome.processes.count, 4)
        // 15 + 120 + 30 + 8
        XCTAssertEqual(chrome.cpuPercent, 173, accuracy: 0.0001)
        XCTAssertEqual(chrome.memoryBytes, 1_500_000_000)
    }

    /// 活链优先:进程被重挂到另一个活着的 App 下时,当前父链赢过出生登记。
    func testLiveChainTakesPrecedenceOverBirthRegistry() {
        let born = ProcessSnapshot(processes: [
            RawProcess(pid: 20, parentPID: 1, executablePath: "/Applications/Aaa.app/Contents/MacOS/aaa"),
            RawProcess(pid: 21, parentPID: 20, executablePath: "/usr/local/bin/node", argv: ["node"]),
        ])
        let registry = LineageRegistry().registeringBirths(in: born)

        // 21 被重挂到另一个活着的 App 下:活链(Bbb)必须赢过出生登记(Aaa)
        let after = ProcessSnapshot(processes: [
            RawProcess(pid: 30, parentPID: 1, executablePath: "/Applications/Bbb.app/Contents/MacOS/bbb"),
            RawProcess(pid: 21, parentPID: 30, executablePath: "/usr/local/bin/node", argv: ["node"]),
        ])

        let groups = GroupingEngine.groups(from: after, lineage: registry)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Bbb")
        XCTAssertEqual(Set(groups[0].processes.map(\.pid)), [21, 30])
    }

    /// 无项目根配置:dev 进程的项目归因整体失效,门禁链沿父链上溯跟随宿主 App,正常降级。
    func testEmptyProjectRootsDegradeDevChainToHostAppBundle() {
        let groups = GroupingEngine.groups(
            from: ProcessSnapshot(processes: octokGateTree()),
            configuration: GroupingConfiguration(), // 无项目根
            cpuPercentByPID: octokGateCPU()
        )

        XCTAssertEqual(groups.count, 1)
        let host = groups[0]
        XCTAssertEqual(host.name, "Zcode")
        XCTAssertEqual(host.category, .app)
        // node / cargo / rustc×4 全部经父链上溯跟随宿主
        XCTAssertEqual(host.processes.count, 7)
        // 3 + 5 + 10 + 90 + 92 + 88 + 91
        XCTAssertEqual(host.cpuPercent, 379, accuracy: 0.0001)
    }

    /// cwd 不可读(PROC_PIDVNODEPATHINFO 受限)时,argv 中的路径次之兜底项目归因。
    func testProjectAttributionViaArgvPathWhenCwdUnavailable() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 21,
                parentPID: 1,
                executablePath: "/usr/local/bin/node",
                argv: ["node", octokRoot + "/server.js"],
                physicalFootprintBytes: 120_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [21: 30]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].category, .project)
        // 命中的不是 worktree 目录:显示纯项目名
        XCTAssertEqual(groups[0].name, "octok-client")
        XCTAssertEqual(groups[0].processes.map(\.pid), [21])
    }

    /// project-visibility/02(2026-10-25 拍板 A 无条件翻):可执行在 .app 容器内、
    /// cwd 命中项目根的进程归项目组——宿主 Helper、Xcode 工具链编译器随项目记账。
    func testBundledProcessWithCwdInsideRootAttributesToProject() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 21,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode Helper",
                argv: ["Zcode Helper"],
                cwd: worktree("alpha"),
                physicalFootprintBytes: 80_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [21: 12]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].category, .project)
        XCTAssertEqual(groups[0].name, "octok-client @ alpha")
        XCTAssertEqual(groups[0].processes.map(\.pid), [21])
    }

    /// 防翻过头(对调后的兜底位):容器进程 cwd / argv 都不命中项目根时仍归宿主 App。
    func testBundledProcessWithoutProjectMatchStillAttributesToHostApp() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 21,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode Helper",
                argv: ["Zcode Helper"],
                cwd: "/Users/x",
                physicalFootprintBytes: 80_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [21: 12]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].category, .app)
        XCTAssertEqual(groups[0].name, "Zcode")
        XCTAssertEqual(groups[0].processes.map(\.pid), [21])
    }

    /// 容器进程(放宽口径的 Xcode 工具链路径)cwd 未命中、argv 路径命中项目根:
    /// 同样归项目——项目层内 argv 次级通道压过容器判定。
    func testBundledProcessWithArgvPathInsideRootAttributesToProject() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 21,
                parentPID: 1,
                executablePath:
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                argv: ["swift-frontend", "-module-name", "octok", octokRoot + "/Sources/main.swift"],
                cwd: "/tmp",
                physicalFootprintBytes: 200_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [21: 90]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].category, .project)
        XCTAssertEqual(groups[0].name, "octok-client")
        XCTAssertEqual(groups[0].processes.map(\.pid), [21])
    }

    /// 并行 worktree 各自成组、互不混淆(用户故事 10)。
    func testParallelWorktreesFormDistinctGroups() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 100,
                parentPID: 1,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc"],
                cwd: worktree("alpha"),
                physicalFootprintBytes: 100_000_000
            ),
            RawProcess(
                pid: 101,
                parentPID: 1,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc"],
                cwd: worktree("beta"),
                physicalFootprintBytes: 100_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [100: 80, 101: 70]
        )

        XCTAssertEqual(groups.count, 2)
        // 按组 CPU% 降序:alpha 在前
        XCTAssertEqual(groups.map(\.name), ["octok-client @ alpha", "octok-client @ beta"])
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }

    /// 多个项目根同时命中时取最具体的(最长)根。
    func testLongestProjectRootWins() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 100,
                parentPID: 1,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc"],
                cwd: worktree("gamma"),
                physicalFootprintBytes: 100_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [
                "/Users/x/work", // 更宽泛的根
                octokRoot,
            ]),
            cpuPercentByPID: [100: 50]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "octok-client @ gamma")
    }

    // MARK: - 出生登记

    /// 中间父进程(cargo)已死、rustc 被重挂到 launchd 且 cwd 不可读:出生登记回查仍归对。
    func testDeadMidChainParentStillAttributesViaBirthRegistry() {
        let fullTree = octokGateTree()
        let registered = LineageRegistry().registeringBirths(
            in: ProcessSnapshot(processes: fullTree)
        )

        // cargo(12) 已死,rustc(100) 被重挂到 launchd 且 cwd 已不可读——活链断了
        let after = ProcessSnapshot(processes: [
            fullTree[0], // Zcode(10)
            RawProcess(
                pid: 100,
                parentPID: 1,
                executablePath: fullTree[3].executablePath,
                argv: ["rustc", "--crate-name", "octok"],
                physicalFootprintBytes: 200_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: after,
            lineage: registered,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [10: 3, 100: 90]
        )

        // 出生登记回查:rustc 出生时的父链经 cargo(出生时 cwd 在 worktree)→ 项目组
        let project = groups.first { $0.category == .project }
        XCTAssertNotNil(project)
        XCTAssertEqual(project?.name, "octok-client @ skill-manage-read-and-index")
        XCTAssertEqual(project?.processes.map(\.pid), [100])
        XCTAssertEqual(project?.cpuPercent ?? 0, 90, accuracy: 0.0001)
    }

    /// 登记是纯函数:返回新表,不改动原表。
    func testRegisteringBirthsReturnsNewRegistryWithoutMutatingOriginal() {
        let original = LineageRegistry()
        let snapshot = ProcessSnapshot(processes: octokGateTree())

        let updated = original.registeringBirths(in: snapshot)

        XCTAssertNotEqual(updated, original)
        XCTAssertEqual(original, LineageRegistry())
        XCTAssertEqual(updated.entries.count, 7)
        // 只登记首次出现:重复登记不产生新记录
        XCTAssertEqual(updated.registeringBirths(in: snapshot).entries.count, 7)
    }

    // MARK: - 兜底三分类

    /// 断链(父不在快照)且出生登记无记录:落"孤儿进程"。
    func testUnregisteredBrokenChainProcessFallsToOrphanGroup() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 777,
                parentPID: 1, // launchd 不在快照中:父链断
                executablePath: "/opt/homebrew/bin/waifud",
                argv: ["waifud"],
                physicalFootprintBytes: 30_000_000
            ),
        ])

        // 出生登记为空(如 Pulse 启动晚于进程出生)
        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [777: 7])

        XCTAssertEqual(groups.count, 1)
        let orphan = groups[0]
        XCTAssertEqual(orphan.name, "孤儿进程")
        XCTAssertEqual(orphan.category, .orphan)
        XCTAssertEqual(orphan.processes.map(\.pid), [777])
        XCTAssertEqual(orphan.cpuPercent, 7, accuracy: 0.0001)
    }

    /// WindowServer(自身路径在 .app bundle 里)与内核:落"系统",不另成 App 组。
    func testWindowServerAndKernelTaskFallToSystemGroupDespiteBundlePath() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 128,
                parentPID: 1,
                executablePath: "/System/Library/CoreServices/WindowServer.app/Contents/MacOS/WindowServer",
                physicalFootprintBytes: 90_000_000
            ),
            RawProcess(
                pid: 0,
                parentPID: 0,
                executablePath: "/System/Library/Kernels/kernel_task",
                physicalFootprintBytes: 500_000_000
            ),
        ])

        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [128: 40, 0: 25])

        XCTAssertEqual(groups.count, 1)
        let system = groups[0]
        XCTAssertEqual(system.name, "系统")
        XCTAssertEqual(system.category, .system)
        XCTAssertNil(system.bundlePath)
        XCTAssertEqual(system.processes.count, 2)
        XCTAssertEqual(system.cpuPercent, 65, accuracy: 0.0001)
        XCTAssertEqual(system.memoryBytes, 590_000_000)
    }

    /// 活着的 launchd 之下、可执行位于 launchd 域(/Library/LaunchDaemons 等):
    /// 落"后台服务";launchd 自身落"系统"。
    func testLaunchdDomainDaemonUnderLiveLaunchdFallsToBackgroundServiceGroup() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 1,
                parentPID: 0,
                executablePath: "/sbin/launchd",
                physicalFootprintBytes: 20_000_000
            ),
            RawProcess(
                pid: 500,
                parentPID: 1,
                executablePath: "/Library/LaunchDaemons/com.example.tunnel.helper",
                argv: ["com.example.tunnel.helper"],
                physicalFootprintBytes: 400_000_000
            ),
        ])

        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [1: 0.5, 500: 12])

        XCTAssertEqual(groups.count, 2)
        let service = groups[0]
        XCTAssertEqual(service.name, "后台服务")
        XCTAssertEqual(service.category, .backgroundService)
        XCTAssertEqual(service.processes.map(\.pid), [500])
        XCTAssertEqual(service.cpuPercent, 12, accuracy: 0.0001)

        let system = groups[1]
        XCTAssertEqual(system.name, "系统")
        XCTAssertEqual(system.processes.map(\.pid), [1])
    }

    /// 重启后(无出生记录)的 launchd 域守护:/System/Library 下的可执行、
    /// 现挂在活 launchd 之下 → 仍落"后台服务"(spec:后台服务 = launchd 域推断)。
    func testRestartedSystemDaemonWithoutBirthRecordStaysBackgroundService() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 1,
                parentPID: 0,
                executablePath: "/sbin/launchd",
                physicalFootprintBytes: 20_000_000
            ),
            RawProcess(
                pid: 501,
                parentPID: 1,
                executablePath: "/System/Library/CoreServices/rememberd",
                argv: ["rememberd"],
                physicalFootprintBytes: 60_000_000
            ),
        ])

        // 出生登记为空:Pulse 重启后的真实形态(launchd 在现场,活链可达)。
        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [501: 3])

        XCTAssertEqual(groups.count, 2)
        let daemon = groups.first { $0.processes.contains { $0.pid == 501 } }
        XCTAssertEqual(daemon?.name, "后台服务")
        XCTAssertEqual(daemon?.category, .backgroundService)
    }

    /// 用户级 LaunchAgent 域(~/Library/LaunchAgents):同样按"后台服务"。
    func testUserLaunchAgentsDomainDaemonFallsToBackgroundService() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 1,
                parentPID: 0,
                executablePath: "/sbin/launchd"
            ),
            RawProcess(
                pid: 502,
                parentPID: 1,
                executablePath: "/Users/x/Library/LaunchAgents/com.example.sync",
                argv: ["com.example.sync"],
                physicalFootprintBytes: 40_000_000
            ),
        ])

        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [502: 2])

        XCTAssertEqual(groups.count, 2)
        let daemon = groups.first { $0.processes.contains { $0.pid == 502 } }
        XCTAssertEqual(daemon?.category, .backgroundService)
    }

    /// 父为活 launchd 但可执行不在 launchd 域(评审 S3:不再一律算后台服务):
    /// 落"孤儿进程"——重启后无出生记录的自装/homebrew 常驻是典型形态。
    func testNonDomainExecutableUnderLiveLaunchdFallsToOrphanGroup() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 1,
                parentPID: 0,
                executablePath: "/sbin/launchd",
                physicalFootprintBytes: 20_000_000
            ),
            RawProcess(
                pid: 500,
                parentPID: 1,
                executablePath: "/usr/local/postgres/bin/postgres",
                argv: ["postgres", "-D", "/usr/local/postgres/data"],
                physicalFootprintBytes: 400_000_000
            ),
        ])

        // 无出生记录(Pulse 重启后):现父是 launchd ≠ launchd 域服务。
        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [500: 12])

        XCTAssertEqual(groups.count, 2)
        let postgres = groups.first { $0.processes.contains { $0.pid == 500 } }
        XCTAssertEqual(postgres?.name, "孤儿进程")
        XCTAssertEqual(postgres?.category, .orphan)
    }

    /// 有出生记录、出生时父即 launchd:可执行在 launchd 域 → 后台服务;
    /// 不在域内(出生即挂在 launchd 下的用户进程)→ 孤儿。
    func testLaunchdBornRecordClassifiesByExecutableDomain() {
        let registered = LineageRegistry().registeringBirths(
            in: ProcessSnapshot(processes: [
                RawProcess(pid: 1, parentPID: 0, executablePath: "/sbin/launchd"),
                RawProcess(
                    pid: 600,
                    parentPID: 1,
                    executablePath: "/Library/LaunchAgents/com.example.agentd",
                    argv: ["com.example.agentd"]
                ),
                RawProcess(
                    pid: 601,
                    parentPID: 1,
                    executablePath: "/opt/homebrew/bin/waifud",
                    argv: ["waifud"]
                ),
            ])
        )
        // 现场与出生一致(仍在 launchd 之下)。
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(pid: 1, parentPID: 0, executablePath: "/sbin/launchd"),
            RawProcess(
                pid: 600,
                parentPID: 1,
                executablePath: "/Library/LaunchAgents/com.example.agentd",
                argv: ["com.example.agentd"]
            ),
            RawProcess(
                pid: 601,
                parentPID: 1,
                executablePath: "/opt/homebrew/bin/waifud",
                argv: ["waifud"]
            ),
        ])

        let groups = GroupingEngine.groups(from: snapshot, lineage: registered)

        let agentd = groups.first { $0.processes.contains { $0.pid == 600 } }
        XCTAssertEqual(agentd?.category, .backgroundService, "launchd 域可执行 → 后台服务")
        let waifud = groups.first { $0.processes.contains { $0.pid == 601 } }
        XCTAssertEqual(waifud?.category, .orphan, "非域可执行 → 孤儿进程")
    }

    /// launchd 域路径谓词(S3 判定的唯一口径):系统域、两级 LaunchAgents/Daemons、
    /// 用户级 LaunchAgents 命中;一般安装位 / 应用 / nil 不命中。
    func testLaunchdDomainExecutablePathPredicate() {
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath("/Library/LaunchAgents/com.x"))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath("/Library/LaunchDaemons/com.x"))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath("/System/Library/CoreServices/foo"))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath("/Users/x/Library/LaunchAgents/com.x"))
        // 相近但不属于域的位置不误伤。
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath("/Library/Application Support/com.x"))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath("/usr/local/postgres/bin/postgres"))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath("/opt/homebrew/bin/waifud"))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath("/Applications/Foo.app/Contents/MacOS/Foo"))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath(nil))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath(""))
    }

    /// launchd 域 2026-10-16 扩充:/usr/{sbin,libexec} 的 Apple 系统守护与
    /// /Library/{SystemExtensions,PrivilegedHelperTools,Developer} 都算域内;
    /// /usr/bin 刻意不算(用户一次性命令 ssh/python3 不该读成后台服务),
    /// /usr/local、/opt/homebrew 维持域外(S3 本意)。
    func testLaunchdDomainExtendedPrefixes() {
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath("/usr/libexec/logd"))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath("/usr/sbin/securityd"))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath(
            "/Library/SystemExtensions/ABC/com.example.ext.systemextension/Contents/MacOS/ext"
        ))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath(
            "/Library/PrivilegedHelperTools/com.macpaw.CleanMyMac5.Agent"
        ))
        XCTAssertTrue(GroupingEngine.isLaunchdDomainExecutablePath(
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simdiskimaged"
        ))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath("/usr/bin/ssh"))
        XCTAssertFalse(GroupingEngine.isLaunchdDomainExecutablePath("/usr/local/corplink/corplink-service"))
    }

    /// .app 容器谓词 2026-10-16 放宽:/Applications、/Users 下 .app 容器内的
    /// 助手(Frameworks、XPCServices、PlugIns/*.appex)算 bundle 内进程;
    /// 系统域(/System、/Library)与 /usr/local 不放宽,留给 launchd 域判定。
    func testAppContainerPredicateWidening() {
        // 严格口径回归:嵌套 Helper.app 仍算容器内(归属取最外层宿主)。
        XCTAssertTrue(GroupingEngine.isBundleExecutablePath(
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Helper"
        ))
        // 放宽:断链助手的三种典型驻地。
        XCTAssertTrue(GroupingEngine.isBundleExecutablePath(
            "/Applications/WeChat.app/Contents/Frameworks/crashpad_handler"
        ))
        XCTAssertTrue(GroupingEngine.isBundleExecutablePath(
            "/Applications/Input Source Pro.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
        ))
        XCTAssertTrue(GroupingEngine.isBundleExecutablePath(
            "/Applications/Stats.app/Contents/PlugIns/WidgetsExtension.appex/Contents/MacOS/WidgetsExtension"
        ))
        XCTAssertTrue(GroupingEngine.isBundleExecutablePath(
            "/Applications/Raycast.app/Contents/XPCServices/Raycast Accessibility.xpc/Contents/MacOS/agent"
        ))
        XCTAssertTrue(GroupingEngine.isBundleExecutablePath(
            "/Users/aa00930/Demo.app/Contents/Resources/helper"
        ))
        // 不放宽:系统域与厂商域的容器进程不做 App 归属。
        XCTAssertFalse(GroupingEngine.isBundleExecutablePath(
            "/System/Library/CoreServices/Foo.xpc/Contents/MacOS/foo"
        ))
        XCTAssertFalse(GroupingEngine.isBundleExecutablePath(
            "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Helper"
        ))
        XCTAssertFalse(GroupingEngine.isBundleExecutablePath(
            "/usr/local/Foo.app/Contents/Resources/helper"
        ))
        XCTAssertFalse(GroupingEngine.isBundleExecutablePath("/opt/homebrew/bin/tool"))
        XCTAssertFalse(GroupingEngine.isBundleExecutablePath(nil))
    }

    /// 断链的宿主 App 助手(crashpad 断链成 launchd 子进程)→ 归宿主 App 组,
    /// 不再落孤儿(放宽前它落孤儿进程)。
    func testOrphanedHostAppHelperAttributesToHostBundle() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 47639,
                parentPID: 1,
                executablePath: "/Applications/WeChat.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler",
                argv: ["chrome_crashpad_handler"],
                physicalFootprintBytes: 9_000_000
            ),
        ])
        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [47639: 1])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "WeChat")
        XCTAssertEqual(groups[0].category, .app)
        XCTAssertEqual(groups[0].bundlePath, "/Applications/WeChat.app")
    }

    /// /usr/libexec 的 Apple 系统守护(logd 等,launchd 之下):落"后台服务",
    /// 不再落孤儿(域扩充前 ~200 个系统守护全被误成孤儿,孤儿桶虚胖)。
    func testAppleSystemDaemonUnderLaunchdFallsToBackgroundService() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 1,
                parentPID: 0,
                executablePath: "/sbin/launchd",
                physicalFootprintBytes: 20_000_000
            ),
            RawProcess(
                pid: 336,
                parentPID: 1,
                executablePath: "/usr/libexec/logd",
                argv: ["logd"],
                physicalFootprintBytes: 30_000_000
            ),
        ])
        let groups = GroupingEngine.groups(from: snapshot, cpuPercentByPID: [1: 0.2, 336: 3])

        XCTAssertEqual(groups.count, 2)
        let daemon = groups.first { $0.processes.contains { $0.pid == 336 } }
        XCTAssertEqual(daemon?.name, "后台服务")
        XCTAssertEqual(daemon?.category, .backgroundService)
    }

    // MARK: - 项目归因(评审 S4:不看可执行名,名单闸解除)

    /// 名单外工具(zig)的 cwd 命中项目根 → 照样归"项目名 @ worktree"。
    func testUnlistedToolWithCwdUnderRootAttributesToProject() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 210,
                parentPID: 1,
                executablePath: "/usr/local/bin/zig",
                argv: ["zig", "build", "test"],
                cwd: worktree("unlisted"),
                physicalFootprintBytes: 90_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [210: 60]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "octok-client @ unlisted")
        XCTAssertEqual(groups[0].category, .project)
        XCTAssertEqual(groups[0].processes.map(\.pid), [210])
        XCTAssertEqual(groups[0].cpuPercent, 60, accuracy: 0.0001)
    }

    /// 名单外工具的 argv 路径命中项目根(cwd 受限)→ 同样归项目组。
    func testUnlistedToolViaArgvPathAttributesToProject() {
        let snapshot = ProcessSnapshot(processes: [
            RawProcess(
                pid: 211,
                parentPID: 1,
                executablePath: "/usr/local/bin/bazel",
                argv: ["bazel", "test", octokRoot + "/..."],
                physicalFootprintBytes: 70_000_000
            ),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: GroupingConfiguration(projectRoots: [octokRoot]),
            cpuPercentByPID: [211: 40]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "octok-client")
        XCTAssertEqual(groups[0].category, .project)
    }

    // MARK: - 纯函数

    /// 引擎为纯函数:同输入同输出,不持任何跨调用状态。
    func testEngineIsPureSameInputsProduceEqualOutputs() {
        let snapshot = ProcessSnapshot(
            takenAt: Date(timeIntervalSince1970: 1000),
            processes: octokGateTree()
        )
        let lineage = LineageRegistry().registeringBirths(in: snapshot)
        let configuration = GroupingConfiguration(projectRoots: [octokRoot])

        let first = GroupingEngine.groups(
            from: snapshot, lineage: lineage, configuration: configuration, cpuPercentByPID: octokGateCPU()
        )
        let second = GroupingEngine.groups(
            from: snapshot, lineage: lineage, configuration: configuration, cpuPercentByPID: octokGateCPU()
        )

        XCTAssertEqual(first, second)
    }
}
