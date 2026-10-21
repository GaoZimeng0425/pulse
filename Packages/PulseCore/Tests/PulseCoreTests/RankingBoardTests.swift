@testable import PulseCore
import XCTest

/// 模块排行纯值内核(RankingBoard):最新一轮的组 + 三份最新读数 → 按组聚合的排行行。
/// 钉的是「同轮出行」的接线口径(聚合本身的口径由 ModuleRankingAggregatorTests 钉):
/// 组每轮换新、行随组同轮重归属;能耗/磁盘只在满窗轮整份替换(nil = 保留上次);
/// nettop 轮间交付按最新一轮的组重算;组里找不到的 pid 进"其他进程"桶。
/// 只经公开接口断言,期望值全部来自手算的字面量。
final class RankingBoardTests: XCTestCase {
    private let xcodeID = "bundle:/Applications/Xcode.app"
    private let demoID = "project:/Users/x/work/demo@main"

    // MARK: 夹具

    private func xcode(_ pids: [pid_t]) -> ProcessGroup {
        ProcessGroup(
            id: .app(bundlePath: "/Applications/Xcode.app"), name: "Xcode",
            processes: pids.map { RawProcess(pid: $0, parentPID: 1) },
            cpuPercent: 0, memoryBytes: 0
        )
    }

    private func demo(_ pids: [pid_t]) -> ProcessGroup {
        ProcessGroup(
            id: .project(root: "/Users/x/work/demo", worktreeName: "main"), name: "demo @ main",
            processes: pids.map { RawProcess(pid: $0, parentPID: 1) },
            cpuPercent: 0, memoryBytes: 0
        )
    }

    /// 能耗读数:CPU 增量按秒给(主值 = 秒),无唤醒 → 复合分 = CPU 纳秒。
    private func energy(cpuSeconds: Double) -> ProcessEnergyImpact {
        let nanos = UInt64(cpuSeconds * 1_000_000_000)
        return ProcessEnergyImpact(cpuNanosDelta: nanos, wakeupsDelta: 0, impact: nanos)
    }

    // MARK: 同轮重归属

    /// pid 10 在第二轮从 Xcode 挪进 demo(读数不变,满窗轮带来同一份):
    /// 行在同一轮跟着组走——2 秒 CPU 从 Xcode 行换到 demo 行。
    func testEnergyRowFollowsAPIDThatMovesGroupInTheSameRound() {
        var board = RankingBoard()
        let impacts: [pid_t: ProcessEnergyImpact] = [10: energy(cpuSeconds: 2)]

        board.recordRound(
            groups: [xcode([10, 11]), demo([20])],
            rankings: ProcessRankingRound(energyImpacts: impacts)
        )
        XCTAssertEqual(board.energyRows.map(\.id), [xcodeID])
        XCTAssertEqual(board.energyRows.first?.primary ?? 0, 2.0, accuracy: 1e-9)

        board.recordRound(
            groups: [xcode([11]), demo([10, 20])],
            rankings: ProcessRankingRound(energyImpacts: impacts)
        )
        XCTAssertEqual(board.energyRows.map(\.id), [demoID])
        XCTAssertEqual(board.energyRows.first?.primary ?? 0, 2.0, accuracy: 1e-9)
    }

    // MARK: 未满窗轮保留读数、照常换组

    /// 第一轮两窗都满(能耗 pid 10 3 秒、磁盘 pid 20 读 2048 + 写 1024 B/s);第二轮
    /// 两窗都没满(nil),但 10 / 20 互换了组:读数原样保留,行按第二轮的组重归属。
    func testRoundWithoutAFullWindowKeepsReadingsButRegroupsWithFreshGroups() {
        var board = RankingBoard()
        board.recordRound(
            groups: [xcode([10]), demo([20])],
            rankings: ProcessRankingRound(
                energyImpacts: [10: energy(cpuSeconds: 3)],
                diskRates: [20: ProcessDiskRates(readBytesPerSec: 2048, writeBytesPerSec: 1024)]
            )
        )
        XCTAssertEqual(board.energyRows.map(\.id), [xcodeID])
        XCTAssertEqual(board.diskRows.map(\.id), [demoID])

        board.recordRound(groups: [xcode([20]), demo([10])], rankings: .empty)

        XCTAssertEqual(board.energyRows.map(\.id), [demoID])
        XCTAssertEqual(board.energyRows.first?.primary ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(board.diskRows.map(\.id), [xcodeID])
        XCTAssertEqual(board.diskRows.first?.primary ?? 0, 3072, accuracy: 1e-9)
    }

    // MARK: nettop 轮间交付

    /// nettop 5s 自有节拍、与心跳不同步:轮间到达的速率按**最新一轮**的组出行;
    /// 下一轮换组时既有速率随之重归属;交付 nil(从未有过好值)保留上次。
    func testNettopRatesBetweenRoundsUseTheLatestGroups() {
        var board = RankingBoard()
        board.recordRound(groups: [xcode([10])], rankings: .empty)

        board.recordNetworkRates([10: ProcessNetworkRates(downBytesPerSec: 1000, upBytesPerSec: 500)])
        XCTAssertEqual(board.networkRows.map(\.id), [xcodeID])
        XCTAssertEqual(board.networkRows.first?.primary ?? 0, 1500, accuracy: 1e-9)

        // 第二轮:pid 10 挪进 demo、pid 20 新进 Xcode;nettop 尚未再交付。
        board.recordRound(groups: [xcode([20]), demo([10])], rankings: .empty)
        XCTAssertEqual(board.networkRows.map(\.id), [demoID])

        // 轮间交付:按第二轮的组归属(20 → Xcode 4000,10 → demo 1500)。
        board.recordNetworkRates([
            10: ProcessNetworkRates(downBytesPerSec: 1000, upBytesPerSec: 500),
            20: ProcessNetworkRates(downBytesPerSec: 4000, upBytesPerSec: 0),
        ])
        XCTAssertEqual(board.networkRows.map(\.id), [xcodeID, demoID])
        XCTAssertEqual(board.networkRows.map(\.primary), [4000, 1500])

        board.recordNetworkRates(nil)
        XCTAssertEqual(board.networkRows.map(\.primary), [4000, 1500])
    }

    // MARK: 组外 pid 入桶

    /// pid 99 从不在组里 → "其他进程";第二轮 pid 10 退出(组里没了它)而能耗窗未满、
    /// 读数仍在 → 它也落进桶里(1 + 0.5 = 1.5 秒),不再冒用 Xcode 的身份。
    func testPIDsAbsentFromTheLatestGroupsLandInTheOtherProcessesBucket() {
        var board = RankingBoard()
        board.recordRound(
            groups: [xcode([10])],
            rankings: ProcessRankingRound(energyImpacts: [
                10: energy(cpuSeconds: 1),
                99: energy(cpuSeconds: 0.5),
            ])
        )
        XCTAssertEqual(board.energyRows.map(\.id), [xcodeID, ModuleRankingAggregator.otherProcessesKey])

        board.recordRound(groups: [xcode([11])], rankings: .empty)

        XCTAssertEqual(board.energyRows.map(\.id), [ModuleRankingAggregator.otherProcessesKey])
        XCTAssertEqual(board.energyRows.first?.name, "其他进程")
        XCTAssertEqual(board.energyRows.first?.primary ?? 0, 1.5, accuracy: 1e-9)
    }

    // MARK: 满窗整份替换

    /// 满窗轮带来的是整窗读数:空字典(本窗无活跃进程)也整份替换上一窗 → 空榜;
    /// 同轮未满的磁盘窗(nil)不受牵连。
    func testAFullWindowReplacesPreviousReadingsEvenWhenEmpty() {
        var board = RankingBoard()
        board.recordRound(
            groups: [xcode([10])],
            rankings: ProcessRankingRound(
                energyImpacts: [10: energy(cpuSeconds: 1)],
                diskRates: [10: ProcessDiskRates(readBytesPerSec: 100, writeBytesPerSec: 0)]
            )
        )

        board.recordRound(groups: [xcode([10])], rankings: ProcessRankingRound(energyImpacts: [:]))

        XCTAssertEqual(board.energyRows, [])
        XCTAssertEqual(board.diskRows.map(\.id), [xcodeID])
    }

    /// 首轮前:三张榜全空(卡片空态安静兜底)。
    func testFreshBoardHasNoRows() {
        let board = RankingBoard()
        XCTAssertEqual(board.energyRows, [])
        XCTAssertEqual(board.diskRows, [])
        XCTAssertEqual(board.networkRows, [])
    }
}
