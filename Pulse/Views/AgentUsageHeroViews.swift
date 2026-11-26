import PulseCore
import SwiftUI

// MARK: - 消耗页主卡(agent-usage-redesign/02)

//
// 主卡沿用 DESIGN.md「指标卡两形态」的大卡(左列读数 + 右侧走势),多一行卡头放
// 作用于整卡的范围开关——这是消耗页唯一的「7 天 | 30 天」,项目榜单跟着它走。
// · 全尺寸:卡头 → [左列 200(今日消耗与今日环比一行 / 大数字 / 读数格)+ 走势],
//   正文高 184;读数格两格并排、Claude 用量通栏(每格够宽,副行都是单行);
// · 紧凑档(弹窗):卡头 → 说明与大数字一行(环比在右端)→ 64 高的走势 → 读数格一行。
// 今日环比拿全天等效量去比昨天(`AgentUsageFigures.todayDelta`),大数字恒为实际值。
// 主卡与走势全用定高:弹窗把整页当一个量高块,弹性高会把整页量成天文数字。

/// 范围(7 / 30 天):主卡的走势与读数、项目榜单共用同一个状态。
enum AgentUsageRange: Hashable {
    case week
    case month

    var days: Int {
        self == .week ? 7 : 30
    }

    var title: String {
        self == .week ? "7 天" : "30 天"
    }

    /// 窗口环比基准的称谓(7 天比上周、30 天比上月)。
    var previousLabel: String {
        self == .week ? "较上周" : "较上月"
    }
}

/// 消耗页主卡。
struct AgentUsageHeroCard: View {
    let figures: AgentUsageFigures
    /// 当前范围的逐天合计(走势用)。
    let totals: [AgentDayTotal]
    /// Claude 用量快照(5 小时窗优先,缺失退本周;两窗全缺如实「—」)。
    var usage: ClaudeUsageSnapshot?
    let isCompact: Bool
    @Binding var range: AgentUsageRange

    /// 正文高:读数格带副行,比大卡标准的 176 高 8(DESIGN.md「指标卡两形态」)。
    private static let bodyHeight: CGFloat = 184
    /// 左列宽,与大卡标准同(DESIGN.md「指标卡两形态」)。
    private static let columnWidth: CGFloat = 200
    /// 紧凑档走势高(大卡紧凑档的走势高)。
    private static let compactTrendHeight: CGFloat = 64
    /// 卡头与正文之间(`{spacing.group-gap}`)。
    private static let headerGap: CGFloat = 12

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                regularBody
            }
        }
        .cardShell(compact: isCompact, padded: false)
    }

    // MARK: 全尺寸

    private var regularBody: some View {
        let padding = CardMetrics.padding(compact: false)
        return VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, padding)
                .padding(.top, padding)
            HStack(alignment: .top, spacing: 24) {
                AgentUsageFiguresColumn(figures: figures, usage: usage, range: range)
                    .frame(width: Self.columnWidth, alignment: .topLeading)
                AgentTrendChart(totals: totals, height: Self.bodyHeight, showsPeakLabels: true)
                    .accessibilityHidden(true)
            }
            .frame(height: Self.bodyHeight)
            .padding(.horizontal, padding)
            .padding(.top, Self.headerGap)
            .padding(.bottom, padding)
        }
    }

    // MARK: 紧凑档

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("今日消耗")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                let figure = agentTokenFigure(figures.todayTotal)
                FigureText(value: figure.value, unit: figure.unit, size: FigureSize.mainCompact)
                Spacer(minLength: 8)
                AgentUsageTodayDelta(delta: figures.todayDelta, size: .micro)
            }
            AgentTrendChart(totals: totals, height: Self.compactTrendHeight, showsPeakLabels: false)
                .accessibilityHidden(true)
            AgentUsageStatCells(figures: figures, usage: usage, range: range, layout: .threeColumns)
        }
        .padding(CardMetrics.padding(compact: true))
    }

    // MARK: 零件

    /// 卡头:标题 + 全页唯一的范围开关(标准药丸页签条的常规档)。
    private var header: some View {
        CardHeader(symbolName: nil, title: "消耗", tint: agentsAccent) {
            PillTabBar([AgentUsageRange.week, .month], selection: $range) { item in
                PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
            }
        }
    }
}

/// 主卡左列(全尺寸):首行「今日消耗」与今日环比(环比靠右,和它说明的读数同组),
/// 下接今日实际用量,再下是读数格。环比不与大数字同行:44pt 的读数再加环比,
/// 200pt 的左列放不下。
struct AgentUsageFiguresColumn: View {
    let figures: AgentUsageFigures
    var usage: ClaudeUsageSnapshot?
    let range: AgentUsageRange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日消耗")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                AgentUsageTodayDelta(delta: figures.todayDelta, size: .stat)
            }
            let figure = agentTokenFigure(figures.todayTotal)
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.main)
            AgentUsageStatCells(figures: figures, usage: usage, range: range, layout: .twoColumnsWithWideThird)
                .padding(.top, 8)
        }
    }
}

/// 今日环比:按全天等效量比昨天,不是「实际值比实际值」——悬停说明讲清楚。
struct AgentUsageTodayDelta: View {
    let delta: Double?
    let size: AgentDeltaText.Size

    var body: some View {
        AgentDeltaText(label: "较昨日", delta: delta, size: size)
            .help("今天还没过完:按已过的时间折算成全天进度后再和昨天比(不足 6 小时按 6 小时算)。大数字是实际用量")
    }
}

/// 读数格的排法:全尺寸两格并排 + 第三格通栏(每格够宽,副行都是单行);
/// 紧凑档三格并排(整行宽)。
enum AgentUsageStatLayout {
    case twoColumnsWithWideThird
    case threeColumns
}

/// 主卡读数格:窗口合计(副行:较上期)/ 日均(副行:峰值)/ Claude 用量(副行:本周 · 重置)。
struct AgentUsageStatCells: View {
    let figures: AgentUsageFigures
    /// Claude 用量快照(5 小时窗优先,缺失退本周;两窗全缺如实「—」)。
    var usage: ClaudeUsageSnapshot?
    let range: AgentUsageRange
    let layout: AgentUsageStatLayout

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            switch layout {
            case .twoColumnsWithWideThird:
                GridRow {
                    windowCell
                    averageCell
                }
                GridRow {
                    claudeCell
                        .gridCellColumns(2)
                }
            case .threeColumns:
                GridRow {
                    windowCell
                    averageCell
                    claudeCell
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var windowCell: some View {
        statCell("\(figures.windowDays) 天合计", agentTokenText(figures.windowTotal)) {
            AgentDeltaText(label: range.previousLabel, delta: figures.windowDelta)
        }
    }

    private var averageCell: some View {
        statCell("日均(\(figures.windowDays) 天)", agentTokenText(figures.windowAverage)) {
            subline("峰值 \(agentTokenText(figures.windowPeak))/天")
        }
    }

    private var claudeCell: some View {
        statCell("Claude 用量", claudeUsageText) {
            subline(usageSubline)
        }
    }

    private func statCell(
        _ label: String,
        _ value: String,
        @ViewBuilder sub: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            StatValue(label: label, value: value)
            sub()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }

    // MARK: Claude 用量

    /// 5 小时窗优先,缺失退本周;两窗全缺如实「—」,不伪造。
    private var claudeUsageText: String {
        if let window = usage?.fiveHour ?? usage?.sevenDay {
            "\(window.usedPercentage)%"
        } else {
            "—"
        }
    }

    /// 副行:本周占用 + 窗口重置(读得到的才写;都读不到如实说)。
    private var usageSubline: String {
        var parts: [String] = []
        if let week = usage?.sevenDay {
            parts.append("本周 \(week.usedPercentage)%")
        }
        if let resetsIn = usage?.fiveHour?.resetsAt.map(\.timeIntervalSinceNow),
           resetsIn > 0 {
            parts.append("重置 \(PulseFormat.duration(seconds: resetsIn))后")
        }
        return parts.isEmpty ? "未读到快照" : parts.joined(separator: " · ")
    }
}
