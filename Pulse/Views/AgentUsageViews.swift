import PulseCore
import SwiftUI

// MARK: - 每日消耗卡(agent-tab/02)

//
// Claude + ZCode 两家按天 token 合计的折线(7/30 天切换)与 GitHub 贡献图式
// 热力图(近 13 周)。数据 = AgentUsageFeature 的账本行(自落库,不受源删除
// 影响);「重新扫描」= 手动全量档(补漏天)。配色一律本页指标色(蓝牙青),
// 不开阈值变色第四处;图表无轴无标签,数值由文字行承载(StripChartView 同决策)。

/// 每日消耗卡。
struct AgentUsageCardView: View {
    /// 账本全表(按天升序);空 = 还没扫过。
    let rows: [AgentDailyUsageRow]
    /// 项目轨全表(agent-tab/04);窗口内聚合出项目排行。
    var projectRows: [AgentProjectUsageRow] = []
    /// 弹窗紧凑档。
    var isCompact = false
    /// 全量扫描进行中(按钮转圈与禁用重入)。
    var isScanning = false
    /// 「重新扫描」动作(UI 按钮的唯一触发源)。
    var onRescan: () -> Void

    /// 折线范围切换。
    private enum Range: Hashable {
        case week
        case month

        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            }
        }

        var title: String {
            switch self {
            case .week: "7 天"
            case .month: "30 天"
            }
        }
    }

    @State private var range: Range = .week

    /// 热力图:13 周(列 = 连续 7 天一组,顺序铺格,最新在右下)。
    private static let heatmapWeeks = 13
    private static let heatmapCellSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "chart.line.uptrend.xyaxis", title: "每日消耗", tint: agentsAccent) {
                rescanButton
            }
            if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    PillTabBar([Range.week, .month], selection: $range) { item in
                        PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
                    }
                    lineChart
                    summaryRow
                    projectRank
                    heatmap
                    Text("近 \(Self.heatmapWeeks) 周 · Claude 与 ZCode 合计")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 重新扫描按钮:扫描中转圈禁用(全量档后台跑,完成即刷新账本)。
    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            if isScanning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("扫描中")
                }
            } else {
                Text("重新扫描")
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(isScanning)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isScanning {
            CardEmptyState(
                title: "正在扫描本地记录",
                detail: "正在从 Claude 与 ZCode 的会话记录回填每日消耗"
            )
        } else {
            CardEmptyState(
                title: "还没有每日数据",
                detail: "点「重新扫描」,从 Claude 与 ZCode 的本地记录回填历史"
            )
        }
    }

    // MARK: 折线

    /// 近 N 天合计折线(缺数据天画 0——账本无行即当日无记录,不猜)。轨道与
    /// 画法与 HistoryCurveView 同族(9% 底、2pt 圆头线、窗口最大值归一)。
    private var lineChart: some View {
        let values = recentDayTotals(days: range.days).map(\.total)
        return Canvas { context, size in
            drawLine(values, in: &context, size: size)
        }
        .frame(height: isCompact ? 44 : 64)
        .background(agentsAccent.opacity(0.09), in: .rect(cornerRadius: 8))
        .accessibilityHidden(true) // 数值由下方文字行承载
    }

    private func drawLine(_ values: [Double], in context: inout GraphicsContext, size: CGSize) {
        let count = values.count
        guard count > 1 else {
            // 单点:落一个点(HistoryCurveView 单点段同款)。
            if let only = values.first, only > 0 {
                let radius: CGFloat = 1
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: size.width / 2 - radius,
                        y: size.height / 2 - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(agentsAccent)
                )
            }
            return
        }
        let inset: CGFloat = 6
        let drawableHeight = size.height - inset * 2
        let normalizer = max(values.max() ?? 0, 1)

        func point(_ index: Int) -> CGPoint {
            CGPoint(
                x: (CGFloat(index) + 0.5) * size.width / CGFloat(count),
                y: inset + (1 - CGFloat(min(max(values[index] / normalizer, 0), 1))) * drawableHeight
            )
        }

        var path = Path()
        path.move(to: point(0))
        for index in 1 ..< count {
            path.addLine(to: point(index))
        }
        context.stroke(
            path,
            with: .color(agentsAccent),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    /// 区间摘要:近 N 天合计 · 日均。
    private var summaryRow: some View {
        let totals = recentDayTotals(days: range.days)
        let sum = totals.reduce(0) { $0 + $1.total }
        let average = sum / Double(max(totals.count, 1))
        return Text("近 \(range.days) 天合计 \(agentTokenText(Int(sum))) · 日均 \(agentTokenText(Int(average)))")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    // MARK: 项目排行(agent-tab/04)

    /// 近 N 天项目排行:两家合计、按量降序、封顶 8 行(超出补「另 N 项」);
    /// worktree 消耗已归组主仓名。无项目数据(只有 cache 回填的日子)整节不画。
    @ViewBuilder
    private var projectRank: some View {
        let ranked = projectTotals(days: range.days)
        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                ForEach(Array(ranked.prefix(8)), id: \.project) { item in
                    CardEntityRow(
                        systemImage: "folder",
                        tint: agentsAccent,
                        name: item.project,
                        sub: nil,
                        compact: isCompact
                    ) {
                        Text(agentTokenText(Int(item.total)))
                            .font(.system(size: RowMetrics.valueFontSize(compact: isCompact), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if ranked.count > 8 {
                    Text("另 \(ranked.count - 8) 个项目")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 窗口内项目合计(两家合并),按量降序。
    private func projectTotals(days: Int) -> [(project: String, total: Double)] {
        let keys = windowDayKeys(days: days)
        var totals: [String: Double] = [:]
        for row in projectRows where keys.contains(row.day) && row.totalTokens > 0 {
            totals[row.project, default: 0] += Double(row.totalTokens)
        }
        return totals
            .map { (project: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// 近 N 天(含今天)的日键集合(与 recentDayTotals 同法生成)。
    private func windowDayKeys(days: Int) -> Set<String> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return Set((0 ..< days).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { Self.dayKey($0, calendar: calendar) }
        })
    }

    // MARK: 热力图

    /// 近 13 周格子墙:当天量按窗口最大值分四档着色(GitHub 贡献图式),
    /// 无数据格 = 卡内抬升底;顺序铺格(列 = 连续 7 天),最新在右下。
    private var heatmap: some View {
        let totals = recentDayTotals(days: Self.heatmapWeeks * 7)
        return Canvas { context, size in
            drawHeatmap(totals, in: &context, size: size)
        }
        .frame(height: 84)
        .accessibilityHidden(true) // 数值由折线区摘要行承载
    }

    private func drawHeatmap(
        _ totals: [DayTotal],
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let weeks = Self.heatmapWeeks
        let spacing = Self.heatmapCellSpacing
        let cellSide = min(
            (size.width - spacing * CGFloat(weeks - 1)) / CGFloat(weeks),
            (size.height - spacing * 6) / 7
        )
        let maxValue = totals.map(\.total).max() ?? 0

        for (index, day) in totals.enumerated() {
            let column = index / 7
            let row = index % 7
            let rect = CGRect(
                x: CGFloat(column) * (cellSide + spacing),
                y: CGFloat(row) * (cellSide + spacing),
                width: cellSide,
                height: cellSide
            )
            let corner = min(2.5, cellSide / 3)
            let color: Color
            if day.total <= 0 || maxValue <= 0 {
                color = Surface.cardHigh
            } else {
                // 四档着色:1/4 → 1.0 透明度。
                let level = min(4, Int(ceil(day.total / maxValue * 4)))
                let opacity: Double = [0, 0.25, 0.5, 0.75, 1][level]
                color = agentsAccent.opacity(opacity)
            }
            context.fill(Path(roundedRect: rect, cornerRadius: corner), with: .color(color))
        }
    }

    // MARK: 数据成形

    /// 近 `days` 天(含今天)的逐天合计,旧 → 新;账本无行的天 = 0。
    private func recentDayTotals(days: Int) -> [DayTotal] {
        let calendar = Calendar.current
        var byDay: [String: Double] = [:]
        for row in rows where row.totalTokens > 0 {
            byDay[row.day, default: 0] += Double(row.totalTokens)
        }
        let today = calendar.startOfDay(for: Date())
        return (0 ..< days).reversed().map { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return DayTotal(day: "", total: 0)
            }
            let key = Self.dayKey(date, calendar: calendar)
            return DayTotal(day: key, total: byDay[key] ?? 0)
        }
    }

    /// 毫秒免 DateFormatter(线程安全;与账本行同格式)。
    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private struct DayTotal {
        var day: String
        var total: Double
    }
}

#Preview("每日消耗") {
    func row(_ day: String, source: AgentUsageSource, total: Int) -> AgentDailyUsageRow {
        AgentDailyUsageRow(day: day, source: source, origin: .jsonl, totalTokens: total)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())

    func back(_ days: Int) -> String {
        formatter.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date())!)
    }

    var rows: [AgentDailyUsageRow] = []
    for offset in 0 ..< 91 {
        let base = Double(91 - offset) / 91
        let wave = 0.4 + 0.6 * abs(sin(Double(offset) / 5))
        let total = Int(base * wave * 800_000_000)
        rows.append(row(back(offset), source: .claude, total: total))
        rows.append(row(back(offset), source: .zcode, total: total / 3))
    }
    rows.append(row(today, source: .claude, total: 320_000_000))
    rows.append(row(today, source: .zcode, total: 64_000_000))

    return VStack(spacing: 16) {
        AgentUsageCardView(rows: rows, isScanning: false, onRescan: {})
        AgentUsageCardView(rows: [], isScanning: true, onRescan: {})
        AgentUsageCardView(rows: [], isScanning: false, onRescan: {})
    }
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
