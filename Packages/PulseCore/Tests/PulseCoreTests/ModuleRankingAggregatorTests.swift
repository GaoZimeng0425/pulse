@testable import PulseCore
import XCTest

/// 模块排行聚合(工单 01,纯逻辑):每 pid 读数字典 → 按组聚合的排行行。
/// 钉死:组行 = 成员之和、按主值降序次键稳定、未知 pid 入"其他进程"
/// 桶、空字典出空榜、零值行不上榜、meter 榜首归一。
/// (能耗榜已于 battery-energy/01 移交 root 能耗口径,不再在本聚合层;
/// 组求和/降序等通用口径由磁盘榜测试承载。)
final class ModuleRankingAggregatorTests: XCTestCase {
    /// 公共夹具:Xcode 组(成员 pid 10/11)+ 项目组(成员 pid 20);
    /// pid 99 留给"快照里找不到"的用例。
    private func sampleGroups() -> [ProcessGroup] {
        [
            ProcessGroup(
                id: .app(bundlePath: "/Applications/Xcode.app"), name: "Xcode",
                processes: [
                    RawProcess(pid: 10, parentPID: 1),
                    RawProcess(pid: 11, parentPID: 1),
                ],
                cpuPercent: 0, memoryBytes: 0
            ),
            ProcessGroup(
                id: .project(root: "/Users/x/work/demo", worktreeName: "main"), name: "demo @ main",
                processes: [RawProcess(pid: 20, parentPID: 1)],
                cpuPercent: 0, memoryBytes: 0
            ),
        ]
    }

    // MARK: 未知 pid 入桶

    func testUnknownPIDFallsIntoOtherProcessesBucket() {
        let rows = ModuleRankingAggregator.diskRows(
            rates: [99: ProcessDiskRates(readBytesPerSec: 500, writeBytesPerSec: 0)],
            groups: sampleGroups()
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, ModuleRankingAggregator.otherProcessesKey)
        XCTAssertEqual(rows[0].name, "其他进程")
        XCTAssertNil(rows[0].bundlePath) // 通用符号瓦片的信号:无 bundle、无类别
        XCTAssertNil(rows[0].fallbackCategory)
        XCTAssertEqual(rows[0].primary, 500, accuracy: 1e-9)
        XCTAssertEqual(rows[0].meterFraction, 1.0, accuracy: 1e-9) // 榜内唯一 = 榜首
    }

    // MARK: 空字典 / 零值

    func testEmptyDictionariesYieldEmptyBoards() {
        XCTAssertTrue(ModuleRankingAggregator.diskRows(rates: [:], groups: sampleGroups()).isEmpty)
        XCTAssertTrue(ModuleRankingAggregator.networkRows(rates: [:], groups: []).isEmpty)
    }

    /// 零速率的 pid 不上榜(纯噪声);全零时出空榜交卡片空态兜底
    /// (磁盘版承载,原能耗版同语义随能耗榜移交删)。
    func testAllZeroReadingsStayOffTheBoard() {
        let rows = ModuleRankingAggregator.diskRows(
            rates: [
                10: ProcessDiskRates(readBytesPerSec: 0, writeBytesPerSec: 0),
                20: ProcessDiskRates(readBytesPerSec: 0, writeBytesPerSec: 300_000),
            ],
            groups: sampleGroups()
        )
        XCTAssertEqual(rows.map(\.id), ["project:/Users/x/work/demo@main"])
    }

    // MARK: 磁盘 / 网络

    func testDiskRowsSumAcrossMembersAndCarryReadWriteSubtitle() {
        let rates: [pid_t: ProcessDiskRates] = [
            10: ProcessDiskRates(readBytesPerSec: 1_000_000, writeBytesPerSec: 500_000),
            11: ProcessDiskRates(readBytesPerSec: 250_000, writeBytesPerSec: 0),
            20: ProcessDiskRates(readBytesPerSec: 0, writeBytesPerSec: 300_000),
        ]
        let rows = ModuleRankingAggregator.diskRows(rates: rates, groups: sampleGroups())

        XCTAssertEqual(rows.map(\.id), ["bundle:/Applications/Xcode.app", "project:/Users/x/work/demo@main"])
        XCTAssertEqual(rows[0].primary, 1_750_000, accuracy: 1e-6) // 读 1.25M + 写 0.5M
        XCTAssertEqual(rows[0].primaryText, PulseFormat.diskRate(1_750_000))
        XCTAssertEqual(rows[0].meterFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(
            rows[0].subtitle,
            "读 \(PulseFormat.diskRate(1_250_000)) · 写 \(PulseFormat.diskRate(500_000))"
        )
        XCTAssertEqual(rows[1].meterFraction, 300.0 / 1750.0, accuracy: 1e-9)
    }

    func testNetworkRowsRankByDownPlusUpAndBucketUnknownPIDs() {
        let rates: [pid_t: ProcessNetworkRates] = [
            20: ProcessNetworkRates(downBytesPerSec: 800_000, upBytesPerSec: 200_000),
            99: ProcessNetworkRates(downBytesPerSec: 100_000, upBytesPerSec: 50000),
        ]
        let rows = ModuleRankingAggregator.networkRows(rates: rates, groups: sampleGroups())

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "project:/Users/x/work/demo@main")
        XCTAssertEqual(rows[0].primary, 1_000_000, accuracy: 1e-6) // 下 + 上
        XCTAssertEqual(rows[0].meterFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].id, ModuleRankingAggregator.otherProcessesKey)
        XCTAssertEqual(rows[1].primary, 150_000, accuracy: 1e-6)
        XCTAssertEqual(rows[1].meterFraction, 150.0 / 1000.0, accuracy: 1e-9)
        // 副文箭头分列上下行。
        XCTAssertEqual(
            rows[0].subtitle,
            "↓\(PulseFormat.networkRateBadge(800_000)) ↑\(PulseFormat.networkRateBadge(200_000))"
        )
    }
}
