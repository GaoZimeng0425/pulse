import Charts
import PulseCore
import SwiftUI

// MARK: - 消耗子页(agent-tab/06,定稿骨架 wireframe-agents-page.html)

//
// 「每日消耗」外壳拆掉、四块平级成卡(用户拍板):数字卡排(四张一排,含
// Claude 用量)→ 日历图 + 走势(≥1280 窗宽两列,否则一列;07)→ 项目宽卡
// (媒体查询列数)。range(7/30)子页内共享,数字卡排随档位联动;「重新扫描」
// 在日历图卡头(全量档手动触发,补漏天)。项目卡对齐 tokscale 参数:四桶 +
// 缓存倍率 + 会话数(Cost / 精确 Last Active 用户点名不做)。数据派生全走
// PulseCore `AgentUsageWindow`(纯值,UI 只描不算)。

/// 消耗子页(智能体页三子 tab 之一)。
struct AgentUsagePaneView: View {
    /// 账本全表(按天升序);空 = 还没扫过。
    let rows: [AgentDailyUsageRow]
    var projectRows: [AgentProjectUsageRow] = []
    var modelRows: [AgentModelUsageRow] = []
    /// 项目现存会话数(agent-tab/06,扫描现数)。
    var sessionCounts: [String: Int] = [:]
    /// Claude 用量快照(数字卡排第 4 张;两窗全缺如实「—」)。
    var usage: ClaudeUsageSnapshot?
    /// 会话快照的项目在跑数(组装时传入)。
    var liveProjectCounts: [String: Int] = [:]
    /// 弹窗紧凑档。
    var isCompact = false
    /// 全量扫描进行中(按钮转圈与禁用重入)。
    var isScanning = false
    /// 「重新扫描」动作(日历图卡头按钮的唯一触发源)。
    var onRescan: () -> Void

    /// 项目默认展示上限(超出走展开/收起;用户拍板 2026-11-14)。
    private static let projectLimit = 10

    /// 走势 / 项目的范围切换(数字卡排随档位联动)。
    enum Range: Hashable {
        case week
        case month

        var days: Int {
            self == .week ? 7 : 30
        }

        var title: String {
            self == .week ? "7 天" : "30 天"
        }

        /// 合计卡环比基准的称谓(7 天比上周、30 天比上月)。
        var previousLabel: String {
            self == .week ? "较上周" : "较上月"
        }
    }

    /// 日历图「年」占位单选项(时间筛选位置恒定;档位切换是未来功能)。
    enum HeatSpan: Hashable {
        case year
    }

    @State private var range: Range = .week
    /// 项目超过上限时的展开态(切 7/30 保持;重进子页回默认收起)。
    @State private var projectsExpanded = false
    /// 日历图 + 走势列数(按子页内容宽 ≥ `chartTwoColumnMinWidth` 判定)。
    @State private var chartColumns = 1

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 16) {
                numberCard
                chartRow
                projectCard
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isScanning {
            CardEmptyState(
                title: "正在扫描本地记录",
                detail: "正在从 Claude 与 ZCode 的会话记录回填每日消耗"
            )
            .cardShell(compact: isCompact)
        } else {
            CardEmptyState(
                title: "还没有每日数据",
                detail: "点「重新扫描」,从 Claude 与 ZCode 的本地记录回填历史"
            )
            .cardShell(compact: isCompact)
        }
    }

    // MARK: 卡 1:数字卡排(四张一排)

    private var numberCard: some View {
        let figures = AgentUsageWindow.figures(rows: rows, days: range.days)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "消耗总览", tint: agentsAccent) {
                EmptyView()
            }
            HStack(alignment: .top, spacing: 8) {
                numberCell(
                    label: "今日消耗",
                    tokens: figures.todayTotal,
                    valueTint: agentsAccent
                ) {
                    AgentDeltaText(label: "较昨日", delta: figures.todayDelta)
                }
                numberCell(
                    label: "\(figures.windowDays) 天合计",
                    tokens: figures.windowTotal
                ) {
                    AgentDeltaText(label: range.previousLabel, delta: figures.windowDelta)
                }
                numberCell(
                    label: "日均(\(figures.windowDays) 天)",
                    tokens: figures.windowAverage
                ) {
                    Text("峰 \(agentTokenText(figures.windowPeak))/天")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                usageCell
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 一张 lift 数字小卡:标签 → 大数字(figure-stat 28)→ 副行;等宽分布。
    private func numberCell(
        label: String,
        tokens: Int,
        valueTint: Color? = nil,
        @ViewBuilder sub: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            let figure = agentTokenFigure(tokens)
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.stat)
                .foregroundStyle(valueTint ?? Color.primary)
                .minimumScaleFactor(0.5) // 弹窗紧凑档四等分,超宽读数兜底
            sub()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        .frame(maxHeight: .infinity, alignment: .top) // 同行四卡等高(2026-11-13 用户拍板)
        .accessibilityElement(children: .combine)
    }

    /// 第 4 张 = Claude 用量(5 小时窗优先,缺失退本周;快照缺失「—」不伪造)。
    private var usageCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Claude 用量")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if let window = usage?.fiveHour ?? usage?.sevenDay {
                FigureText(value: "\(window.usedPercentage)", unit: "%", size: FigureSize.stat)
                    .foregroundStyle(Color.primary)
                    .minimumScaleFactor(0.5)
                Text(usageSubline)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            } else {
                FigureText(value: "—", unit: "", size: FigureSize.stat)
                    .foregroundStyle(Color.primary)
                Text("未读到快照")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    /// 用量副行:本周占用 + 窗口重置(读得到的才写)。
    private var usageSubline: String {
        var parts: [String] = []
        if let week = usage?.sevenDay {
            parts.append("本周 \(week.usedPercentage)%")
        }
        if let resetsIn = usage?.fiveHour?.resetsAt.map(\.timeIntervalSinceNow),
           resetsIn > 0 {
            parts.append("重置 \(PulseFormat.duration(seconds: resetsIn))后")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 卡 2/3:日历图 + 走势(≥1280 窗宽一排两列,否则一列)

    /// 双列断点(agent-tab/07,2026-11-14 用户拍板「1280 变为一列」):子页内容宽
    /// ≥ 1232(= 窗宽 1280 − 两侧 `{spacing.window-padding}` 24)才并排,否则
    /// 上下一列。06 的 `ViewThatFits` 按子视图理想宽判定,而热力墙 / Charts 都是
    /// 弹性宽、理想宽不可预期——何时切换不可控,是「别扭」的来源之一。弹窗恒一列。
    static let chartTwoColumnMinWidth: CGFloat = 1232
    /// 单列时走势定高(`{layout.agent-trend-height}`;弹窗紧凑档 120)。
    private var trendHeight: CGFloat {
        isCompact ? 120 : 180
    }

    private var chartRow: some View {
        Group {
            if chartColumns == 2 {
                // 并排两卡等高(用户拍板 2026-11-13):fixedSize 先量两卡理想高取大者,
                // 再按该高回传——热力墙卡被拉高、页脚压底,走势图弹性吃满。
                HStack(alignment: .top, spacing: 16) {
                    heatCard
                        .frame(maxHeight: .infinity, alignment: .top)
                    trendCard(height: nil)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    heatCard
                    trendCard(height: trendHeight)
                }
            }
        }
        .onGeometryChange(for: Int.self) { proxy in
            !isCompact && proxy.size.width >= Self.chartTwoColumnMinWidth ? 2 : 1
        } action: { newValue in
            if newValue != chartColumns {
                chartColumns = newValue
            }
        }
    }

    /// 7/30 时间筛选药丸(走势与项目各一份,同一 state 视觉同步)。
    private var rangePills: some View {
        PillTabBar([Range.week, .month], selection: $range) { item in
            PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
        }
    }

    private var heatCard: some View {
        let totals = AgentUsageWindow.dayTotals(rows: rows, days: AgentHeatWall.weeks * 7)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "Token 消耗", tint: agentsAccent) {
                HStack(spacing: 12) {
                    rescanButton
                    PillTabBar([HeatSpan.year], selection: .constant(HeatSpan.year)) { span in
                        PillTabItem(title: span == .year ? "年" : "", symbol: nil, tint: agentsAccent)
                    }
                }
            }
            AgentHeatWall(totals: totals)
            Spacer(minLength: 0) // 并排被拉高时页脚压底;单列无效
            HStack {
                Text("Claude 与 ZCode 合计")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("最多一天 \(agentTokenText(totals.map(\.total).max() ?? 0))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 重新扫描 = 卡头文字按钮(07 收编:06 用 `.bordered` 小号系统按钮,与全 app
    /// 卡头动作「borderless 12 semibold secondary」配方不一致——空间地图「在 Finder
    /// 中显示」、垃圾下钻「全选安全项」同款)。扫描中换转圈 + 「扫描中」并禁用。
    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            HStack(spacing: 4) {
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isScanning ? "扫描中" : "重新扫描")
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(isScanning)
        .help("全量重扫 Claude 与 ZCode 的本地记录,补齐漏记的日子")
    }

    private func trendCard(height: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "走势", tint: agentsAccent) {
                rangePills
            }
            AgentTrendChart(
                totals: AgentUsageWindow.dayTotals(rows: rows, days: range.days),
                height: height
            )
        }
        .cardShell(compact: isCompact)
    }

    // MARK: 卡 4:项目(宽卡,媒体查询列数)

    private var projectCard: some View {
        let projects = AgentUsageWindow.projects(
            projectRows: projectRows,
            modelRows: modelRows,
            days: range.days,
            liveCounts: liveProjectCounts,
            sessionCounts: sessionCounts
        )
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "项目", tint: agentsAccent) {
                rangePills
            }
            if projects.isEmpty {
                CardEmptyState(title: "窗口内没有项目数据", detail: "只有粗粒度回填的日子没有项目维度")
            } else {
                // 响应式多列(2026-11-13 三度修正,用户拍板「同行等高 + 宽了出多列」):
                // 列数按容器实宽容纳的最多列(单卡保底 520、上限 3 列),逐行 HStack
                // 排布——行内卡 .frame(maxHeight:.infinity) 等高、末行不满自动满宽;
                // 不用 LazyVGrid(行内不拉齐高度)也不用 GridItem minimum(硬下限,
                // 窄容器溢出裁剪,前案实锤),容器多窄单列都 100% 宽。
                // 默认前 10 张 + 末行展开/收起(用户拍板 2026-11-14,排行截断同款
                // 交互;上限 = {layout.agent-project-limit})。
                AgentProjectCardGrid(
                    projects: projectsExpanded ? projects : Array(projects.prefix(Self.projectLimit)),
                    windowDays: range.days
                )
                if projects.count > Self.projectLimit {
                    AgentProjectOverflowRow(
                        isExpanded: projectsExpanded,
                        hiddenCount: projects.count - Self.projectLimit
                    ) {
                        projectsExpanded.toggle()
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }
}

// MARK: - 环比文字(数字卡副行与项目卡共用)

/// ▲ +12% / ▼ -8% / 持平 / —(无基准):▲ 绿 ▼ 红,零与无基准灰。
struct AgentDeltaText: View {
    var label: String?
    let delta: Double?

    var body: some View {
        let text: String
        let style: AnyShapeStyle
        if let delta {
            let percent = Int((abs(delta) * 100).rounded())
            if delta > 0 {
                text = arrowLabel("▲", "+\(percent)%")
                style = AnyShapeStyle(Surface.positive)
            } else if delta < 0 {
                text = arrowLabel("▼", "-\(percent)%")
                style = AnyShapeStyle(Surface.negative)
            } else {
                text = "\(label.map { "\($0) " } ?? "")持平"
                style = AnyShapeStyle(.tertiary)
            }
        } else {
            // 前窗无基准:如实「—」,不出 0% 假读数。
            text = "\(label.map { "\($0) " } ?? "")—"
            style = AnyShapeStyle(.tertiary)
        }
        return Text(text)
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(style)
    }

    private func arrowLabel(_ arrow: String, _ value: String) -> String {
        if let label {
            "\(arrow) \(label) \(value)"
        } else {
            "\(arrow) \(value)"
        }
    }
}

#Preview("消耗子页") {
    func row(_ day: String, source: AgentUsageSource, total: Int) -> AgentDailyUsageRow {
        AgentDailyUsageRow(day: day, source: source, origin: .jsonl, totalTokens: total)
    }

    let calendar = Calendar.current
    let now = Date()
    func back(_ days: Int) -> String {
        let date = calendar.date(byAdding: .day, value: -days, to: now)!
        return String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date)
        )
    }

    var rows: [AgentDailyUsageRow] = []
    for offset in 0 ..< 364 {
        let base = Double(364 - offset) / 364
        let wave = 0.4 + 0.6 * abs(sin(Double(offset) / 5))
        let total = Int(base * wave * 800_000_000)
        rows.append(row(back(offset), source: .claude, total: total))
        rows.append(row(back(offset), source: .zcode, total: total / 3))
    }
    rows.append(row(back(0), source: .claude, total: 320_000_000))
    rows.append(row(back(0), source: .zcode, total: 64_000_000))

    var projectRows: [AgentProjectUsageRow] = []
    var modelRows: [AgentModelUsageRow] = []
    let projects: [(String, Int, [String: Int])] = [
        ("pulse", 600, ["claude-opus-5-5": 6, "GLM-5.3": 3, "claude-sonnet-5": 1]),
        ("octok-client", 200, ["claude-opus-5-5": 7, "GLM-5.3": 3]),
        ("NemoNotch", 90, ["claude-sonnet-5": 9]),
        ("sage", 30, ["GLM-5.3": 10]),
    ]
    for (name, weight, models) in projects {
        for offset in 0 ..< 30 where offset % (name == "sage" ? 4 : 2) == 0 {
            let total = weight * 1_000_000 * (offset < 7 ? 1 : 2)
            projectRows.append(
                AgentProjectUsageRow(
                    day: back(offset), source: .claude, project: name,
                    inputTokens: total / 5, outputTokens: total / 10,
                    cacheReadTokens: total / 2, cacheWriteTokens: total / 20,
                    totalTokens: total / 2, requestCount: 40
                )
            )
            projectRows.append(
                AgentProjectUsageRow(
                    day: back(offset), source: .zcode, project: name,
                    inputTokens: total / 10, outputTokens: total / 20,
                    totalTokens: total / 2, requestCount: 20
                )
            )
            for (model, share) in models {
                modelRows.append(
                    AgentModelUsageRow(
                        day: back(offset), source: .claude, project: name, model: model,
                        totalTokens: total / 2 * share / 10
                    )
                )
            }
        }
    }

    return AgentUsagePaneView(
        rows: rows,
        projectRows: projectRows,
        modelRows: modelRows,
        sessionCounts: ["pulse": 291, "octok-client": 142],
        usage: ClaudeUsageSnapshot(
            fiveHour: .init(usedPercentage: 17, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: .init(usedPercentage: 42, resetsAt: nil)
        ),
        liveProjectCounts: ["pulse": 2],
        isScanning: false,
        onRescan: {}
    )
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
