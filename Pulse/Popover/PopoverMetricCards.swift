import AppKit
import PulseCore

// MARK: - 指标卡 AppKit 版(popover-appkit/02 总览小卡 + 04 主卡紧凑档)

/// 指标 tab 主卡紧凑档(MetricMainCardView.compactBody 同值):数字行(caption 11 secondary
/// + 30pt 大数字,右侧状态 chip 底对齐)/ 64pt 面积走势 / 统计等分一行(间距 6);
/// 竖向间距 10,卡内距 12。7 个指标模型同组件。
@MainActor
final class MetricMainCardNSView: ObservingView {
    private let modelProvider: @MainActor () -> MetricCardModel
    private let caption = makeLabel(font: PFont.text(11), color: Ink.secondary)
    private let figure = FigureView(size: FigureSize.mainCompact)
    private let chip = ChipView()
    private let chart = AreaTrendChartNSView()
    private let statsRow = hstack([], spacing: 6, alignment: .top)
    private var statViews: [StatValueView] = []

    init(model: @escaping @MainActor () -> MetricCardModel) {
        modelProvider = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        statsRow.distribution = .fillEqually
        chart.fixed(height: 64)
        let figureColumn = vstack([caption, figure], spacing: 4)
        let topRow = hstack([figureColumn, spacer(), chip], spacing: 8, alignment: .bottom)
        let body = vstack([topRow, chart, statsRow], spacing: 10)
        for view in [topRow, chart, statsRow] {
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

    override func update() {
        let model = modelProvider()
        caption.setText(model.caption)
        figure.set(value: model.figureValue, unit: model.figureUnit)
        chip.isHidden = model.chip == nil
        if let value = model.chip {
            chip.set(value)
        }
        chart.set(values: model.trend, tint: model.tint.ns, domainMax: model.domainMax)
        setStats(model.stats)
    }

    private func setStats(_ stats: [MetricCardStat]) {
        if statViews.count != stats.count {
            statViews.forEach { $0.removeFromSuperview() }
            statViews = stats.map { _ in StatValueView() }
            statViews.forEach(statsRow.addArrangedSubview)
        }
        for (view, stat) in zip(statViews, stats) {
            view.set(stat)
        }
    }
}

/// 总览紧凑小卡(MetricCardView.compactBody 同值):副卡头 / 22pt 大数字 + 右侧注记
/// (10.5 secondary)/ 36pt 44 柱 strip;竖向间距 6,卡内距 12。整卡可点跳对应 tab。
@MainActor
final class OverviewMetricCardNSView: ObservingView {
    private let modelProvider: @MainActor () -> MetricCardModel
    private let header: CardSubHeaderView
    private let figure = FigureView(size: FigureSize.overviewCompact)
    private let note = makeLabel(font: PFont.text(10.5), color: Ink.secondary, alignment: .right)
    private let chart = StripChartNSView()

    init(model: @escaping @MainActor () -> MetricCardModel, onOpen: @escaping () -> Void) {
        modelProvider = model
        let initial = model()
        header = CardSubHeaderView(symbolName: initial.symbolName, title: initial.title, tint: initial.tint.ns)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        chart.fixed(height: 36)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let figureRow = hstack([figure, spacer(minLength: 4), note], spacing: 2, alignment: .firstBaseline)
        let body = vstack([header, figureRow, chart], spacing: 6)
        for view in [header, figureRow, chart] {
            view.fillWidth(of: body)
        }
        let card = ClickableCardView(content: body)
        card.onClick = onOpen
        addSubview(card)
        card.pin(to: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(initial.title)
        setAccessibilityHelp("打开\(initial.title)详情")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let model = modelProvider()
        figure.set(value: model.figureValue, unit: model.figureUnit)
        note.setText(model.note)
        chart.set(values: model.trend, tint: model.tint.ns, domainMax: model.domainMax)
    }
}
