import AppKit
import SwiftUI

// MARK: - 药丸 tab 条 AppKit 版(popover-appkit/08)

//
// 与 PillTabBar(SwiftUI)同配方:选中 = 该项强调色 15% 胶囊底 + 同色前景,未选中 = secondary 前景
// 无底;图标 11 medium、文字 callout(12)medium、图文间距 5、内距 9×5、药丸间距 4。
// 玻璃外裹 = 药丸外 4pt 内距 + 系统 Liquid Glass(`NSGlassEffectView` .regular,胶囊圆角),
// 与 SwiftUI `glassEffect()` 同一系统材质,不自绘底 / 影。
// 已知差异:不做 0.2s snappy 切换动画(选中文字展开 / 胶囊生长 / 让位滑移)——选中态即时切换。

/// 药丸条(单选)。`items` 变化时才增删药丸视图;选中态变化只改受影响的两颗。
@MainActor
final class PillTabBarNSView: NSView {
    enum TextVisibility {
        case selectedOnly
        case always
    }

    var onSelect: ((Int) -> Void)?
    private let textVisibility: TextVisibility
    private let row = hstack([], spacing: 4)
    private var pills: [PillNSView] = []

    init(textVisibility: TextVisibility = .always, isGlassContainer: Bool = true) {
        self.textVisibility = textVisibility
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        if isGlassContainer {
            let glass = CapsuleGlassView()
            let padded = NSView()
            padded.translatesAutoresizingMaskIntoConstraints = false
            padded.addSubview(row)
            row.pin(to: padded, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
            glass.contentView = padded
            padded.pin(to: glass)
            addSubview(glass)
            glass.pin(to: self)
        } else {
            addSubview(row)
            row.pin(to: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(items: [PillTabItem], selectedIndex: Int) {
        while pills.count < items.count {
            let pill = PillNSView()
            let index = pills.count
            pill.onClick = { [weak self] in self?.onSelect?(index) }
            pills.append(pill)
            row.addArrangedSubview(pill)
        }
        while pills.count > items.count {
            pills.removeLast().removeFromSuperview()
        }
        for (index, (pill, item)) in zip(pills, items).enumerated() {
            let isSelected = index == selectedIndex
            pill.set(item, isSelected: isSelected, showsText: textVisibility == .always || isSelected)
        }
    }
}

/// 系统玻璃胶囊:圆角随高度取半(SwiftUI `glassEffect()` 默认胶囊形)。
@MainActor
private final class CapsuleGlassView: NSGlassEffectView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        style = .regular
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        if cornerRadius != radius {
            cornerRadius = radius
        }
    }
}

/// 一颗药丸:点按即选(`.buttonStyle(.plain)` 同样无悬停 / 按下视觉);悬停提示 = 标题。
@MainActor
private final class PillNSView: FlippedView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = makeLabel(font: PFont.text(12, .medium))
    private var current: (title: String, symbol: String?, tint: Color, selected: Bool, showsText: Bool)?
    private var tint: NSColor = .clear
    private var isSelected = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 放不下时只压选中药丸的文字(尾部省略),不让栈把整颗药丸挤掉:历史页指标条
        // 9 项在 324pt 内放不下「图标 + 系统负载」(旧版同处文字被挤成竖排,popover-appkit/08)。
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = hstack([icon, label], spacing: 5)
        addSubview(content)
        content.pin(to: self, insets: NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ item: PillTabItem, isSelected: Bool, showsText: Bool) {
        let changed = current?.title != item.title || current?.symbol != item.symbol || current?.tint != item.tint
            || current?.selected != isSelected || current?.showsText != showsText
        guard changed else { return }
        if current?.symbol != item.symbol || current == nil {
            icon.image = item.symbol.flatMap { symbolImage($0, size: 11, weight: .medium) }
            icon.isHidden = item.symbol == nil
        }
        current = (item.title, item.symbol, item.tint, isSelected, showsText)
        let tint = item.tint.ns
        self.tint = tint
        self.isSelected = isSelected
        let foreground = isSelected ? tint : Ink.secondary
        label.setText(item.title)
        label.textColor = foreground
        label.isHidden = !showsText
        icon.contentTintColor = foreground
        toolTip = item.title
        setAccessibilityLabel(item.title)
        setAccessibilityValue(isSelected ? "已选中" : nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        tint.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
