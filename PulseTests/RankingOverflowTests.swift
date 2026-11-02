@testable import Pulse
@testable import PulseCore
import XCTest

/// 接缝:排行截断(ranking-limit/01,主窗口与弹窗同规则)。上限切分、末行有无与文案口径、
/// 主窗口展开态、弹窗「查看全部」冷开窗落点(路由 pending)在此钉死;末行外观走预览。
@MainActor
final class RankingOverflowTests: XCTestCase {
    private let limit = RankingOverflow.limit

    // MARK: - 切分

    func testSplitKeepsEverythingAtOrUnderLimit() {
        let items = Array(0 ..< limit)
        let (shown, hidden) = RankingOverflow.split(items, isExpanded: false)
        XCTAssertEqual(Array(shown), items)
        XCTAssertEqual(hidden, 0)
    }

    func testSplitTruncatesToLimitWhenCollapsed() {
        let items = Array(0 ..< (limit + 7))
        let (shown, hidden) = RankingOverflow.split(items, isExpanded: false)
        XCTAssertEqual(Array(shown), Array(0 ..< limit))
        XCTAssertEqual(hidden, 7)
    }

    func testSplitShowsAllWhenExpanded() {
        let items = Array(0 ..< (limit + 7))
        let (shown, hidden) = RankingOverflow.split(items, isExpanded: true)
        XCTAssertEqual(Array(shown), items)
        XCTAssertEqual(hidden, 0, "展开态无隐藏项")
    }

    // MARK: - 末行

    func testNoOverflowRowAtOrUnderLimitEvenWhenExpanded() {
        // 展开态下榜单缩回上限内,也不留一行孤零零的「收起」。
        XCTAssertNil(RankingOverflow.rowModel(total: limit, action: .jump({})))
        XCTAssertNil(RankingOverflow.rowModel(total: limit, action: .expand(isExpanded: true, toggle: {})))
    }

    func testOverflowRowCarriesHiddenCountWhenCollapsed() {
        let row = RankingOverflow.rowModel(total: limit + 3, action: .expand(isExpanded: false, toggle: {}))
        XCTAssertEqual(row?.hiddenCount, 3)
        XCTAssertEqual(row?.action.isExpanded, false)
    }

    func testOverflowRowStaysAsCollapseHandleWhenExpanded() {
        let row = RankingOverflow.rowModel(total: limit + 3, action: .expand(isExpanded: true, toggle: {}))
        XCTAssertNotNil(row, "超上限的展开态要留「收起」行")
        XCTAssertEqual(row?.hiddenCount, 0)
        XCTAssertEqual(row?.action.isExpanded, true)
    }

    func testJumpActionIsNeverExpanded() {
        XCTAssertFalse(RankingOverflow.Action.jump({}).isExpanded, "弹窗只跳转,不原地展开")
    }

    // MARK: - 主窗口展开态(按卡 id)

    func testExpandInPlacePolicyTogglesModelPerRankingID() {
        let model = DashboardModel(monitor: .preview())
        let cpuID = MetricTabBlockBuilder.groupRankingID(for: .cpu)
        let memoryID = MetricTabBlockBuilder.groupRankingID(for: .memory)

        guard case let .expand(isExpanded, toggle) = RankingOverflowPolicy.expandInPlace.action(
            for: cpuID,
            model: model
        )
        else { return XCTFail("主窗口策略应派生原地展开动作") }
        XCTAssertFalse(isExpanded)
        toggle()
        XCTAssertTrue(model.expandedRankingIDs.contains(cpuID))
        XCTAssertFalse(model.expandedRankingIDs.contains(memoryID), "展开态按卡 id,不跨 tab")

        model.toggleRankingExpansion(cpuID)
        XCTAssertFalse(model.expandedRankingIDs.contains(cpuID), "再点一次收起")
        model.expandRanking(cpuID)
        model.expandRanking(cpuID)
        XCTAssertTrue(model.expandedRankingIDs.contains(cpuID), "预置展开重复无害")
    }

    func testJumpPolicyHandsRankingIDToHost() {
        var jumped: String?
        let policy = RankingOverflowPolicy.jumpToMainWindow { jumped = $0 }
        guard case let .jump(open) = policy.action(for: "battery-energy", model: DashboardModel(monitor: .preview()))
        else { return XCTFail("弹窗策略应派生跳转动作") }
        open()
        XCTAssertEqual(jumped, "battery-energy")
    }

    // MARK: - 冷开窗落点(路由 pending)

    func testRouterStashIsConsumedOnceThenCleared() {
        let router = AlertNotificationRouter()
        router.stash(tab: .battery, rankingID: "battery-energy")
        XCTAssertEqual(router.pendingTab, .battery)
        XCTAssertEqual(router.consumePendingTab(), .battery)
        XCTAssertEqual(router.consumePendingRankingID(), "battery-energy")
        XCTAssertNil(router.consumePendingTab(), "消费即清,不重放")
        XCTAssertNil(router.consumePendingRankingID())
    }

    func testRouterClearPendingDropsBothSlots() {
        let router = AlertNotificationRouter()
        router.stash(tab: .cpu, rankingID: "cpu-group-ranking")
        router.clearPending()
        XCTAssertNil(router.pendingTab)
        XCTAssertNil(router.pendingRankingID)
    }
}
