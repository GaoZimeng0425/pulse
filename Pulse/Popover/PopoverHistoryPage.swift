import AppKit
import PulseCore
import SwiftUI

// MARK: - 历史页 AppKit 版(popover-appkit/08)

/// 历史页紧凑档(HistoryTabView isCompact 同值):指标条(`.selectedOnly` + 玻璃)/ 分项条(仅温度、
/// 功率;`.always` + 玻璃)/ 范围条(`.always` + 玻璃,色随指标 / 分项)/ 曲线卡 / 口径脚注,
/// 竖向间距 8。选择态是页面本地会话态(切页重建即复位,与 SwiftUI `@State` 同):默认系统负载 ×
/// 近 1 小时。查询走 `monitor.history.series`(引擎 actor,主线程零 SQL);换选择即取消重查,
/// 驻留期间每 60 秒补一轮;离窗取消,不空转。
@MainActor
final class HistoryPageNSView: FlippedView {
    /// 弹窗内容宽:定宽 360 − 外框内距 14×2。
    private static let pageWidth = PopoverRootView.width - 28

    private let monitor: SystemMonitor
    private var metric: HistoryMetricKey = .systemLoad
    private var range: HistoryRange = .hour1
    private var breakdown: HistoryBreakdown?
    private var series: HistorySeries?
    private var queryTask: Task<Void, Never>?
    private var queriedKey: QueryKey?

    private let metricBar = PillTabBarNSView(textVisibility: .selectedOnly)
    private let breakdownBar = PillTabBarNSView()
    private let rangeBar = PillTabBarNSView()
    private let chartCard = HistoryChartCardNSView(width: HistoryPageNSView.pageWidth)
    private let footnote = makeLabel(font: PFont.text(11), color: Ink.secondary)

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        footnote.maximumNumberOfLines = 0
        footnote.lineBreakMode = .byWordWrapping
        footnote.preferredMaxLayoutWidth = Self.pageWidth
        let stack = vstack([metricBar, breakdownBar, rangeBar, chartCard, footnote], spacing: 8)
        chartCard.fillWidth(of: stack)
        addSubview(stack)
        stack.pin(to: self)

        metricBar.onSelect = { [weak self] index in
            guard let self else { return }
            let next = HistoryMetricKey.allCases[index]
            guard next != metric else { return }
            metric = next
            breakdown = nil // 切主指标清空分项 → 回落该指标默认分项
            refresh()
        }
        breakdownBar.onSelect = { [weak self] index in
            guard let self else { return }
            breakdown = metric.breakdowns[index]
            refresh()
        }
        rangeBar.onSelect = { [weak self] index in
            guard let self else { return }
            range = HistoryRange.allCases[index]
            refresh()
        }
        applySelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: 选择态

    /// 生效分项(无分项的指标为 nil;回落规则与查询层同一条)。
    private var activeBreakdown: HistoryBreakdown? {
        metric.resolvedBreakdown(breakdown)
    }

    /// 页面强调色:有分项随分项,否则随指标。
    private var tint: Color {
        activeBreakdown?.tint ?? metric.accent.accentColor
    }

    private func refresh() {
        applySelection()
        restartQueryIfNeeded()
    }

    private func applySelection() {
        let metrics = HistoryMetricKey.allCases
        metricBar.set(
            items: metrics.map { PillTabItem(title: $0.title, symbol: $0.symbolName, tint: $0.accent.accentColor) },
            selectedIndex: metrics.firstIndex(of: metric) ?? 0
        )
        if let active = activeBreakdown {
            let items = metric.breakdowns
            breakdownBar.set(
                items: items.map { PillTabItem(title: $0.title, tint: $0.tint) },
                selectedIndex: items.firstIndex(of: active) ?? 0
            )
            breakdownBar.isHidden = false
        } else {
            breakdownBar.isHidden = true
        }
        let ranges = HistoryRange.allCases
        let tint = tint
        rangeBar.set(
            items: ranges.map { PillTabItem(title: $0.title, tint: tint) },
            selectedIndex: ranges.firstIndex(of: range) ?? 0
        )
        footnote.setText(activeBreakdown?.caption ?? metric.caption)
        chartCard.set(series: series, metric: metric)
    }

    // MARK: 查询(引擎 actor)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            queryTask?.cancel()
            queryTask = nil
            queriedKey = nil
        } else {
            restartQueryIfNeeded()
        }
    }

    /// 查询键不变不重查(切主指标清空分项前后生效分项相同时即如此)。
    private func restartQueryIfNeeded() {
        guard window != nil else { return }
        let key = QueryKey(metric: metric, breakdown: activeBreakdown, range: range)
        guard key != queriedKey else { return }
        queriedKey = key
        queryTask?.cancel()
        queryTask = Task { @MainActor [weak self] in
            await self?.reload(key)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.reload(key)
            }
        }
    }

    private func reload(_ key: QueryKey) async {
        let result = await monitor.history.series(metric: key.metric, breakdown: key.breakdown, range: key.range)
        guard !Task.isCancelled, key == queriedKey else { return }
        series = result
        chartCard.set(series: result, metric: metric)
    }
}

/// 查询键:换指标、分项或范围才重查。
private struct QueryKey: Equatable {
    let metric: HistoryMetricKey
    let breakdown: HistoryBreakdown?
    let range: HistoryRange
}

// MARK: - 曲线卡

/// 曲线卡(紧凑):统计行(均值 / 峰值:11 secondary 标签 + 17 semibold 圆体等宽数字,列距 20;
/// 右侧 11 tertiary 覆盖计数)/ 160 高曲线;无数据时占位(26 light 符号 / 「暂无数据」title3 /
/// caption 说明,间距 8,竖向内距 32)。卡竖向间距 12。
@MainActor
private final class HistoryChartCardNSView: NSView {
    private let statsRow: NSStackView
    private let averageValue = makeLabel(font: PFont.rounded(17, .semibold))
    private let peakValue = makeLabel(font: PFont.rounded(17, .semibold))
    private let coverage = makeLabel(font: PFont.text(11), color: Ink.tertiary, alignment: .right)
    private let curve = HistoryCurveNSView()
    private let empty: NSStackView
    private let emptyDetail = makeLabel(font: PFont.text(10), color: Ink.tertiary)

    init(width: CGFloat) {
        func statColumn(_ title: String, _ value: NSTextField) -> NSStackView {
            vstack([makeLabel(title, font: PFont.text(11), color: Ink.secondary), value], spacing: 2)
        }
        statsRow = hstack(
            [statColumn("均值", averageValue), statColumn("峰值", peakValue), spacer(), coverage],
            spacing: 20,
            alignment: .top
        )
        let symbol = makeSymbolView("chart.line.uptrend.xyaxis", size: 26, weight: .light, tint: Ink.tertiary)
        let title = makeLabel("暂无数据", font: PFont.text(15), color: Ink.tertiary)
        empty = vstack([symbol, title, emptyDetail], spacing: 8, alignment: .centerX)
        empty.edgeInsets = NSEdgeInsets(top: 32, left: 0, bottom: 32, right: 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        emptyDetail.maximumNumberOfLines = 0
        emptyDetail.lineBreakMode = .byWordWrapping
        // 卡内宽 = 页宽 − 卡内距 12×2。
        emptyDetail.preferredMaxLayoutWidth = width - 2 * CardMetrics.padding(compact: true)
        curve.fixed(height: 160)
        let body = vstack([statsRow, curve, empty], spacing: 12)
        for view in [statsRow, curve, empty] {
            view.fillWidth(of: body)
        }
        let card = CardView(content: body)
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(series: HistorySeries?, metric: HistoryMetricKey) {
        if let series, let stats = series.statistics() {
            statsRow.isHidden = false
            averageValue.setText(metric.statisticText(stats.average))
            peakValue.setText(metric.statisticText(stats.peak))
            let total = series.values.count
            let filled = series.filledCount
            coverage.setText(filled == total ? "全程有记录" : "\(filled)/\(total) 桶有记录")
        } else {
            statsRow.isHidden = true
        }
        if let series, !series.isEmpty {
            curve.isHidden = false
            empty.isHidden = true
            curve.set(series)
        } else {
            curve.isHidden = true
            empty.isHidden = false
            emptyDetail.setText(Self.emptyDetail(metric))
        }
    }

    /// 暂无数据的原因随指标如实说明(HistoryTabView.emptyDetail 同文案)。
    private static func emptyDetail(_ metric: HistoryMetricKey) -> String {
        switch metric {
        case .network, .disk:
            "该时段无吞吐记录(Pulse 未运行或网络/磁盘读数缺席)——历史留空,不补零"
        case .temperature, .gpu, .power, .energy:
            "该时段传感器读数缺席,或 Pulse 未运行——历史留空,不补零"
        case .systemLoad, .cpu, .memory:
            "所选时间段内 Pulse 未运行——历史留空,不补零"
        }
    }
}

// MARK: - 历史曲线

/// 历史曲线(HistoryCurveView 同几何):轨道 tint 9% 圆角 8;桶中心取 x、上下留白 8;
/// 线 2px 圆头圆角,空桶断线不跨缺,单点段落一个 2px 点。系统负载固定 0–100 域,其余按窗口最大值。
@MainActor
private final class HistoryCurveNSView: FlippedView {
    private static let verticalInset: CGFloat = 8
    private static let lineWidth: CGFloat = 2

    private var series: HistorySeries?

    func set(_ series: HistorySeries) {
        guard series != self.series else { return }
        self.series = series
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let series else { return }
        let tint = series.tint.ns
        tint.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let count = series.values.count
        guard count > 1 else { return }
        let normalizer = series.metric == .systemLoad ? 100.0 : max(series.values.compactMap(\.self).max() ?? 0, 1)
        let size = bounds.size
        let drawableHeight = size.height - Self.verticalInset * 2
        func point(_ index: Int, _ value: Double) -> NSPoint {
            let fraction = CGFloat(min(max(value / normalizer, 0), 1))
            return NSPoint(
                x: (CGFloat(index) + 0.5) * size.width / CGFloat(count),
                y: Self.verticalInset + (1 - fraction) * drawableHeight
            )
        }

        tint.set()
        var run: [(Int, Double)] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard let first = run.first else { return }
            if run.count == 1 {
                let center = point(first.0, first.1)
                let radius = Self.lineWidth / 2
                NSBezierPath(ovalIn: NSRect(
                    x: center.x - radius, y: center.y - radius,
                    width: Self.lineWidth, height: Self.lineWidth
                )).fill()
                return
            }
            let path = NSBezierPath()
            path.move(to: point(first.0, first.1))
            for (index, value) in run.dropFirst() {
                path.line(to: point(index, value))
            }
            path.lineWidth = Self.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        for (index, value) in series.values.enumerated() {
            if let value {
                run.append((index, value))
            } else {
                flush() // 缺口:当前段收笔,下一段另起
            }
        }
        flush()
    }
}
