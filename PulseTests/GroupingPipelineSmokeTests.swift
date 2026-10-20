import XCTest
@testable import Pulse
@testable import PulseCore

/// 真机冒烟(工单 05):两轮 Live 采集 → 差分 → 归组,弹窗首屏数据路径的
/// 真实可用性。与 LiveProcessSourceSmokeTests 同一决策口径:证明可用,不深测。
final class GroupingPipelineSmokeTests: XCTestCase {
    func testLiveSweepsProduceRankedTopGroupsIncludingSystem() {
        let source = LiveProcessSource()
        // 大上限取全量组:验证"系统组参与排名"(在榜与否取决于真机负载,
        // launchd 常年近 0% 落到 Top-5 之外是合法结果);前 5 个即弹窗所见。
        var pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(
                bundleDisplayName: BundleDisplayNameReader.shared.displayName
            ),
            displayLimit: 1000
        )

        // 首采登记出生(全新生儿、CPU 全 nil);间隔 1.1s 再采一张让差分有墙钟可除。
        let first = source.snapshot()
        _ = pipeline.update(
            snapshot: first,
            processCPU: CPUDiffer.diff(previous: nil, current: first).processCPU
        )
        Thread.sleep(forTimeInterval: 1.1)
        let second = source.snapshot()
        let allGroups = pipeline.update(
            snapshot: second,
            processCPU: CPUDiffer.diff(previous: first, current: second).processCPU
        )
        let topGroups = Array(allGroups.prefix(GroupingPipeline.defaultDisplayLimit))

        print(
            "[smoke] 真机 Top-\(topGroups.count) 组:\n"
                + topGroups
                .map { "  \($0.name) [\($0.category.rawValue)] \($0.processes.count) 进程 \(Int($0.cpuPercent.rounded()))% \(PulseFormat.memory($0.memoryBytes))" }
                .joined(separator: "\n")
        )

        XCTAssertFalse(allGroups.isEmpty, "真机应有组可归")
        let cpus = allGroups.map(\.cpuPercent)
        XCTAssertEqual(cpus, cpus.sorted(by: >), "全量组按组 CPU% 降序")
        XCTAssertTrue(allGroups.contains { $0.category == .system }, "系统组应参与排名(launchd 恒在)")
        XCTAssertLessThanOrEqual(topGroups.count, GroupingPipeline.defaultDisplayLimit)
        topGroups.forEach { group in
            XCTAssertFalse(group.name.isEmpty)
            XCTAssertFalse(group.processes.isEmpty)
        }
    }
}
