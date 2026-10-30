import AppKit
import PulseCore
import SwiftUI

// MARK: - 弹窗根视图 AppKit 版(popover-appkit/01,取代 DashboardView + MenuBarPopoverGate)

/// 弹窗主页:图标 tab → 页头(页名 + 本机一行 / 运行时长)→ 定高 520 滚动区(当前 tab
/// 的卡片竖排,间距 8)→ 触发中告警横幅 → 底部操作排(开窗靠左;设置 + 退出靠右)。
/// 外框:定宽 360、内距 14、竖向间距 10、窗底色 `Surface.window`(DashboardView 同值)。
///
/// 每个 tab 的卡片组成见 `PopoverPages`(以 `MetricTabStack` 紧凑分支为准)。
/// 切 tab 时整页重建、旧页卸下(观察回路随离窗停止);卡片自己观察要画的数据。
@MainActor
final class PopoverRootView: ObservingView {
    static let width: CGFloat = 360
    static let contentHeight: CGFloat = 520

    private let monitor: SystemMonitor
    private let model: DashboardModel
    private let onTabChange: (MetricTab) -> Void

    private var selection: MetricTabSelection
    private let tabBar = IconTabBarView()
    private let header = PageHeaderView()
    private let scrollView = NSScrollView()
    private let pageStack = vstack([], spacing: 8, alignment: .leading)
    private let banner: AlertBannerNSView
    private var builtTab: MetricTab?
    /// 正在呈现的失败汇总(防同一份报告在观察重放里重复弹)。
    private var presentingFailure = false

    init(
        monitor: SystemMonitor,
        model: DashboardModel,
        initialTab: MetricTab,
        onTabChange: @escaping (MetricTab) -> Void
    ) {
        self.monitor = monitor
        self.model = model
        self.onTabChange = onTabChange
        selection = MetricTabSelection(
            current: initialTab,
            axis: MetricTab.popoverAxis(hasBattery: monitor.battery.hasBattery)
        )
        banner = AlertBannerNSView(center: monitor.alerts)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        tabBar.onSelect = { [weak self] in self?.select($0) }
        applySelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: 布局

    private func buildLayout() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pageStack)
        pageStack.pin(to: document)
        scrollView.documentView = document
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.contentHeight),
        ])

        let footer = hstack([
            FooterButton(symbolName: "macwindow", help: "打开主窗口", accessibilityLabel: "打开主窗口") {
                PopoverActions.openMainWindow()
            },
            spacer(),
            FooterButton(symbolName: "gearshape", help: "设置项目根目录", accessibilityLabel: "设置") {
                PopoverActions.openSettings()
            },
            FooterButton(symbolName: "power", help: "退出 Pulse", accessibilityLabel: "退出 Pulse") {
                NSApplication.shared.terminate(nil)
            },
        ], spacing: 6)

        let root = vstack([tabBar, header, scrollView, banner, footer], spacing: 10, alignment: .leading)
        addSubview(root)
        root.pin(to: self, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        for view in [tabBar, header, scrollView, banner, footer] {
            view.fillWidth(of: root)
        }
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Surface.window.ns.setFill()
        bounds.fill()
    }

    // MARK: 观察:电池入轴 + 处置失败汇总

    override func update() {
        // 首次电池读数落地 → 电池页入轴;被隐藏的当前 tab 回落总览。
        let axis = MetricTab.popoverAxis(hasBattery: monitor.battery.hasBattery)
        if axis != selection.axis {
            selection.setAxis(axis)
            applySelection()
        }
        // 处置结果汇总:有失败才弹(KillFailureAlert 同口径)。弹窗是模态,
        // 移出观察回路异步呈现,确认后清空报告。
        if let report = model.killFailureReport, report.hasFailures, !presentingFailure {
            presentingFailure = true
            DispatchQueue.main.async { [weak self] in self?.presentFailure(report) }
        }
    }

    private func presentFailure(_ report: KillReport) {
        let alert = NSAlert()
        alert.messageText = report.failureAlertTitle
        alert.informativeText = report.failureAlertMessage
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        model.killFailureReport = nil
        presentingFailure = false
    }

    // MARK: tab 切换(点击 / ←→)

    private func select(_ tab: MetricTab) {
        guard tab != selection.current else { return }
        selection.current = tab
        applySelection()
    }

    private func applySelection() {
        tabBar.set(selection)
        header.setTitle(selection.current.title)
        guard builtTab != selection.current else { return }
        builtTab = selection.current
        pageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let context = PopoverPageContext(monitor: monitor, model: model) { [weak self] in self?.select($0) }
        for card in PopoverPages.cards(for: selection.current, context: context) {
            pageStack.addArrangedSubview(card)
            card.fillWidth(of: pageStack)
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        onTabChange(selection.current)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow:
            selection.moveLeft()
            applySelection()
        case .rightArrow:
            selection.moveRight()
            applySelection()
        default:
            super.keyDown(with: event)
        }
    }
}

/// 底排动作(DashboardView.footer 同义)。
@MainActor
enum PopoverActions {
    /// LSUIElement 应用 `.accessory`:先激活再开窗,否则窗口开在其他应用后面;
    /// 开窗走广播由菜单栏控制器统一路由(收面板 + 经桥开主窗)。
    static func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: AlertNotificationRouter.openMainWindowNotification, object: nil)
    }

    /// 系统标准动作开设置窗(macOS 14+ showSettingsWindow:),旧名兜底。
    static func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
