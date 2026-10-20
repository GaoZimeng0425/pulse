import XCTest
@testable import Pulse
@testable import PulseCore

/// 模块排行聚合(工单 01,纯逻辑):每 pid 读数字典 → 按组聚合的排行行。
/// 钉死六件事:组行 = 成员之和、按主值降序次键稳定、未知 pid 入"其他进程"
/// 桶、空字典出空榜、零值行不上榜、meter 榜首归一;能耗榜按复合分排序而非裸 CPU。
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

    // MARK: 能耗影响

    func testEnergyRowsGroupMembersSumIntoOneRow() {
        let impacts: [pid_t: ProcessEnergyImpact] = [
            10: ProcessEnergyImpact(cpuNanosDelta: 3_000_000_000, wakeupsDelta: 10, impact: 8_000_000_000),
            11: ProcessEnergyImpact(cpuNanosDelta: 1_000_000_000, wakeupsDelta: 20, impact: 3_000_000_000),
            20: ProcessEnergyImpact(cpuNanosDelta: 2_000_000_000, wakeupsDelta: 0, impact: 2_000_000_000),
        ]
        let rows = ModuleRankingAggregator.energyRows(impacts: impacts, windowSeconds: 5, groups: sampleGroups())

        // 组行 = 成员之和:Xcode 两个 pid 合成一行,复合分 8+3=110 亿居首。
        XCTAssertEqual(rows.map(\.id), ["bundle:/Applications/Xcode.app", "project:/Users/x/work/demo@main"])
        XCTAssertEqual(rows[0].name, "Xcode")
        XCTAssertEqual(rows[0].bundlePath, "/Applications/Xcode.app")
        XCTAssertEqual(rows[0].primary, 4.0, accuracy: 1e-9) // (3+1) 亿 ns ×10 = 4.0 秒
        XCTAssertEqual(rows[0].meterFraction, 1.0, accuracy: 1e-9) // 榜首满条
        // 次行 meter 按复合分归一:20 / 110。
        XCTAssertEqual(rows[1].meterFraction, 2.0 / 11.0, accuracy: 1e-9)
        // 副文 = 唤醒/秒(约定 5 秒档折算):Xcode (10+20)/5 = 6.0 次/秒。
        XCTAssertEqual(rows[0].subtitle, "唤醒 \(PulseFormat.wakeupsPerSecond(6.0))")
        XCTAssertEqual(rows[0].primaryText, PulseFormat.cpuSeconds(4.0))
    }

    /// 唤醒/秒按实际窗长折算(不是标称 5s):8s 窗里 Xcode 共唤醒 30 次 → 3.75 次/秒。
    func testEnergyWakeupsPerSecondUseTheActualWindowLength() {
        let impacts: [pid_t: ProcessEnergyImpact] = [
            10: ProcessEnergyImpact(cpuNanosDelta: 3_000_000_000, wakeupsDelta: 10, impact: 8_000_000_000),
            11: ProcessEnergyImpact(cpuNanosDelta: 1_000_000_000, wakeupsDelta: 20, impact: 3_000_000_000),
        ]
        let rows = ModuleRankingAggregator.energyRows(impacts: impacts, windowSeconds: 8, groups: sampleGroups())

        XCTAssertEqual(rows.first?.subtitle, "唤醒 \(PulseFormat.wakeupsPerSecond(3.75))")
    }

    /// 排序口径:能耗榜按复合分(impact),不是裸 CPU——唤醒堆权重的进程名次不亏。
    func testEnergyBoardRanksByCompositeImpact() {
        let impacts: [pid_t: ProcessEnergyImpact] = [
            10: ProcessEnergyImpact(cpuNanosDelta: 2_000_000_000, wakeupsDelta: 0, impact: 2_000_000_000),
            20: ProcessEnergyImpact(cpuNanosDelta: 500_000_000, wakeupsDelta: 40, impact: 2_500_000_000),
        ]
        let rows = ModuleRankingAggregator.energyRows(impacts: impacts, windowSeconds: 5, groups: sampleGroups())

        // CPU 赢家(pid 10)复合分 20 亿 < pid 20 的 25 亿(50ms/唤醒 × 40)。
        XCTAssertEqual(rows.first?.id, "project:/Users/x/work/demo@main")
    }

    // MARK: 未知 pid 入桶

    func testUnknownPIDFallsIntoOtherProcessesBucket() {
        let impacts: [pid_t: ProcessEnergyImpact] = [
            99: ProcessEnergyImpact(cpuNanosDelta: 500_000_000, wakeupsDelta: 0, impact: 500_000_000),
        ]
        let rows = ModuleRankingAggregator.energyRows(impacts: impacts, windowSeconds: 5, groups: sampleGroups())

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, ModuleRankingAggregator.otherProcessesKey)
        XCTAssertEqual(rows[0].name, "其他进程")
        XCTAssertNil(rows[0].bundlePath) // 通用符号瓦片的信号:无 bundle、无类别
        XCTAssertNil(rows[0].fallbackCategory)
        XCTAssertEqual(rows[0].primary, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rows[0].meterFraction, 1.0, accuracy: 1e-9) // 榜内唯一 = 榜首
    }

    // MARK: 空字典 / 零值

    func testEmptyDictionariesYieldEmptyBoards() {
        XCTAssertTrue(ModuleRankingAggregator.energyRows(impacts: [:], windowSeconds: 5, groups: sampleGroups()).isEmpty)
        XCTAssertTrue(ModuleRankingAggregator.diskRows(rates: [:], groups: sampleGroups()).isEmpty)
        XCTAssertTrue(ModuleRankingAggregator.networkRows(rates: [:], groups: []).isEmpty)
    }

    /// 零差分 / 零速率的 pid 不上榜(纯噪声);全零时出空榜交卡片空态兜底。
    func testAllZeroReadingsStayOffTheBoard() {
        let impacts: [pid_t: ProcessEnergyImpact] = [
            10: ProcessEnergyImpact(cpuNanosDelta: 0, wakeupsDelta: 0, impact: 0),
            20: ProcessEnergyImpact(cpuNanosDelta: 1_000_000_000, wakeupsDelta: 0, impact: 1_000_000_000),
        ]
        let rows = ModuleRankingAggregator.energyRows(impacts: impacts, windowSeconds: 5, groups: sampleGroups())
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
        XCTAssertEqual(rows[1].meterFraction, 300.0 / 1_750.0, accuracy: 1e-9)
    }

    func testNetworkRowsRankByDownPlusUpAndBucketUnknownPIDs() {
        let rates: [pid_t: ProcessNetworkRates] = [
            20: ProcessNetworkRates(downBytesPerSec: 800_000, upBytesPerSec: 200_000),
            99: ProcessNetworkRates(downBytesPerSec: 100_000, upBytesPerSec: 50_000),
        ]
        let rows = ModuleRankingAggregator.networkRows(rates: rates, groups: sampleGroups())

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "project:/Users/x/work/demo@main")
        XCTAssertEqual(rows[0].primary, 1_000_000, accuracy: 1e-6) // 下 + 上
        XCTAssertEqual(rows[0].meterFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].id, ModuleRankingAggregator.otherProcessesKey)
        XCTAssertEqual(rows[1].primary, 150_000, accuracy: 1e-6)
        XCTAssertEqual(rows[1].meterFraction, 150.0 / 1_000.0, accuracy: 1e-9)
        // 副文箭头分列上下行。
        XCTAssertEqual(
            rows[0].subtitle,
            "↓\(PulseFormat.networkRateBadge(800_000)) ↑\(PulseFormat.networkRateBadge(200_000))"
        )
    }
}
