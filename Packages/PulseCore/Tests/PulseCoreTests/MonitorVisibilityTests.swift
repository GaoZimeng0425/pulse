@testable import PulseCore
import XCTest

// MARK: - 可见性双 tab 槽(p2-review/05)派生语义与家族闸

/// `MonitorVisibility` 两槽(popoverTab / mainWindowTab)的派生读数与
/// `shows(_:)` 家族闸——弹窗停在无传感器内容的 tab 不开任何家族闸,
/// 是本票的行为核心。tab → 家族映射(`displayedFamilies`)与排行页集合
/// (`moduleRankingTabs`)的成员资格在此钉死:视图层卡片组成改动时,
/// 这里红了就是映射需要同步,不是测试过时。
final class MonitorVisibilityTests: XCTestCase {
    // ── 派生在场读数 ──

    func testNilSlotsMeanClosed() {
        let none = MonitorVisibility()
        XCTAssertFalse(none.popover)
        XCTAssertFalse(none.mainWindow)
        XCTAssertFalse(none.moduleRankings)
        XCTAssertFalse(none.anyWindow)
    }

    func testPopoverDerivedFromTabSlot() {
        XCTAssertTrue(MonitorVisibility(popoverTab: .cpu).popover)
        XCTAssertFalse(MonitorVisibility(popoverTab: .cpu).mainWindow)
    }

    func testModuleRankingsDerivedFromMainWindowTab() {
        // 排行模块页:battery / disk / network(moduleRankingTabs 集合)。
        XCTAssertTrue(MonitorVisibility(mainWindowTab: .battery).moduleRankings)
        XCTAssertTrue(MonitorVisibility(mainWindowTab: .disk).moduleRankings)
        XCTAssertTrue(MonitorVisibility(mainWindowTab: .network).moduleRankings)
        XCTAssertFalse(MonitorVisibility(mainWindowTab: .history).moduleRankings)
        // 弹窗任何 tab 都承载组排行卡:弹窗在场即开排行闸,但 popoverTab
        // 本身不进 moduleRankings 派生(那是主窗口侧的读数)。
        XCTAssertFalse(MonitorVisibility(popoverTab: .battery).moduleRankings)
        XCTAssertTrue(MonitorVisibility(popoverTab: .overview).anyWindow)
    }

    // ── 家族闸 shows(_:) ──

    func testPopoverOnNonSensorTabOpensNoFamilyGate() {
        // 本票主命题:弹窗停在 CPU 页,五族采集全关。
        let cpuOnly = MonitorVisibility(popoverTab: .cpu)
        for family in MetricSensorFamily.allCases {
            XCTAssertFalse(cpuOnly.shows(family), "\(family) 不该在 CPU tab 开闸")
        }
    }

    func testFamilyGatesFollowDisplayedFamilies() {
        // 总览只吃 GPU 卡;GPU 页 GPU + 功率;传感器/外设/容器各只本族。
        let overview = MonitorVisibility(popoverTab: .overview)
        XCTAssertTrue(overview.shows(.gpu))
        XCTAssertFalse(overview.shows(.power))

        let gpuPage = MonitorVisibility(mainWindowTab: .gpu)
        XCTAssertTrue(gpuPage.shows(.gpu))
        XCTAssertTrue(gpuPage.shows(.power))
        XCTAssertFalse(gpuPage.shows(.smc))

        XCTAssertTrue(MonitorVisibility(mainWindowTab: .sensors).shows(.smc))
        XCTAssertFalse(MonitorVisibility(mainWindowTab: .sensors).shows(.gpu))
        XCTAssertTrue(MonitorVisibility(popoverTab: .peripherals).shows(.bluetooth))
        XCTAssertTrue(MonitorVisibility(popoverTab: .containers).shows(.containers))
    }

    func testEitherWindowShowingFamilyOpensGate() {
        // 两窗互补:主窗口在 GPU 页 + 弹窗停传感器页 → GPU 与 SMC 同时开。
        let both = MonitorVisibility(popoverTab: .sensors, mainWindowTab: .gpu)
        XCTAssertTrue(both.shows(.gpu))
        XCTAssertTrue(both.shows(.smc))
    }

    func testPopoverOnOldGpuFlagPageStillGatedAfterClose() {
        // 关窗(槽归 nil)即全关——历史 30s 档不经此闸,此处只管 5s UI 档。
        var visibility = MonitorVisibility(popoverTab: .gpu, mainWindowTab: .gpu)
        XCTAssertTrue(visibility.shows(.power))
        visibility.popoverTab = nil
        visibility.mainWindowTab = nil
        for family in MetricSensorFamily.allCases {
            XCTAssertFalse(visibility.shows(family))
        }
    }

    // ── tab → 家族映射全表(与 MetricTabStack 卡片组成对齐)──

    func testDisplayedFamiliesTable() {
        XCTAssertEqual(MetricTab.overview.displayedFamilies, [.gpu])
        XCTAssertEqual(MetricTab.gpu.displayedFamilies, [.gpu, .power])
        XCTAssertEqual(MetricTab.sensors.displayedFamilies, [.smc])
        XCTAssertEqual(MetricTab.peripherals.displayedFamilies, [.bluetooth])
        XCTAssertEqual(MetricTab.containers.displayedFamilies, [.containers])
        // 无家族内容的 tab:排行与主卡数据走心跳/低频档,不经家族闸。
        for tab: MetricTab in [.cpu, .memory, .disk, .network, .battery, .history] {
            XCTAssertTrue(tab.displayedFamilies.isEmpty, "\(tab) 不该展示传感器家族")
        }
    }
}
