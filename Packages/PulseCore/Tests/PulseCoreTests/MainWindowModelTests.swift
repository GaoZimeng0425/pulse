import XCTest
@testable import PulseCore

/// 主窗口模型(工单 P0.5-01):窗口与弹窗共用同一条采样管线,
/// 区别只在截取——弹窗取 Top-5,主窗口要**全部组**。此文件测两个纯逻辑接缝:
/// 1. GroupingPipeline 的全组列表(Top-5 截取之前的完整榜单);
/// 2. ProcessTableOrder 进程表排序(主窗口进程表 CPU%/内存两列可排序)。
/// 期望值全部为独立字面量;窗口 UI 按 spec 测试决策以手动验收。
final class MainWindowModelTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: 全组列表(截取之前的完整榜单)

    /// 7 个 App 组 + 1 个系统组:弹窗截 Top-5,主窗口拿全部 8 组,
    /// 两者同序(组 CPU% 降序)——窗口列表只是弹窗榜单去截断,不是另一套归组。
    func testAllGroupsKeepsFullRankingBeyondTopCut() {
        let apps = (1...7).map { index in
            RawProcess(
                pid: pid_t(200 + index),
                parentPID: 1,
                executablePath: "/Applications/A\(index * 10).app/Contents/MacOS/A\(index * 10)"
            )
        }
        let windowServer = RawProcess(
            pid: 1,
            parentPID: 0,
            executablePath: "/System/Library/CoreServices/WindowServer.app/Contents/MacOS/WindowServer"
        )
        let processCPU =
            (1...7).map { index in
                ProcessCPU(pid: pid_t(200 + index), cpuPercent: Double(index * 10))
            } + [ProcessCPU(pid: 1, cpuPercent: 1)]
        var pipeline = GroupingPipeline()

        let top = pipeline.update(
            snapshot: ProcessSnapshot(takenAt: base, processes: apps + [windowServer]),
            processCPU: processCPU
        )

        XCTAssertEqual(top.count, 5, "弹窗口径不变:仍截 Top-5")
        XCTAssertEqual(pipeline.allGroups.count, 8, "主窗口口径:全部组(7 App + 1 系统)")
        XCTAssertEqual(
            pipeline.allGroups.map(\.name),
            ["A70", "A60", "A50", "A40", "A30", "A20", "A10", "系统"]
        )
        // 弹窗 Top-5 恰为全组列表前缀:两处 UI 读同一榜单的不同截取。
        XCTAssertEqual(Array(pipeline.allGroups.prefix(5)).map(\.id), top.map(\.id))
    }

    /// 全组列表随每轮采样整体刷新:第 6 名 CPU 反超后,下一轮进入主窗口首行。
    func testAllGroupsRefreshEachSweep() {
        func tree(a20CPU: UInt64, a80CPU: UInt64) -> [RawProcess] {
            [
                RawProcess(
                    pid: 20,
                    parentPID: 1,
                    executablePath: "/Applications/A20.app/Contents/MacOS/A20",
                    cpuTimeNanoseconds: a20CPU
                ),
                RawProcess(
                    pid: 80,
                    parentPID: 1,
                    executablePath: "/Applications/A80.app/Contents/MacOS/A80",
                    cpuTimeNanoseconds: a80CPU
                ),
            ]
        }
        let source = SyntheticProcessSource(snapshots: [
            ProcessSnapshot(takenAt: base, processes: tree(a20CPU: 0, a80CPU: 0)),
            ProcessSnapshot(takenAt: base.addingTimeInterval(5), processes: tree(a20CPU: 250_000_000, a80CPU: 500_000_000)),
        ])
        var pipeline = GroupingPipeline()

        let (_, firstSnapshot) = {
            let snapshot = source.snapshot()
            let diff = CPUDiffer.diff(previous: nil, current: snapshot)
            let top = pipeline.update(snapshot: snapshot, processCPU: diff.processCPU)
            return (top, snapshot)
        }()
        XCTAssertEqual(pipeline.allGroups.map(\.name), ["A20", "A80"], "首轮全 0%,并列按组 id 升序")

        let snapshot = source.snapshot()
        let diff = CPUDiffer.diff(previous: firstSnapshot, current: snapshot)
        _ = pipeline.update(snapshot: snapshot, processCPU: diff.processCPU)

        XCTAssertEqual(
            pipeline.allGroups.map(\.name),
            ["A80", "A20"],
            "第二轮 A80(10%)反超 A20(5%),全组列表随之刷新"
        )
    }

    /// 极端空载:无组可显示,主窗口呈空态(全组列表为空,不坏 UI)。
    func testEmptySnapshotProducesEmptyAllGroups() {
        var pipeline = GroupingPipeline()

        _ = pipeline.update(snapshot: ProcessSnapshot(takenAt: base, processes: []), processCPU: [])

        XCTAssertTrue(pipeline.allGroups.isEmpty)
    }

    // MARK: 进程表排序(主窗口:CPU% / 内存两列可排序)

    private let sampleRows = [
        ProcessRowModel(pid: 100, name: "rustc", cpuPercent: 90, memoryBytes: 200_000_000),
        ProcessRowModel(pid: 11, name: "node", cpuPercent: 5, memoryBytes: 500_000_000),
        ProcessRowModel(pid: 12, name: "cargo", cpuPercent: 5, memoryBytes: 50_000_000),
    ]

    /// 默认序 = 引擎既定序(进程 CPU% 降序):进窗口不点表头时与弹窗下钻同观感。
    func testDefaultOrderIsCPUDescending() {
        let order = ProcessTableOrder()

        XCTAssertEqual(order.sorted(sampleRows).map(\.pid), [100, 11, 12])
    }

    /// 内存列:按物理足迹降序(找吃内存的进程是主场景),与 CPU 无关。
    func testMemoryKeySortsByFootprint() {
        let order = ProcessTableOrder(key: .memory, ascending: false)

        XCTAssertEqual(order.sorted(sampleRows).map(\.pid), [11, 100, 12])
    }

    /// 升降切换:同键反向(CPU 升序 = 安静进程在前;5% 并列按 pid 升序破平)。
    func testAscendingReversesKeyOrder() {
        let order = ProcessTableOrder(key: .cpu, ascending: true)

        XCTAssertEqual(order.sorted(sampleRows).map(\.pid), [11, 12, 100])
    }

    /// 同值稳定:并列时次键 pid 升序——排序不随轮次抖动。
    func testTiesBreakByPIDAscendingForStability() {
        let tied = [
            ProcessRowModel(pid: 300, name: "a", cpuPercent: 7, memoryBytes: 10),
            ProcessRowModel(pid: 200, name: "b", cpuPercent: 7, memoryBytes: 10),
            ProcessRowModel(pid: 250, name: "c", cpuPercent: 9, memoryBytes: 10),
        ]

        XCTAssertEqual(ProcessTableOrder(key: .cpu, ascending: false).sorted(tied).map(\.pid), [250, 200, 300])
        XCTAssertEqual(ProcessTableOrder(key: .memory, ascending: false).sorted(tied).map(\.pid), [200, 250, 300])
    }

    /// 点同一表头 = 升降切换;点另一表头 = 换键且回到该列的主视角(降序)。
    func testToggleAndKeySwitch() {
        var order = ProcessTableOrder() // CPU 降序

        order.toggle(.cpu)
        XCTAssertEqual(order, ProcessTableOrder(key: .cpu, ascending: true), "再点 CPU 表头 → CPU 升序")

        order.toggle(.memory)
        XCTAssertEqual(order, ProcessTableOrder(key: .memory, ascending: false), "点内存表头 → 内存降序")

        order.toggle(.memory)
        XCTAssertEqual(order, ProcessTableOrder(key: .memory, ascending: true))
    }
}
