import AppKit
import PulseCore
import SwiftUI

// MARK: - 卡片家族零件 AppKit 版(popover-appkit/01)

//
// 与 CardFamily.swift / OverviewCards.swift 的 SwiftUI 零件一一对应、数值相同
// (DESIGN.md §Components 卡片家族)。弹窗只用紧凑档,但零件保留两档参数,
// 数值仍出自 `CardMetrics`。新卡一律组装这些零件,不手写卡壳 / 卡头 / 空态。

/// 卡壳:卡底色圆角块 + 内距。`padded: false` 给自排内距的卡(总览卡 / 主卡)。
/// 底色在 `draw` 里填——动态色每次绘制按当前外观解析。
@MainActor
class CardView: FlippedView {
    let content: NSView
    private let radius: CGFloat

    init(content: NSView, compact: Bool = true, padded: Bool = true) {
        self.content = content
        radius = CardMetrics.cornerRadius(compact: compact)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let inset = padded ? CardMetrics.padding(compact: compact) : 0
        content.pin(to: self, insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        Surface.card.ns.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// 整卡可点的卡壳(总览卡点击跳页):SwiftUI `.buttonStyle(.plain)` 同样没有
/// 悬停 / 按下视觉,这里也不加——只在松开且仍在卡内时触发。
@MainActor
final class ClickableCardView: CardView {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 卡内子视图一律不截获点击(整卡一个按钮,SwiftUI Button 同义)。
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?()
        }
    }
}

/// 指标徽章(§1.3):22×22,tint 16% 底,圆角 8,11pt semibold 符号。
@MainActor
final class BadgeView: FlippedView {
    private let symbol: NSImageView
    var tint: NSColor {
        didSet {
            symbol.contentTintColor = tint
            needsDisplay = true
        }
    }

    init(symbolName: String, tint: NSColor) {
        self.tint = tint
        symbol = makeSymbolView(symbolName, size: 11, weight: .semibold, tint: tint)
        super.init(frame: .zero)
        fixed(width: 22, height: 22)
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// 主卡头:22pt 徽章 + 卡标题(12.5 semibold,指标色)+ 右侧附件(可选)。
@MainActor
func makeCardHeader(symbolName: String, title: String, tint: NSColor, accessory: NSView? = nil) -> NSStackView {
    let badge = BadgeView(symbolName: symbolName, tint: tint)
    let label = makeLabel(title, font: PFont.text(12.5, .semibold), color: tint)
    var views: [NSView] = [badge, label, spacer(minLength: 8)]
    if let accessory {
        views.append(accessory)
    }
    let stack = hstack(views, spacing: 7)
    stack.setCustomSpacing(0, after: label)
    return stack
}

/// 副卡头:10pt 指标色符号 + 11 medium secondary 标题 + 右侧 10.5 tertiary 等宽注记。
@MainActor
final class CardSubHeaderView: NSStackView {
    let noteLabel = makeLabel(font: PFont.digits(10.5), color: Ink.tertiary, alignment: .right)
    private let symbol: NSImageView
    private let titleLabel: NSTextField

    init(symbolName: String, title: String, tint: NSColor, note: String? = nil) {
        symbol = makeSymbolView(symbolName, size: 10, weight: .semibold, tint: tint)
        titleLabel = makeLabel(title, font: PFont.text(11, .medium), color: Ink.secondary)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 5
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(symbol)
        addArrangedSubview(titleLabel)
        addArrangedSubview(spacer(minLength: 4))
        addArrangedSubview(noteLabel)
        setNote(note)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setNote(_ note: String?) {
        noteLabel.setText(note ?? "")
        noteLabel.isHidden = note == nil
    }

    func setTint(_ tint: NSColor) {
        symbol.contentTintColor = tint
    }
}

/// 统计值:小标签(10.5 secondary,可带 6pt 色点)在上,数值(12 semibold 等宽)在下。
@MainActor
final class StatValueView: NSStackView {
    private let dot = DotView(diameter: 6)
    private let label = makeLabel(font: PFont.text(10.5), color: Ink.secondary)
    private let value = makeLabel(font: PFont.digits(12, .semibold))

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(hstack([dot, label], spacing: 4))
        addArrangedSubview(value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ stat: MetricCardStat) {
        label.setText(stat.label)
        value.setText(stat.value)
        dot.isHidden = stat.dot == nil
        if let color = stat.dot {
            dot.color = color.ns
        }
    }
}

/// 实心圆点(统计色点 / 图例点 / 状态点)。
@MainActor
final class DotView: FlippedView {
    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    init(diameter: CGFloat) {
        super.init(frame: .zero)
        fixed(width: diameter, height: diameter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// 卡内空态:12.5 medium secondary 一句 + 10.5 tertiary 说明,居中;可带 11pt link 动作。
@MainActor
final class EmptyStateView: NSStackView {
    private let titleLabel = makeLabel(font: PFont.text(12.5, .medium), color: Ink.secondary, alignment: .center)
    private let detailLabel = makeLabel(font: PFont.text(10.5), color: Ink.tertiary, alignment: .center)
    private let actionButton = LinkButton()

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        addArrangedSubview(titleLabel)
        addArrangedSubview(detailLabel)
        addArrangedSubview(actionButton)
        setCustomSpacing(6, after: detailLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(title: String, detail: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        titleLabel.setText(title)
        detailLabel.setText(detail ?? "")
        detailLabel.isHidden = detail == nil
        actionButton.isHidden = actionTitle == nil || action == nil
        actionButton.set(title: actionTitle ?? "", action: action)
    }
}

/// `.buttonStyle(.link)` 对应物:11pt 链接色文字按钮。
@MainActor
final class LinkButton: NSButton {
    private var handler: (() -> Void)?

    init(fontSize: CGFloat = 11) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        font = PFont.text(fontSize)
        contentTintColor = .linkColor
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(title: String, action: (() -> Void)?) {
        if self.title != title {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? PFont.text(11),
                .foregroundColor: NSColor.linkColor,
            ])
        }
        handler = action
    }

    @objc private func fire() {
        handler?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 卡内明细行数值:12 常规等宽数字、右对齐,最小宽取 `CardRowWidth` 令牌。
@MainActor
func makeRowValue(minWidth: CGFloat? = nil, color: NSColor = Ink.secondary) -> NSTextField {
    let label = makeLabel(font: PFont.digits(12), color: color, alignment: .right)
    if let minWidth {
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
    }
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
}

/// 大数字(§1.2):圆体 bold + 等宽数字 + 负字距,单位约半号(48%)secondary、基线对齐。
@MainActor
final class FigureView: NSStackView {
    private let size: CGFloat
    private let valueLabel: NSTextField
    private let unitLabel: NSTextField

    init(size: CGFloat) {
        self.size = size
        valueLabel = makeLabel(font: PFont.rounded(size, .bold))
        unitLabel = makeLabel(font: PFont.rounded(size * 0.48, .semibold), color: Ink.secondary)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = size * 0.08
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(valueLabel)
        addArrangedSubview(unitLabel)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    private var current: (String, String)?

    func set(value: String, unit: String) {
        guard current?.0 != value || current?.1 != unit else { return }
        current = (value, unit)
        valueLabel.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: PFont.rounded(size, .bold),
            .foregroundColor: Ink.primary,
            .kern: -size * 0.02,
        ])
        unitLabel.setText(unit)
        unitLabel.isHidden = unit.isEmpty
    }
}

/// 状态 chip(§3-6):全圆胶囊,tint 14% 底 + 同色图标与文字(11 semibold / 图标 10.5,内距 8×3)。
@MainActor
final class ChipView: FlippedView {
    private let icon = NSImageView()
    private let label = makeLabel(font: PFont.text(11, .semibold))
    private var tint: NSColor = .clear
    private var current: (String, String)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        let row = hstack([icon, label], spacing: 2)
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ chip: MetricCardChip) {
        let tint = chip.tint.ns
        if current?.0 != chip.title || current?.1 != chip.systemImage {
            current = (chip.title, chip.systemImage)
            label.setText(chip.title)
            icon.image = symbolImage(chip.systemImage, size: 10.5)
        }
        if tint != self.tint {
            self.tint = tint
            icon.contentTintColor = tint
            label.textColor = tint
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// 占比 meter 条:6pt 圆头胶囊,轨道 = 强调色 14%、填充 = 强调色;**无过渡动画**
/// (DESIGN.md 排行卡节,2026-10-29 用户拍板)。
@MainActor
final class MeterBarView: FlippedView {
    var fraction: Double = 0 {
        didSet {
            if fraction != oldValue {
                needsDisplay = true
            }
        }
    }

    var tint: NSColor = .clear {
        didSet {
            if tint != oldValue {
                needsDisplay = true
            }
        }
    }

    init(width: CGFloat? = nil) {
        super.init(frame: .zero)
        fixed(width: width, height: 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let width = bounds.width * CGFloat(min(max(fraction, 0), 1))
        guard width > 0 else { return }
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: r, yRadius: r)
            .fill()
    }
}
