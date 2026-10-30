import AppKit
import PulseCore
import SwiftUI

// MARK: - 面板外框零件(popover-appkit/01):图标页签栏 / 页头 / 告警横幅 / 底排按钮

/// 弹窗顶部图标 tab(MetricIconTabBar 同配方):单行满宽均分,选中 = 指标强调色 15%
/// 胶囊 + 强调色图标,未选中 = secondary;13pt medium 符号、槽高 26、间距 4;
/// 悬停提示 = 页名。渲染序 = 展示轴(无电池机器不含电池页)。
@MainActor
final class IconTabBarView: NSStackView {
    var onSelect: ((MetricTab) -> Void)?
    private var buttons: [MetricTab: IconTabButton] = [:]
    private var axis: [MetricTab] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fillEqually
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ selection: MetricTabSelection) {
        if selection.axis != axis {
            axis = selection.axis
            arrangedSubviews.forEach { $0.removeFromSuperview() }
            buttons = [:]
            for tab in axis {
                let button = IconTabButton(tab: tab) { [weak self] in self?.onSelect?(tab) }
                buttons[tab] = button
                addArrangedSubview(button)
            }
        }
        for (tab, button) in buttons {
            button.isSelected = tab == selection.current
        }
    }
}

@MainActor
private final class IconTabButton: FlippedView {
    private let tab: MetricTab
    private let icon: NSImageView
    private let action: () -> Void

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            icon.contentTintColor = isSelected ? tab.accent.accentColor.ns : Ink.secondary
            needsDisplay = true
            setAccessibilitySelected(isSelected)
        }
    }

    init(tab: MetricTab, action: @escaping () -> Void) {
        self.tab = tab
        self.action = action
        icon = makeSymbolView(tab.symbolName, size: 13, weight: .medium, tint: Ink.secondary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = tab.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        tab.accent.accentColor.ns.withAlphaComponent(0.15).setFill()
        let r = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// 页头:页名 + 本机一行「芯片 · 核数 · 内存」(两行 11pt secondary)+ 右侧运行时长
/// (时钟符号 + 等宽数字,每分钟刷新);水平内距 4。全 tab 一致,切 tab 页头不跳高。
@MainActor
final class PageHeaderView: FlippedView {
    private let titleLabel = makeLabel(font: PFont.text(11), color: Ink.secondary)
    private let uptimeLabel = makeLabel(font: PFont.digits(11), color: Ink.secondary)
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let host = HostInfo.current
        let hostLabel = makeLabel(
            PulseFormat.hostSummary(
                chipName: host.chipName,
                coreCount: host.coreCount,
                physicalMemoryBytes: host.physicalMemoryBytes
            ),
            font: PFont.text(11),
            color: Ink.secondary
        )
        let clock = makeSymbolView("clock", size: 11, tint: Ink.secondary)
        let left = vstack([titleLabel, hostLabel], spacing: 2)
        let right = hstack([clock, uptimeLabel], spacing: 4)
        let row = hstack([left, spacer(), right], spacing: 8, alignment: .top)
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        refreshUptime()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setTitle(_ title: String) {
        titleLabel.setText(title)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        refreshUptime()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUptime() }
        }
    }

    private func refreshUptime() {
        uptimeLabel.setText(PulseFormat.systemUptime(seconds: ProcessInfo.processInfo.systemUptime))
    }
}

/// 紧凑告警横幅(AlertBannerView 紧凑档):触发中告警逐条(铃铛 9pt + 标题 11 semibold +
/// 副文 10 secondary)+ 授权降级提示;警示色 12% 淡底、圆角 10、内距 10×6。无告警时隐藏。
@MainActor
final class AlertBannerNSView: ObservingView {
    private let center: AlertCenter
    private let stack = vstack([], spacing: 4)

    init(center: AlertCenter) {
        self.center = center
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.pin(to: self, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let alerts = center.activeAlerts
        let denied = center.authorizationDenied
        let requestFailed = center.authorizationRequestFailed
        isHidden = alerts.isEmpty
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !alerts.isEmpty else { return }
        for occurrence in alerts {
            stack.addArrangedSubview(row(occurrence))
        }
        if denied {
            stack.addArrangedSubview(degradedRow(
                "系统通知已被拒绝,告警仅在应用内提示。",
                actionTitle: "打开系统通知设置"
            ) { SystemNotificationSettings.open() })
        }
        if requestFailed {
            stack.addArrangedSubview(degradedRow(
                "系统通知授权未完成,告警仅在应用内提示。",
                actionTitle: "重新请求"
            ) { [center] in center.retryAuthorization() })
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Surface.warning.ns.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    private func row(_ occurrence: AlertOccurrence) -> NSView {
        let bell = makeSymbolView("bell.badge.fill", size: 9, weight: .semibold, tint: Surface.warning.ns)
        let title = makeLabel(AlertNotificationContent.title(for: occurrence), font: PFont.text(11, .semibold))
        let body = makeLabel(AlertNotificationContent.body(for: occurrence), font: PFont.text(10), color: Ink.secondary)
        return hstack([bell, vstack([title, body], spacing: 1)], spacing: 6, alignment: .firstBaseline)
    }

    private func degradedRow(_ text: String, actionTitle: String, action: @escaping () -> Void) -> NSView {
        // .caption2 = 10pt。
        let label = makeLabel(text, font: PFont.text(10), color: Ink.secondary)
        let button = LinkButton(fontSize: 10)
        button.set(title: actionTitle, action: action)
        return hstack([label, button], spacing: 6, alignment: .firstBaseline)
    }
}

/// 弹窗底部按钮(FooterButtonStyle 同配方):12.5 medium 符号,高 30、水平内距 12,
/// 卡底色圆角 8,按下加深为卡内抬升底。纯图标,语义靠 toolTip 与无障碍标签。
@MainActor
final class FooterButton: FlippedView {
    private let action: () -> Void
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(symbolName: String, help: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = makeSymbolView(symbolName, size: 12.5, weight: .medium, tint: Ink.primary)
        addSubview(icon)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        (isPressed ? Surface.cardHigh : Surface.card).ns.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
