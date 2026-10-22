import PulseCore
import SwiftUI

// MARK: - 历史页(工单 04):指标 × 时间范围 Canvas 走势

// 取数口径(表档/列/聚合/空段)全在 HistoryQueries.swift,本文件只消费
// HistorySeries——查询经 monitor.history.series 走引擎 actor(UI 线程零 SQL,
// spec User Story 10);UI 不单测,预览 + 真机验收(spec 既定)。

extension HistoryMetricKey {
    /// 药丸 tab 图标(视图层映射):CPU/内存/网络/磁盘与主窗口 tab 同符号,
    /// 系统负载取仪表盘——两者同为 CPU 蓝(accent 同源),靠符号区分身份
    /// (与工具栏"总览/CPU 同蓝不同符"同一手法)。
    var symbolName: String {
        switch self {
        case .systemLoad: "gauge.with.needle"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "network"
        case .disk: "internaldrive"
        }
    }
}

/// 历史页:选指标(系统负载/CPU/内存/网络/磁盘)× 选范围(近 1 小时/24 小时/
/// 7 天/30 天)看走势,切换用与主窗口工具栏同一款药丸 tab(用户拍板
/// 2026-10-22:tab 是通用组件样式,`PillTabBar`)。app 未运行的时段曲线留缺
/// 不补零(User Story 8);网络/磁盘的记录列要等工单 06 接入,此前如实显示
/// "暂无数据"不伪造。
struct HistoryTabView: View {
    let monitor: SystemMonitor
    /// 弹窗紧凑档(2026-10-20 起弹窗也有历史页):指标条未选中纯图标、
    /// 选中才展开文字,360pt 里放得下;曲线 160 高、卡 {rounded.card-compact} 12
    /// + {spacing.card-padding-compact} 12。
    var isCompact = false

    /// 选择态:页面本地会话态,默认系统负载 × 近 1 小时(最常用的排障起点)。
    @State private var metric: HistoryMetricKey = .systemLoad
    @State private var range: HistoryRange = .hour1
    /// 当前曲线(nil = 尚未查到 / 库不可用):按占位处理,不区分原因(旁路语义)。
    @State private var series: HistorySeries?

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
            // 指标条 = 工具栏同形态(未选中纯图标、选中展开文字):五项各有
            // 指标色与符号,与主窗口 tab 一眼同族。
            PillTabBar(
                HistoryMetricKey.allCases, selection: $metric, textVisibility: .selectedOnly
            ) { key in
                PillTabItem(title: key.title, symbol: key.symbolName, tint: key.accent.accentColor)
            }
            // 范围条:文字恒显(四项短文案无宽度竞争),色调跟随所选指标——
            // 与曲线、统计数字同族,整页一个颜色故事。
            PillTabBar(HistoryRange.allCases, selection: $range) { span in
                PillTabItem(title: span.title, tint: metric.accent.accentColor)
            }

            chartCard

            // 口径脚注(GLOSSARY 双口径 / 占位语义的展示出口,工单 04 票面既定)。
            Text(metric.caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        // 换指标/换范围即重查;驻留本页期间每分钟补一轮(分钟表一分钟长一行,
        // "近 1 小时"要能往前走)。查询在引擎 actor,取消即停,离页不空转。
        .task(id: QueryKey(metric: metric, range: range)) {
            await reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await reload()
            }
        }
    }

    /// 重查当前选择(最新时刻取窗)。
    private func reload() async {
        series = await monitor.history.series(metric: metric, range: range)
    }

    /// 曲线卡:统计行(仅非空桶)+ Canvas 走势 / "暂无数据"占位。
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let series, let stats = series.statistics() {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    statPoint("均值", metric.statisticText(stats.average))
                    statPoint("峰值", metric.statisticText(stats.peak))
                    Spacer()
                    Text(coverageText(series))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if let series, !series.isEmpty {
                HistoryCurveView(series: series)
                    .frame(height: isCompact ? 160 : 220)
            } else {
                emptyState
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 统计点(与指标卡统计行同族:小标签 + 圆体数字)。
    private func statPoint(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    /// 数据覆盖(诚实计数):有数据的桶 / 网格总桶数。
    private func coverageText(_ series: HistorySeries) -> String {
        let total = series.values.count
        let filled = series.filledCount
        return filled == total ? "全程有记录" : "\(filled)/\(total) 桶有记录"
    }

    /// 暂无数据占位:原因随指标如实说明——网络/磁盘是记录未接入(工单 06),
    /// 其余是所选时段 Pulse 未运行(留空不补零)。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("暂无数据")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isCompact ? 32 : 64)
    }

    private var emptyDetail: String {
        switch metric {
        case .network, .disk:
            return "吞吐记录尚未接入(工单 06),接入后这里自动出现曲线"
        case .systemLoad, .cpu, .memory:
            return "所选时间段内 Pulse 未运行——历史留空,不补零"
        }
    }
}

/// 查询键:task(id:) 的重启条件(换指标或换范围)。
private struct QueryKey: Equatable {
    let metric: HistoryMetricKey
    let range: HistoryRange
}

// MARK: - 历史曲线(Canvas)

/// 历史曲线:固定桶网格上的折线,空桶断线、段间不跨缺连线(留缺不补零,
/// spec User Story 8;分段口径与 HistorySeries.segments 同源)。样式与
/// StripChartView 同族——同一份 MetricAccent 强调色令牌、同一 9% 轨道底、
/// 圆角画法;无轴无标签,数值由统计行文字承载(P0.6 同决策)。
/// 归一化:系统负载固定 0–100 语义域(菜单栏同口径),其余按窗口内最大值。
struct HistoryCurveView: View {
    let series: HistorySeries

    /// 折线上下的留白(线不贴轨道边)。
    private static let verticalInset: CGFloat = 8
    private static let lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        // 轨道:强调色 9%(与 StripChartView 的 §1.1 color-mix 口径一致)。
        .background(
            series.metric.accent.accentColor.opacity(0.09),
            in: .rect(cornerRadius: 8)
        )
        .accessibilityHidden(true) // 数值信息由统计行的文字承载
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let count = series.values.count
        guard count > 1 else { return }
        let filled = series.values.compactMap(\.self)
        let normalizer =
            series.metric == .systemLoad
                ? 100.0
                : max(filled.max() ?? 0, 1)
        let drawableHeight = size.height - Self.verticalInset * 2

        // 桶中心取 x(首尾桶的半桶让出边缘,窗界读数不裁半)。
        func point(_ index: Int, _ value: Double) -> CGPoint {
            let fraction = CGFloat(min(max(value / normalizer, 0), 1))
            return CGPoint(
                x: (CGFloat(index) + 0.5) * size.width / CGFloat(count),
                y: Self.verticalInset + (1 - fraction) * drawableHeight
            )
        }

        let tint = series.metric.accent.accentColor
        var run: [(index: Int, value: Double)] = []

        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard let first = run.first else { return }
            if run.count == 1 {
                // 单点段:圆头线在此退化为零长路径,显式落一个点。
                let center = point(first.index, first.value)
                let radius = Self.lineWidth / 2
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: Self.lineWidth, height: Self.lineWidth
                    )),
                    with: .color(tint)
                )
                return
            }
            var path = Path()
            path.move(to: point(first.index, first.value))
            for (index, value) in run.dropFirst() {
                path.addLine(to: point(index, value))
            }
            context.stroke(
                path,
                with: .color(tint),
                style: StrokeStyle(
                    lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round
                )
            )
        }

        for (index, value) in series.values.enumerated() {
            if let value {
                run.append((index, value))
            } else {
                flush() // 缺口:当前段收笔,下一段另起(不跨缺连线)
            }
        }
        flush()
    }
}

// MARK: - 预览(内存库夹具,spec 测试决策:UI 以预览 + 真机验收)

#Preview("历史页:分钟 3 小时(带缺口)+ 小时 3 天") {
    // 预览夹具:失败即崩是期望行为
    // swiftlint:disable:next force_try
    let queue = try! HistoryDatabase.openInMemory()
    let now = Int(Date().timeIntervalSince1970)
    let hourStart = now / 3600 * 3600
    // swiftlint:disable:next force_try
    try! queue.write { db in
        // 分钟表:最近 3 小时,每 17 分钟缺一行(app 未运行的时段示意);
        // 系统负载锯齿 + 两个组(CPU 求和口径、内存合计口径都有形)。
        for minute in 0 ..< 180 where minute % 17 != 0 {
            let ts = hourStart - (180 - minute) * 60
            let load = 18.0 + Double((minute * 37) % 64)
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (?, ?, ?)",
                arguments: [ts, load, load]
            )
            try db.execute(
                sql: """
                INSERT INTO sample_min (ts, group_id, cpu_avg, cpu_max, mem_max, procs)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [ts, "app:Zed", load * 0.6, load, 1_400_000_000, 3]
            )
            try db.execute(
                sql: """
                INSERT INTO sample_min (ts, group_id, cpu_avg, cpu_max, mem_max, procs)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [ts, "app:Chrome", 22, 22, 900_000_000, 21]
            )
        }
        // 小时表:最近 3 天,留两小时缺口(远期趋势形态)。
        for hour in 0 ..< 72 where hour % 29 != 0 {
            let ts = hourStart - (72 - hour) * 3600
            let load = 30.0 + Double((hour * 53) % 45)
            try db.execute(
                sql: "INSERT INTO system_hour (ts, load_avg, load_max) VALUES (?, ?, ?)",
                arguments: [ts, load, load]
            )
        }
    }
    let monitor = SystemMonitor.preview(historyEngine: HistoryEngine(database: queue))
    return HistoryTabView(monitor: monitor)
        .padding(24)
        .frame(width: 680)
        .containerBackground(Surface.window, for: .window)
}
