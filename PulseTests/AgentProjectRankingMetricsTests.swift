import AppKit
@testable import Pulse
@testable import PulseCore
import SwiftUI
import XCTest

/// agent-usage-redesign/03:项目榜单的尺寸钉子——列宽、委托关系、弹窗量高。只量几何与
/// 数值、不上屏:量高按弹窗原生列表同款量法(宽定、高无上限)。
final class AgentProjectRankingMetricsTests: XCTestCase {
    /// 消耗列现实最宽读数(各单位的最高位形态)。
    private let tokenReadings = ["999.9B", "999.9M", "999k", "999"]
    /// 占比列现实最宽读数(整数百分比)。
    private let shareReadings = ["100%", "99%", "0%"]
    /// 环比列现实最宽读数(三位数涨跌、持平);过千的读数靠缩字号,见量高用例。
    private let deltaReadings = ["▲ +999%", "▼ -999%", "持平"]

    /// 弹窗里榜单卡的内宽:面板 360 − 两侧窗口内距 12 × 2 − 卡内距 12 × 2。
    private static let compactCardWidth: CGFloat = 312

    private func width(_ reading: String, fontSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        return (reading as NSString).size(withAttributes: [.font: font]).width
    }

    func testEveryRealisticReadingFitsItsColumn() {
        for compact in [false, true] {
            let tier = compact ? "紧凑" : "全尺寸"
            let fontSize = RowMetrics.valueFontSize(compact: compact)
            for reading in tokenReadings {
                XCTAssertLessThanOrEqual(
                    width(reading, fontSize: fontSize, weight: .semibold),
                    AgentProjectRankingMetrics.tokensWidth(compact: compact),
                    "\(reading) 撑出\(tier)消耗列"
                )
            }
        }
        // 占比、环比两列只有全尺寸行有。
        for reading in shareReadings {
            XCTAssertLessThanOrEqual(
                width(reading, fontSize: RowMetrics.valueFontSize(compact: false), weight: .semibold),
                AgentProjectRankingMetrics.shareWidth,
                "\(reading) 撑出占比列"
            )
        }
        for reading in deltaReadings {
            XCTAssertLessThanOrEqual(
                width(reading, fontSize: 10.5, weight: .regular),
                AgentProjectRankingMetrics.deltaWidth,
                "\(reading) 撑出环比列"
            )
        }
    }

    /// 共享值必须委托出处,不在本页重抄(DESIGN.md「委托关系有防漂移单测」)。
    func testSharedSizesDelegateToTheirSources() {
        XCTAssertEqual(AgentProjectRankingMetrics.barWidth, RowMetrics.meterWidth(compact: false))
        XCTAssertEqual(
            AgentProjectRankingMetrics.shareWidth,
            CardRowWidth.scaled(CardRowWidth.percentValue, fontSize: RowMetrics.valueFontSize(compact: false))
        )
        for compact in [false, true] {
            XCTAssertEqual(
                AgentProjectRankingMetrics.trailingWidth(compact: compact),
                RankingListMetrics.trailingWidth(compact: compact)
            )
        }
    }

    // MARK: 弹窗量高

    /// 环比没有上限:涨过千的行靠缩字号放进定宽列,榜单不能因此变高。
    @MainActor
    func testFourDigitDeltaDoesNotMakeTheCardTaller() {
        for width in [900 as CGFloat, Self.compactCardWidth] {
            let fourDigit = Self.cardHeight(
                width: width, projects: Self.twoProjects(pulseCurrent: 150_000_000, pulsePrevious: 10_000_000),
                expanded: []
            )
            let threeDigit = Self.cardHeight(
                width: width, projects: Self.twoProjects(pulseCurrent: 1_000_000, pulsePrevious: 500_000),
                expanded: []
            )
            XCTAssertEqual(fourDigit, threeDigit, accuracy: 0.5, "宽 \(width):四位数环比把榜单撑高了")
        }
    }

    /// 展开一行明细后,弹窗量法仍量得出有限高,且与实际排版高一致(收起态由子页量高
    /// 用例钉着)。展开必须真的比收起高,否则这条用例量的不是明细。
    @MainActor
    func testExpandedDetailMeasuresLikePopoverListAndMatchesLayout() {
        let projects = Self.manyProjects()
        let expandedID = projects[0].id
        let expanded = Self.cardHeight(width: Self.compactCardWidth, projects: projects, expanded: [expandedID])
        let collapsed = Self.cardHeight(width: Self.compactCardWidth, projects: projects, expanded: [])
        XCTAssertLessThan(expanded, 2000)
        XCTAssertGreaterThan(expanded - collapsed, 60)
        XCTAssertEqual(
            expanded,
            Self.laidOutHeight(width: Self.compactCardWidth, projects: projects, expanded: [expandedID]),
            accuracy: 1,
            "弹窗量法报的高与实排不一致(行容器换成惰性堆叠就会这样)"
        )
    }

    // MARK: 夹具与量法

    /// 榜单卡在给定宽下按弹窗量法(宽定、高取最大有限值)量出的高;窄于 700 按紧凑档。
    @MainActor
    private static func cardHeight(
        width: CGFloat,
        projects: [AgentProjectSummary],
        expanded: Set<String>
    ) -> CGFloat {
        let card = Self.card(width: width, projects: projects, expanded: expanded)
        return NSHostingController(rootView: AnyView(card)).sizeThatFits(
            in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
    }

    /// 同一张卡实际排版出来的高(装进够高的宿主视图、转一轮运行循环后取理想高)。
    @MainActor
    private static func laidOutHeight(
        width: CGFloat,
        projects: [AgentProjectSummary],
        expanded: Set<String>
    ) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(card(width: width, projects: projects, expanded: expanded)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    private static func card(
        width: CGFloat,
        projects: [AgentProjectSummary],
        expanded: Set<String>
    ) -> some View {
        AgentProjectRankingCard(
            projects: projects,
            windowDays: 7,
            isCompact: width < 700,
            expandedProjects: .constant(expanded),
            showsAll: .constant(false)
        )
    }

    /// 两个项目 × 近 14 天:pulse 本窗 / 前窗的日用量由入参给(环比随之变),
    /// octok-client 恒为 +11%。
    private static func twoProjects(pulseCurrent: Int, pulsePrevious: Int) -> [AgentProjectSummary] {
        summary(
            rows("pulse", current: pulseCurrent, previous: pulsePrevious)
                + rows("octok-client", current: 50_000_000, previous: 45_000_000)
        )
    }

    /// 12 个项目 × 近 14 天:超过默认上限 10,榜首涨过千,有的在跑。
    private static func manyProjects() -> [AgentProjectSummary] {
        let names = [
            "pulse", "octok-client", "NemoNotch", "agent-usage-redesign-worktree", "sage", "tokscale",
            "dust-rs", "petal", "iSurge", "stats", "mole", "purge-app",
        ]
        let rows = names.enumerated().flatMap { index, name in
            let current = index == 0 ? 150_000_000 : 90_000_000 / (index + 1)
            let previous = index == 0 ? 10_000_000 : 70_000_000 / (index + 1)
            return self.rows(name, current: current, previous: previous)
        }
        return summary(
            rows,
            liveCounts: ["pulse": 2, "NemoNotch": 1],
            sessionCounts: ["pulse": 291]
        )
    }

    private static func summary(
        _ rows: [AgentProjectUsageRow],
        liveCounts: [String: Int] = [:],
        sessionCounts: [String: Int] = [:]
    ) -> [AgentProjectSummary] {
        AgentUsageWindow.projects(
            projectRows: rows,
            modelRows: [],
            days: 7,
            liveCounts: liveCounts,
            sessionCounts: sessionCounts
        )
    }

    private static func rows(_ name: String, current: Int, previous: Int) -> [AgentProjectUsageRow] {
        (0 ..< 14).map { offset in
            let total = offset < 7 ? current : previous
            return AgentProjectUsageRow(
                day: dayKey(offset: offset),
                source: .claude,
                project: name,
                inputTokens: total / 5,
                outputTokens: total / 10,
                cacheReadTokens: total / 2,
                cacheWriteTokens: total / 20,
                totalTokens: total / 2,
                requestCount: 40
            )
        }
    }

    /// 今天倒推 offset 天的账本日键;日期从当前时钟推,不写死(写死的夹具跨午夜必挂)。
    private static func dayKey(offset: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date()))!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
