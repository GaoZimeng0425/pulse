import AppKit
import PulseCore
import SwiftUI

// MARK: - 排行列表通用零件 AppKit 版(popover-appkit/03)

//
// 与 RankingList.swift 的 RankingListCard / RankingListRow 一一对应,只取紧凑档:
// 卡内标题(12.5 semibold,所在页指标色)→ 表头「应用 | 指标名」→ 行 → 可选注脚,
// 空态在卡内。度量一律读 `RankingListMetrics`(两处同源:改一处,主窗口与弹窗同改)。
// 组排行(PopoverGroupRanking)与模块排行(PopoverModuleRanking)共用本文件的卡壳与行。

/// 紧凑档常量:全部取自 `RankingListMetrics(compact: true)`,这里只做命名。
@MainActor
enum RankingRowMetrics {
    static let spacing = RankingListMetrics.spacing(compact: true)
    static let iconSize = RankingListMetrics.iconSize(compact: true)
    static let meterWidth = RankingListMetrics.meterWidth(compact: true)
    static let valueFontSize = RankingListMetrics.valueFontSize(compact: true)
    static let valueWidth = RankingListMetrics.valueWidth(compact: true)
    static let trailingWidth = RankingListMetrics.trailingWidth
    static let rowInset = RankingListMetrics.rowInset
    /// 紧凑档行竖向内距(RankingListRow `.padding(.vertical, isCompact ? 5 : 7)`)。
    static let rowVerticalInset: CGFloat = 5
}

// MARK: - 卡壳

/// 排行卡外壳(RankingListCard 紧凑档):竖排间距 2;标题下 `.padding(.bottom, 6)`、
/// 表头下 `.padding(.bottom, 2)`、注脚上 `.padding(.top, 6)` 折成自定义间距。
/// 行容器 `rowsStack` 由调用方填充;空 / 非空切换只改显隐。
@MainActor
final class RankingCardShell: NSView {
    let rowsStack = vstack([], spacing: 2)
    private let titleLabel = makeLabel(font: PFont.text(12.5, .semibold))
    private let headerLeft = makeLabel("应用", font: PFont.text(10.5, .medium), color: Ink.tertiary)
    private let headerRight = makeLabel(font: PFont.text(10.5, .medium), color: Ink.tertiary, alignment: .right)
    private let header: NSStackView
    private let empty = EmptyStateView()
    private let footnoteLabel = makeLabel(font: PFont.text(10.5), color: Ink.tertiary)
    private var currentEmpty: (String, String?)?

    init(title: String) {
        header = hstack([headerLeft, spacer(), headerRight], spacing: 8)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        // 表头右列对齐数值列右缘:越过行尾列(行内距 + 行间距 + 行尾 30)。
        header.edgeInsets = NSEdgeInsets(
            top: 0,
            left: RankingRowMetrics.rowInset,
            bottom: 0,
            right: RankingRowMetrics.rowInset + RankingRowMetrics.spacing + RankingRowMetrics.trailingWidth
        )
        let body = vstack([titleLabel, header, rowsStack, empty, footnoteLabel], spacing: 2)
        body.setCustomSpacing(2 + 6, after: titleLabel)
        body.setCustomSpacing(2 + 2, after: header)
        body.setCustomSpacing(2 + 6, after: rowsStack)
        body.setCustomSpacing(2 + 6, after: empty)
        for view in [header, rowsStack, empty] {
            view.fillWidth(of: body)
        }
        footnoteLabel.isHidden = true
        let card = CardView(content: body)
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setTitle(_ title: String, accent: NSColor) {
        titleLabel.setText(title)
        titleLabel.setColor(accent)
    }

    func setValueLabel(_ text: String) {
        headerRight.setText(text)
    }

    func setFootnote(_ text: String?) {
        footnoteLabel.setText(text ?? "")
        footnoteLabel.isHidden = text == nil
    }

    /// 空 / 非空切换:空时表头与行区隐藏、画卡内空态。
    func setEmpty(_ isEmpty: Bool, message: RankingEmptyMessage) {
        if header.isHidden != isEmpty {
            header.isHidden = isEmpty
            rowsStack.isHidden = isEmpty
        }
        if empty.isHidden == isEmpty {
            empty.isHidden = !isEmpty
        }
        if isEmpty, currentEmpty?.0 != message.title || currentEmpty?.1 != message.detail {
            currentEmpty = (message.title, message.detail)
            empty.set(title: message.title, detail: message.detail)
        }
    }
}

// MARK: - 行

/// 排行行排版(RankingListRow 紧凑档):图标 18 + 名称(12.5 medium,中间省略)/ 副文
/// (10.5 secondary)| 弹性空白(≥8)| meter 52 + 定宽数值列 | 行尾 30pt 列(恒占位)。
/// 只管排版与内容;交互由子类(组排行行)加在外面。
@MainActor
class RankingRowNSView: FlippedView {
    let trailing = FlippedView()
    private let icon = RankingIconView(size: RankingRowMetrics.iconSize)
    private let nameLabel = makeLabel(font: PFont.text(RankingRowMetrics.valueFontSize, .medium))
    private let subtitleLabel = makeLabel(font: PFont.text(10.5), color: Ink.secondary)
    private let meter = MeterBarView(width: RankingRowMetrics.meterWidth)
    private let value = RankingValueView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingMiddle
        for label in [nameLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let textColumn = vstack([nameLabel, subtitleLabel], spacing: 1)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.fixed(width: RankingRowMetrics.trailingWidth, height: 18)
        let row = hstack(
            [icon, textColumn, spacer(minLength: 8), meter, value, trailing],
            spacing: RankingRowMetrics.spacing
        )
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(
            top: RankingRowMetrics.rowVerticalInset,
            left: RankingRowMetrics.rowInset,
            bottom: RankingRowMetrics.rowVerticalInset,
            right: RankingRowMetrics.rowInset
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// 写一行内容:值未变的字段不动(采样轮刷新只改内容,不重建行)。
    func setContent(
        name: String,
        subtitle: String,
        icon iconSource: RankingIconView.Source,
        meterFraction: Double,
        tint: NSColor,
        valueText: String,
        alertsHighLoad: Bool
    ) {
        nameLabel.setText(name)
        subtitleLabel.setText(subtitle)
        icon.source = iconSource
        meter.fraction = meterFraction
        meter.tint = tint
        value.set(text: valueText, alerts: alertsHighLoad)
    }
}

// MARK: - 图标

/// 行图标:App 行取真实应用图标(AppIconCache 预栅格化缓存,与 SwiftUI 行同一取法),
/// 其余取类别瓦片(CategoryIconTile 同配方:圆角 = 边长 × 0.24 的实心方块 + 白符号
/// 边长 × 0.52 semibold)。来源未变不重画。
@MainActor
final class RankingIconView: FlippedView {
    enum Source: Equatable {
        case app(bundlePath: String)
        case tile(symbolName: String, color: Color)
    }

    var source: Source? {
        didSet {
            guard source != oldValue else { return }
            resolve()
            needsDisplay = true
        }
    }

    private let size: CGFloat
    private var appImage: NSImage?
    private var tileSymbol: NSImage?
    private var tileColor: NSColor = .clear

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        fixed(width: size, height: size)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private func resolve() {
        appImage = nil
        tileSymbol = nil
        switch source {
        case let .app(bundlePath):
            appImage = AppIconCache.icon(forBundle: bundlePath, pointSize: size)
        case let .tile(symbolName, color):
            tileColor = color.ns
            tileSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                )
        case nil:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let appImage {
            appImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        guard tileSymbol != nil || source != nil else { return }
        tileColor.setFill()
        let radius = size * 0.24
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if let tileSymbol {
            let symbolSize = tileSymbol.size
            let rect = NSRect(
                x: (bounds.width - symbolSize.width) / 2,
                y: (bounds.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )
            tileSymbol.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }
}

extension RankingIconView.Source {
    /// App 行(有 bundle 路径)取应用图标;其余取类别瓦片。
    static func make(bundlePath: String?, tileSymbol: String, tileColor: Color) -> Self {
        if let bundlePath {
            return .app(bundlePath: bundlePath)
        }
        return .tile(symbolName: tileSymbol, color: tileColor)
    }
}

// MARK: - 数值列

/// 定宽数值列:12.5 semibold 等宽数字、右对齐;超宽先缩字(最小 0.8,SwiftUI
/// `.minimumScaleFactor(0.8)` 同义)再截断。高负载警示 = state-negative 数字 + 同色
/// 1pt 胶囊描边、负内距外扩 4pt(随文不占版)——描边画在外扩 4pt 的内层视图里,
/// 列宽与行高不动,重画范围也覆盖描边。
@MainActor
final class RankingValueView: FlippedView {
    private let canvas = RankingValueCanvas()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let font = PFont.digits(RankingRowMetrics.valueFontSize, .semibold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        fixed(width: RankingRowMetrics.valueWidth, height: lineHeight)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        clipsToBounds = false
        addSubview(canvas)
        canvas.pin(to: self, insets: NSEdgeInsets(
            top: -RankingValueCanvas.ringOutset,
            left: -RankingValueCanvas.ringOutset,
            bottom: -RankingValueCanvas.ringOutset,
            right: -RankingValueCanvas.ringOutset
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(text: String, alerts: Bool) {
        canvas.set(text: text, alerts: alerts)
    }
}

@MainActor
private final class RankingValueCanvas: FlippedView {
    static let ringOutset: CGFloat = 4
    private static let minimumScale: CGFloat = 0.8
    private var text = ""
    private var alerts = false

    func set(text: String, alerts: Bool) {
        guard text != self.text || alerts != self.alerts else { return }
        self.text = text
        self.alerts = alerts
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let outset = Self.ringOutset
        let column = bounds.insetBy(dx: outset, dy: outset)
        let color = alerts ? Surface.negative.ns : Ink.primary
        var font = PFont.digits(RankingRowMetrics.valueFontSize, .semibold)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var size = (text as NSString).size(withAttributes: attributes)
        if size.width > column.width {
            let scale = max(Self.minimumScale, column.width / size.width)
            font = PFont.digits(RankingRowMetrics.valueFontSize * scale, .semibold)
            attributes[.font] = font
            size = (text as NSString).size(withAttributes: attributes)
        }
        let width = min(size.width, column.width)
        let textRect = NSRect(
            x: column.maxX - width,
            y: column.midY - size.height / 2,
            width: width,
            height: size.height
        )
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .right
        attributes[.paragraphStyle] = style
        (text as NSString).draw(in: textRect, withAttributes: attributes)
        guard alerts else { return }
        // strokeBorder:描边落在外扩矩形之内(半线宽内缩)。
        let ring = textRect.insetBy(dx: -outset, dy: -outset).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}
