import AppKit
@testable import Pulse
@testable import PulseCore
import XCTest

/// 接缝:指标 tab 内容模型(工单 P0.6-03,纯逻辑)。
/// 弹窗图标 tab / 主窗口药丸 tab 共用的"哪个 tab 展示什么"在此钉死:
/// tab 顺序与中文标题、键盘 ←/→ 切换语义、每 tab 的组排行口径、
/// 内存环形分段(top5 + 其他)。SwiftUI 外观(图标/药丸/选中胶囊)属预览 +
/// 手动验收,不在此接缝。
final class MetricTabModelTests: XCTestCase {
    // MARK: - MetricTab:顺序与文案

    func testTabsAreOrderedOverviewCPUMemoryGpuSensorsDiskNetworkBatteryHistory() {
        // 展示序即键盘 ←/→ 的移动轴:总览在最左,历史(工单 04)在最右;
        // GPU(p2-sensors/02)与传感器(p2-sensors/04)插在内存之后——硬件族聚拢;
        // 外设(p2-sensors/05)插在传感器与磁盘之间;容器(p2-sensors/07)插在
        // 网络与电池之间(服务负载与 disk/network 相邻,电池/历史收尾不动)。
        XCTAssertEqual(
            MetricTab.allCases.map(\.rawValue),
            [
                "overview",
                "cpu",
                "memory",
                "gpu",
                "sensors",
                "peripherals",
                "disk",
                "network",
                "containers",
                "battery",
                "history",
            ]
        )
    }

    func testTabTitlesAreChinese() {
        // 药丸 tab 文字与无障碍标签共用中文文案。
        let titles = MetricTab.allCases.map(\.title)
        XCTAssertEqual(titles, ["总览", "CPU", "内存", "GPU", "传感器", "外设", "磁盘", "网络", "容器", "电池", "历史"])
    }

    func testTabSymbolsAreDistinct() {
        // 图标 tab 靠符号区分,互异才可辨识。
        let symbols = MetricTab.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }

    func testTabAndHistorySymbolsResolveToRealSFSymbols() {
        // 符号名拼错 = Image(systemName:) 静默渲染空白(p2-sensors/07 实案:
        // 容器 tab 写了本机不存在的 "shippingcontainer.fill",图标位空白直到
        // 目验才抓到)。虽属外观,这是机械事实非观感判断,测试钉死:全 tab +
        // 历史页指标条(同样图标承载)逐一 NSImage 解析非空。
        let symbols = MetricTab.allCases.map(\.symbolName)
            + HistoryMetricKey.allCases.map(\.symbolName)
        for symbol in symbols {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "SF Symbol 不存在:\(symbol)"
            )
        }
    }

    func testTabAccentMapsToMetricTokens() {
        // 选中态强调色(tint 派生)的色源:总览以系统负载(CPU)为主视角,
        // CPU/内存/磁盘/电池 tab → 各自令牌;历史页默认主视角同为系统负载
        // (工单 04,页内曲线色另随所选指标取)。
        XCTAssertEqual(MetricTab.overview.accent, .cpu)
        XCTAssertEqual(MetricTab.cpu.accent, .cpu)
        XCTAssertEqual(MetricTab.memory.accent, .memory)
        XCTAssertEqual(MetricTab.disk.accent, .disk)
        XCTAssertEqual(MetricTab.network.accent, .network)
        XCTAssertEqual(MetricTab.battery.accent, .battery)
        XCTAssertEqual(MetricTab.history.accent, .cpu)
    }

    // MARK: - MetricTabSelection:键盘 ←/→ 切换

    func testSelectionDefaultsToOverview() {
        XCTAssertEqual(MetricTabSelection().current, .overview)
    }

    func testMoveRightAdvancesInDisplayOrder() {
        // → 键沿展示序右移:总览 → CPU → 内存 → GPU → 传感器 → 外设 → 磁盘 → 电池 → 历史
        // (GPU p2-sensors/02、传感器 p2-sensors/04 相继插在内存之后;外设 05 插
        // 传感器与磁盘之间)。
        var selection = MetricTabSelection()
        selection.moveRight()
        XCTAssertEqual(selection.current, .cpu)
        selection.moveRight()
        XCTAssertEqual(selection.current, .memory)
        selection.moveRight()
        XCTAssertEqual(selection.current, .gpu)
        selection.moveRight()
        XCTAssertEqual(selection.current, .sensors)
        selection.moveRight()
        XCTAssertEqual(selection.current, .peripherals)
        selection.moveRight()
        XCTAssertEqual(selection.current, .disk)
        selection.moveRight()
        XCTAssertEqual(selection.current, .network)
        selection.moveRight()
        XCTAssertEqual(selection.current, .containers)
        selection.moveRight()
        XCTAssertEqual(selection.current, .battery)
        selection.moveRight()
        XCTAssertEqual(selection.current, .history)
    }

    func testMoveLeftRetreatsInDisplayOrder() {
        // ← 键左移:历史 → 电池 → 容器 → 网络 → 磁盘 → 外设 → 传感器 → GPU → 内存 → CPU → 总览。
        var selection = MetricTabSelection(current: .history)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .battery)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .containers)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .network)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .disk)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .peripherals)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .sensors)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .gpu)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .memory)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .cpu)
        selection.moveLeft()
        XCTAssertEqual(selection.current, .overview)
    }

    func testMovesClampAtBothEnds() {
        // 两端不回绕:最左再 ←、最右再 → 都停在原地(可预期的键盘行为)。
        var leftmost = MetricTabSelection(current: .overview)
        leftmost.moveLeft()
        XCTAssertEqual(leftmost.current, .overview)

        var rightmost = MetricTabSelection(current: .history)
        rightmost.moveRight()
        XCTAssertEqual(rightmost.current, .history)
    }

    // MARK: - 展示轴:无电池机器隐藏电池页(工单 02);历史页只在主窗口(工单 04)

    func testDisplayAxisKeepsAllTabsWithBattery() {
        XCTAssertEqual(MetricTab.displayAxis(hasBattery: true), MetricTab.allCases)
    }

    func testDisplayAxisHidesBatteryWithoutBattery() {
        // 磁盘/网络/GPU/传感器页(工单 05/06、p2-sensors/02、04)常驻轴
        // (每台 Mac 都有),无电池只隐藏电池页;历史页(工单 04)同为主窗口常驻轴。
        XCTAssertEqual(
            MetricTab.displayAxis(hasBattery: false),
            [.overview, .cpu, .memory, .gpu, .sensors, .peripherals, .disk, .network, .containers, .history]
        )
    }

    func testKeyboardMovesFollowAxisWithoutBattery() {
        // 无电池机器:轴不含电池页(含 GPU/传感器/外设/容器,共 10 页),→ 走
        // 9 步到历史右端,再 → 夹紧停下(不跳空)。
        var selection = MetricTabSelection(axis: MetricTab.displayAxis(hasBattery: false))
        for _ in 0 ..< 9 {
            selection.moveRight()
        }
        XCTAssertEqual(selection.current, .history)
        selection.moveRight()
        XCTAssertEqual(selection.current, .history, "轴右端 = 历史(工单 04),再 → 不动")
    }

    func testSetAxisHidesCurrentTabFallsBackToOverview() {
        // 电池页被隐藏时当前 tab 不留悬空选中:回落总览。
        var selection = MetricTabSelection(current: .battery)
        selection.setAxis(MetricTab.displayAxis(hasBattery: false))
        XCTAssertEqual(selection.current, .overview)
    }

    func testDeepLinkToHiddenTabFallsBackToOverview() {
        // 走查深链注入 .battery 而机器无电池:初始化即回落总览。
        let selection = MetricTabSelection(current: .battery, axis: MetricTab.displayAxis(hasBattery: false))
        XCTAssertEqual(selection.current, .overview)
    }

    // MARK: - MetricTabContent:每 tab 的组排行与组卡口径

    /// 测试用组:id 即名(app 身份的原始值同名字),cpu/mem 显式给定。
    private func group(
        _ id: String,
        cpu: Double,
        mem: UInt64,
        category: GroupCategory = .app,
        bundlePath: String? = nil
    ) -> ProcessGroup {
        let identity: GroupIdentity = switch category {
        case .app: .app(bundlePath: bundlePath ?? id)
        case .project: .project(root: id, worktreeName: nil)
        case .system: .system
        case .backgroundService: .backgroundService
        case .orphan: .orphan
        }
        return ProcessGroup(
            id: identity,
            name: id,
            processes: [],
            cpuPercent: cpu,
            memoryBytes: mem
        )
    }

    /// 期望榜单的身份序列(与旧字符串口径同形:app 身份原始值即名字)。
    private func identities(_ ids: [String]) -> [GroupIdentity] {
        ids.map { GroupIdentity.app(bundlePath: $0) }
    }

    /// 期望分段身份序列:组段 + "其他"段收尾(nil = 不是组)。
    private func segmentIdentities(_ ids: [String]) -> [GroupIdentity?] {
        identities(ids).map(Optional.init) + [nil]
    }

    func testOverviewAndCPUTabsRankByCPUDescending() {
        // 总览与 CPU tab:组 CPU% 降序(与引擎既定序一致——输入打乱也能复位)。
        let groups = [
            group("b", cpu: 40, mem: 100),
            group("a", cpu: 445, mem: 50),
            group("c", cpu: 120, mem: 200),
        ]

        let overview = MetricTabContent.build(groups: groups, tab: .overview)
        XCTAssertEqual(overview.ranking.map(\.id), identities(["a", "c", "b"]))
        XCTAssertEqual(overview.metric, .cpu)

        let cpu = MetricTabContent.build(groups: groups, tab: .cpu)
        XCTAssertEqual(cpu.ranking.map(\.id), identities(["a", "c", "b"]))
        XCTAssertEqual(cpu.metric, .cpu)
    }

    func testDiskTabRanksByCPULikeOverview() {
        // 磁盘 tab(工单 05)不排组——榜单沿用 CPU 序供弹窗"当前最忙"卡,
        // 口径与总览一致(CPU 降序、cpu 卡口径)。
        let groups = [
            group("b", cpu: 40, mem: 100),
            group("a", cpu: 445, mem: 50),
        ]
        let disk = MetricTabContent.build(groups: groups, tab: .disk)
        XCTAssertEqual(disk.ranking.map(\.id), identities(["a", "b"]))
        XCTAssertEqual(disk.metric, .cpu)
    }

    func testMemoryTabRanksByMemoryDescending() {
        // 内存 tab:内存降序重排,组卡换内存大数字口径。
        let groups = [
            group("hot", cpu: 445, mem: 500), // CPU 榜首但内存垫底
            group("fat", cpu: 3, mem: 9000),
            group("mid", cpu: 30, mem: 4000),
        ]

        let content = MetricTabContent.build(groups: groups, tab: .memory)
        XCTAssertEqual(content.ranking.map(\.id), identities(["fat", "mid", "hot"]))
        XCTAssertEqual(content.metric, .memory)
    }

    func testRankingTiesBreakByGroupIDAscending() {
        // 同值次键 id 升序(与引擎口径一致):排序跨采样轮稳定。
        let groups = [
            group("c", cpu: 50, mem: 1000),
            group("a", cpu: 50, mem: 1000),
            group("b", cpu: 50, mem: 1000),
        ]

        XCTAssertEqual(
            MetricTabContent.build(groups: groups, tab: .cpu).ranking.map(\.id),
            identities(["a", "b", "c"])
        )
        XCTAssertEqual(
            MetricTabContent.build(groups: groups, tab: .memory).ranking.map(\.id),
            identities(["a", "b", "c"])
        )
    }

    func testMeterLeadersFollowFullGroupList() {
        // meter 归一榜首(工单 02 口径)取全部组的最大值,与榜单同源。
        let groups = [
            group("a", cpu: 12, mem: 100),
            group("b", cpu: 445, mem: 2400),
            group("c", cpu: 89, mem: 9999),
        ]

        let content = MetricTabContent.build(groups: groups, tab: .overview)
        XCTAssertEqual(content.cpuLeader, 445)
        XCTAssertEqual(content.memoryLeaderBytes, 9999)
    }

    // MARK: - MetricTabContent:内存环形分段(top5 + 其他)

    private func memGroups(_ values: [UInt64]) -> [ProcessGroup] {
        values.enumerated().map { index, bytes in
            group("m\(index)", cpu: 1, mem: bytes)
        }
    }

    func testMemorySegmentsTakeTopFivePlusOther() {
        // 7 组 [100,500,300,50,400,200,600]:前 5 名(600/500/400/300/200)各一段
        // + "其他"聚合段(尾部 100+50),内存降序。
        let segments = MetricTabContent.build(
            groups: memGroups([100, 500, 300, 50, 400, 200, 600]),
            tab: .memory
        ).memorySegments

        XCTAssertEqual(
            segments.map(\.id),
            segmentIdentities(["m6", "m1", "m4", "m2", "m5"])
        )
        XCTAssertEqual(segments.map(\.bytes), [600, 500, 400, 300, 200, 150])
        XCTAssertTrue(segments.last?.isOther ?? false)
        XCTAssertFalse(segments.first?.isOther ?? true)
        // 其他段:无 bundle 路径(图例用通用符号),名字为中文兜底文案。
        XCTAssertEqual(segments.last?.bundlePath, nil)
        XCTAssertEqual(segments.last?.name, "其他")
        // 分数:每段 = 字节 / 总量(2150),其他 = 150/2150。
        let expectedFractions: [Double] = [
            600.0 / 2150, 500.0 / 2150, 400.0 / 2150, 300.0 / 2150, 200.0 / 2150, 150.0 / 2150,
        ]
        XCTAssertEqual(segments.count, expectedFractions.count)
        for (segment, expected) in zip(segments, expectedFractions) {
            XCTAssertEqual(segment.fraction, expected, accuracy: 1e-9)
        }
    }

    func testMemorySegmentsSkipOtherWhenAllFit() {
        // ≤5 组(零内存组先剔除):全部入段,不造"其他"。
        let five = MetricTabContent.build(
            groups: memGroups([100, 500, 300, 50, 400]),
            tab: .memory
        ).memorySegments
        XCTAssertEqual(five.count, 5)
        XCTAssertFalse(five.contains(where: \.isOther))

        let three = MetricTabContent.build(
            groups: memGroups([10, 30, 20]),
            tab: .memory
        ).memorySegments
        XCTAssertEqual(three.map(\.id), identities(["m1", "m2", "m0"]))
        XCTAssertFalse(three.contains(where: \.isOther))
    }

    func testMemorySegmentsExcludeZeroByteGroups() {
        // 零内存组不占段(0 字节的 SectorMark 不可见,图例也只添噪声);
        // 非零组 [500,400,300,200,100,50] → 前 5 名 + 其他(仅剩 50)。
        let segments = MetricTabContent.build(
            groups: memGroups([0, 100, 0, 500, 300, 50, 400, 200]),
            tab: .memory
        ).memorySegments

        XCTAssertEqual(
            segments.map(\.id),
            segmentIdentities(["m3", "m6", "m4", "m7", "m1"])
        )
        XCTAssertEqual(segments.last?.bytes, 50)
    }

    func testMemoryTotalSumsAllGroupsIncludingExcluded() {
        // 环心大数字 = 全部组内存合计(含零段被剔除的组与"其他"尾组)。
        let content = MetricTabContent.build(
            groups: memGroups([100, 500, 0, 250]),
            tab: .memory
        )
        XCTAssertEqual(content.memoryTotalBytes, 850)
    }

    func testDegenerateEmptyGroupsYieldEmptyContent() {
        // 空载 / 首轮采样前:榜单空、榜首 0、分段空、总量 0——不出坏图。
        let content = MetricTabContent.build(groups: [], tab: .memory)
        XCTAssertTrue(content.ranking.isEmpty)
        XCTAssertTrue(content.memorySegments.isEmpty)
        XCTAssertEqual(content.memoryTotalBytes, 0)
        XCTAssertEqual(content.memoryLeaderBytes, 0)
        XCTAssertEqual(content.cpuLeader, 0)
    }

    func testAllZeroMemoryYieldsNoSegmentsButNonzeroTotalIsZero() {
        // 全零内存:分段空(每段都是 0 字节,画不出),总量 0 由空态兜底。
        let content = MetricTabContent.build(groups: memGroups([0, 0]), tab: .memory)
        XCTAssertTrue(content.memorySegments.isEmpty)
        XCTAssertEqual(content.memoryTotalBytes, 0)
    }

    // MARK: - 模块排行可见性判据(工单 01)

    func testModuleRankingTabsAreExactlyTheThreeModulePages() {
        // 排行卡只上电池/磁盘/网络三页(工单拍板);成员资格钉死,防手滑增删。
        XCTAssertEqual(MetricTab.moduleRankingTabs, [.battery, .disk, .network])
        XCTAssertTrue(MetricTab.battery.hostsModuleRanking)
        XCTAssertTrue(MetricTab.disk.hostsModuleRanking)
        XCTAssertTrue(MetricTab.network.hostsModuleRanking)
        XCTAssertFalse(MetricTab.overview.hostsModuleRanking)
        XCTAssertFalse(MetricTab.cpu.hostsModuleRanking)
        XCTAssertFalse(MetricTab.memory.hostsModuleRanking)
        XCTAssertFalse(MetricTab.history.hostsModuleRanking)
    }
}
