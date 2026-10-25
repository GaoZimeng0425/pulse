@testable import PulseCore
import XCTest

/// 接缝:DrilldownState(工单 06)——最近一轮采样留下的下钻视图输入(纯值)。
/// 覆盖:进程行的字段映射与既定顺序、新出生 CPU% 按 0 计、详情组装(原始记录 + 面包屑)。
/// 期望值全部为独立字面量。
final class DrilldownStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    // MARK: 进程行

    /// 行内四要素(进程名/pid/CPU%/内存):保持组的既定顺序(引擎契约:CPU% 降序),
    /// CPU 从最近差分取,内存取物理足迹(活动监视器"内存"列口径)。
    func testRowsCarryNamePIDCPUMemoryInGroupOrder() {
        let group = ProcessGroup(
            id: .project(root: "octok", worktreeName: nil),
            name: "octok-client @ wt",
            processes: [
                RawProcess(
                    pid: 100,
                    parentPID: 12,
                    executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                    argv: ["rustc"],
                    physicalFootprintBytes: 200_000_000
                ),
                RawProcess(
                    pid: 11,
                    parentPID: 10,
                    executablePath: "/usr/local/bin/node",
                    argv: ["node"],
                    physicalFootprintBytes: 80_000_000
                ),
            ],
            cpuPercent: 95,
            memoryBytes: 280_000_000
        )
        let state = DrilldownState(
            snapshot: ProcessSnapshot(takenAt: now, processes: group.processes),
            lineage: LineageRegistry(),
            processCPU: [
                ProcessCPU(pid: 100, cpuPercent: 90),
                ProcessCPU(pid: 11, cpuPercent: 5),
            ]
        )

        let rows = state.rows(for: group)

        XCTAssertEqual(rows.map(\.pid), [100, 11]) // 组的既定顺序(CPU% 降序)不被打乱
        XCTAssertEqual(rows[0].name, "rustc")
        XCTAssertEqual(rows[0].cpuPercent, 90, accuracy: 0.0001)
        XCTAssertEqual(rows[0].memoryBytes, 200_000_000)
        XCTAssertEqual(rows[1].name, "node")
        XCTAssertEqual(rows[1].cpuPercent, 5, accuracy: 0.0001)
        XCTAssertEqual(rows[1].memoryBytes, 80_000_000)
    }

    /// 新出生进程差分为 nil(无前值)/ 差分表缺条目:行 CPU% 按 0 计——与组聚合同口径。
    func testRowsCountNewbornAndMissingCPUAsZero() {
        let processes = [
            RawProcess(pid: 100, parentPID: 1, executablePath: "/usr/local/bin/node"),
            RawProcess(pid: 101, parentPID: 1, executablePath: "/usr/local/bin/node"),
        ]
        let group = ProcessGroup(
            id: .orphan, name: "g",
            processes: processes, cpuPercent: 0, memoryBytes: 0
        )
        let newborn = DrilldownState(
            snapshot: ProcessSnapshot(takenAt: now, processes: processes),
            lineage: LineageRegistry(),
            processCPU: [ProcessCPU(pid: 100, cpuPercent: nil)] // 101 连差分条目都没有
        )

        XCTAssertEqual(newborn.rows(for: group).map(\.cpuPercent), [0, 0])
    }

    /// 可执行路径受限的行:名字退用 argv[0] basename;两者皆缺退 "pid N"。
    func testRowNameFallsBackToArgvThenPID() {
        let processes = [
            RawProcess(pid: 30, parentPID: 1, argv: ["vitest", "run"]),
            RawProcess(pid: 31, parentPID: 1),
        ]
        let group = ProcessGroup(
            id: .orphan, name: "g",
            processes: processes, cpuPercent: 0, memoryBytes: 0
        )
        let state = DrilldownState(
            snapshot: ProcessSnapshot(takenAt: now, processes: processes),
            lineage: LineageRegistry(),
            processCPU: []
        )

        XCTAssertEqual(state.rows(for: group).map(\.name), ["vitest", "pid 31"])
    }

    /// 宿主徽标(project-visibility/02):可执行命中容器判定的行携带宿主 bundle 路径
    /// (判定走引擎公开口径);非容器行 nil;组本身就是该宿主(App 组下钻)时省略
    /// ——同组重复无信息量。
    func testRowsCarryHostBundlePathForBundledProcessesExceptOwnHost() {
        let processes = [
            RawProcess(
                pid: 21,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode Helper",
                argv: ["Zcode Helper"]
            ),
            RawProcess(
                pid: 11,
                parentPID: 1,
                executablePath: "/usr/local/bin/node",
                argv: ["node"]
            ),
        ]
        let state = DrilldownState(
            snapshot: ProcessSnapshot(takenAt: now, processes: processes),
            lineage: LineageRegistry(),
            processCPU: []
        )

        // 项目组下钻:容器行带宿主,非容器行 nil。
        let projectGroup = ProcessGroup(
            id: .project(root: "/Users/x/work/octok-client", worktreeName: nil),
            name: "octok-client",
            processes: processes, cpuPercent: 0, memoryBytes: 0
        )
        let projectRows = state.rows(for: projectGroup)
        XCTAssertEqual(projectRows[0].hostBundlePath, "/Applications/Zcode.app")
        XCTAssertNil(projectRows[1].hostBundlePath)

        // App 组下钻:宿主即组自身,徽标省略。
        let appGroup = ProcessGroup(
            id: .app(bundlePath: "/Applications/Zcode.app"),
            name: "Zcode",
            processes: [processes[0]], cpuPercent: 0, memoryBytes: 0
        )
        XCTAssertNil(state.rows(for: appGroup)[0].hostBundlePath)
    }

    // MARK: 进程详情

    private func gateTree() -> [RawProcess] {
        [
            RawProcess(
                pid: 10, parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode"
            ),
            RawProcess(
                pid: 11, parentPID: 10,
                executablePath: "/usr/local/bin/node", argv: ["node", "server.js"],
                cwd: "/Users/x/work/octok-client/.worktrees/wt",
                startTime: now.addingTimeInterval(-25 * 60)
            ),
            RawProcess(
                pid: 100, parentPID: 11,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok", "--cap-lints", "allow"],
                cwd: "/Users/x/work/octok-client/.worktrees/wt",
                startTime: now.addingTimeInterval(-40)
            ),
        ]
    }

    /// 详情 = 原始记录(cwd / argv / 启动时刻的来源)+ 面包屑原料(自身在前),
    /// 全部取自构建时那份快照与登记表。
    func testDetailCarriesRawProcessAndParentChainNames() {
        let snapshot = ProcessSnapshot(takenAt: now, processes: gateTree())
        let lineage = LineageRegistry().registeringBirths(in: snapshot)
        let state = DrilldownState(snapshot: snapshot, lineage: lineage, processCPU: [])

        let detail = state.detail(for: 100)

        XCTAssertEqual(detail?.process.pid, 100)
        XCTAssertEqual(detail?.process.cwd, "/Users/x/work/octok-client/.worktrees/wt")
        XCTAssertEqual(detail?.process.argv.first, "rustc")
        XCTAssertEqual(detail?.parentChainNames, ["rustc", "node", "Zcode"])
        XCTAssertEqual(detail?.parentChainText, "rustc ← node ← Zcode")
    }

    /// pid 不在最近采样(下钻期间进程退出):详情为 nil,由 UI 安静收起。
    func testDetailForVanishedPIDReturnsNil() {
        let snapshot = ProcessSnapshot(takenAt: now, processes: gateTree())
        let state = DrilldownState(snapshot: snapshot, lineage: LineageRegistry(), processCPU: [])

        XCTAssertNil(state.detail(for: 999))
    }

    /// 空组(极端空载):行列表为空,不坏 UI。
    func testRowsForEmptyGroupAreEmpty() {
        let group = ProcessGroup(
            id: .system, name: "g",
            processes: [], cpuPercent: 0, memoryBytes: 0
        )
        let state = DrilldownState(
            snapshot: ProcessSnapshot(takenAt: now, processes: []),
            lineage: LineageRegistry(),
            processCPU: []
        )

        XCTAssertTrue(state.rows(for: group).isEmpty)
    }
}
