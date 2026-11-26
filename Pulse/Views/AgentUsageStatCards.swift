import PulseCore
import SwiftUI

// MARK: - 消耗页数字卡排(agent-usage-redesign/05)

//
// 消耗页最上面一排四张平级小卡:今日消耗 / N 天合计 / 日均 / Claude 用量。主窗口一排
// 四张、弹窗两列两行;同一行等高(`EqualHeightRow`,卡底铺到行底)。
// 每张卡:说明(11 secondary)→ 大数字(figure-card 24 / 弹窗 figure-overview-compact 22)
// → 副行(10.5)。大数字恒为实际值、主色;今日环比拿全天等效量去比昨天
// (`AgentUsageFigures.todayDelta`)。范围开关在走势卡头(与项目榜单的各自独立),这里只读 range。

/// 范围(7 / 30 天):数字卡与走势共用一个状态,项目榜单另有一个。
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

/// 数字卡排(骨架见文件头)。
struct AgentUsageStatCards: View {
    let figures: AgentUsageFigures
    /// Claude 用量快照(5 小时窗优先,缺失退本周;两窗全缺如实「—」)。
    var usage: ClaudeUsageSnapshot?
    let range: AgentUsageRange
    let isCompact: Bool

    var body: some View {
        let spacing: CGFloat = isCompact ? 8 : 16
        if isCompact {
            VStack(spacing: spacing) {
                EqualHeightRow(spacing: spacing) {
                    todayCard
                    windowCard
                }
                EqualHeightRow(spacing: spacing) {
                    averageCard
                    claudeCard
                }
            }
        } else {
            EqualHeightRow(spacing: spacing) {
                todayCard
                windowCard
                averageCard
                claudeCard
            }
        }
    }

    // MARK: 四张卡

    private var todayCard: some View {
        statCard("今日消耗", figure: agentTokenFigure(figures.todayTotal)) {
            AgentUsageTodayDelta(delta: figures.todayDelta)
        }
    }

    private var windowCard: some View {
        statCard("\(figures.windowDays) 天合计", figure: agentTokenFigure(figures.windowTotal)) {
            AgentDeltaText(label: range.previousLabel, delta: figures.windowDelta)
        }
    }

    private var averageCard: some View {
        statCard("日均(\(figures.windowDays) 天)", figure: agentTokenFigure(figures.windowAverage)) {
            subline("峰值 \(agentTokenText(figures.windowPeak))/天")
        }
    }

    /// 5 小时窗优先,缺失退本周;两窗全缺如实「—」,不伪造。
    private var claudeCard: some View {
        let window = usage?.fiveHour ?? usage?.sevenDay
        return statCard(
            "Claude 用量",
            figure: window.map { ("\($0.usedPercentage)", "%") } ?? ("—", "")
        ) {
            subline(usageSubline)
        }
    }

    // MARK: 零件

    /// 小卡外壳:内容 → 撑宽 → 内距 → 弹性高 → 底色。弹性高必须在底色里面,
    /// `EqualHeightRow` 把行高提进来时矮卡的底色才铺得到行底(agent-tab/14)。
    private func statCard(
        _ label: String,
        figure: (value: String, unit: String),
        @ViewBuilder sub: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            FigureText(
                value: figure.value,
                unit: figure.unit,
                size: isCompact ? FigureSize.overviewCompact : FigureSize.card
            )
            sub()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CardMetrics.padding(compact: isCompact))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Surface.card, in: .rect(cornerRadius: CardMetrics.cornerRadius(compact: isCompact)))
        .accessibilityElement(children: .combine)
    }

    private func subline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
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

/// 今日环比:按全天等效量比昨天,不是「实际值比实际值」——悬停说明讲清楚。
struct AgentUsageTodayDelta: View {
    let delta: Double?

    var body: some View {
        AgentDeltaText(label: "较昨日", delta: delta)
            .help("今天还没过完:按已过的时间折算成全天进度后再和昨天比(不足 6 小时按 6 小时算)。大数字是实际用量")
    }
}
