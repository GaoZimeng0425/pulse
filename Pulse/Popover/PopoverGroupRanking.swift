import AppKit
import PulseCore
import SwiftUI

// MARK: - 「当前最忙」组排行卡 AppKit 版(popover-appkit/03;RankingCardView 紧凑档)

/// 组排行卡:全部组,榜单序 / 读数口径随 tab(`model.content(tab:)`);点行展开组内
/// 进程下钻,悬停出「结束整组」,右键同入口。标题色随口径(CPU / 内存指标色)。
/// 行按榜单位置复用(每个位置一个槽 = 行 + 下钻区),行数变化才增删——采样轮重排
/// 只改槽内容,悬停态留在鼠标所在的位置上。展开 / 选中会话状态在 DashboardModel。
@MainActor
final class GroupRankingCardNSView: ObservingView {
    private static let emptyMessage = RankingEmptyMessage(
        title: "暂无活动组",
        detail: "首轮采样尚未完成,或系统极端空闲"
    )

    private let tab: MetricTab
    private let monitor: SystemMonitor
    private let model: DashboardModel
    private let shell = RankingCardShell(title: "当前最忙")
    private var slots: [GroupRankingSlotView] = []

    init(tab: MetricTab, monitor: SystemMonitor, model: DashboardModel) {
        self.tab = tab
        self.monitor = monitor
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(shell)
        shell.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let content = model.content(tab: tab)
        let metric = content.metric
        shell.setTitle("当前最忙", accent: (metric == .cpu ? Metric.cpu : Metric.memory).accentColor.ns)
        shell.setValueLabel(metric == .cpu ? "CPU" : "内存")
        shell.setEmpty(content.ranking.isEmpty, message: Self.emptyMessage)
        syncSlotCount(content.ranking.count)
        let expanded = model.expandedGroupIDs
        // 下钻数据与选中进程只在有展开组时读:没展开就不订阅它们的变化。
        let anyExpanded = content.ranking.contains { expanded.contains($0.id) }
        let drilldown = anyExpanded ? monitor.drilldown : nil
        let selectedPID = anyExpanded ? model.selectedProcessID : nil
        for (slot, group) in zip(slots, content.ranking) {
            slot.set(
                group: group,
                metric: metric,
                meterFraction: Self.meterFraction(group, content: content),
                isExpanded: expanded.contains(group.id),
                drilldown: drilldown,
                selectedPID: selectedPID
            )
        }
    }

    private func syncSlotCount(_ count: Int) {
        while slots.count < count {
            let slot = GroupRankingSlotView()
            slot.onToggle = { [weak self] id in self?.model.toggleExpansion(of: id) }
            slot.onEndGroup = { [weak self] group in self?.model.requestEndGroup(group) }
            slot.onSelectProcess = { [weak self] pid in self?.model.selectedProcessID = pid }
            slot.onEndProcess = { [weak self] target in self?.model.requestEndProcess(target) }
            slots.append(slot)
            shell.rowsStack.addArrangedSubview(slot)
            slot.fillWidth(of: shell.rowsStack)
        }
        while slots.count > count {
            slots.removeLast().removeFromSuperview()
        }
    }

    /// meter 榜首归一(RankingCardView.meterFraction 同口径,随口径换指标)。
    private static func meterFraction(_ group: ProcessGroup, content: MetricTabContent) -> Double {
        switch content.metric {
        case .cpu:
            MeterNormalization.fraction(group.cpuPercent, leader: content.cpuLeader)
        case .memory:
            MeterNormalization.fraction(Double(group.memoryBytes), leader: Double(content.memoryLeaderBytes))
        }
    }
}

// MARK: - 槽(行 + 下钻区)

/// 一个榜单位置:组行 + 展开时的下钻区(竖排间距 4,下钻区底外距 6)。
@MainActor
private final class GroupRankingSlotView: NSStackView {
    var onToggle: ((GroupIdentity) -> Void)?
    var onEndGroup: ((ProcessGroup) -> Void)?
    var onSelectProcess: ((pid_t?) -> Void)?
    var onEndProcess: ((KillTarget) -> Void)?

    private let row = GroupRankingRowView()
    private let drilldownWrap = FlippedView()
    private lazy var drilldown = PopoverDrilldownView()
    private var drilldownInstalled = false

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(row)
        addArrangedSubview(drilldownWrap)
        row.fillWidth(of: self)
        drilldownWrap.translatesAutoresizingMaskIntoConstraints = false
        drilldownWrap.fillWidth(of: self)
        drilldownWrap.isHidden = true
        row.onToggle = { [weak self] id in self?.onToggle?(id) }
        row.onEndGroup = { [weak self] group in self?.onEndGroup?(group) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(
        group: ProcessGroup,
        metric: GroupCardMetric,
        meterFraction: Double,
        isExpanded: Bool,
        drilldown state: DrilldownState?,
        selectedPID: pid_t?
    ) {
        row.set(group: group, metric: metric, meterFraction: meterFraction, isExpanded: isExpanded)
        // 下钻数据缺席(首轮前)时 SwiftUI 版展开内容为空:这里同样不画下钻区。
        let showsDrilldown = isExpanded && state != nil
        if drilldownWrap.isHidden == showsDrilldown {
            drilldownWrap.isHidden = !showsDrilldown
        }
        guard showsDrilldown, let state else { return }
        installDrilldownIfNeeded()
        drilldown.set(group: group, drilldown: state, selectedPID: selectedPID)
    }

    private func installDrilldownIfNeeded() {
        guard !drilldownInstalled else { return }
        drilldownInstalled = true
        drilldown.onSelect = { [weak self] pid in self?.onSelectProcess?(pid) }
        drilldown.onEndProcess = { [weak self] target in self?.onEndProcess?(target) }
        drilldownWrap.addSubview(drilldown)
        drilldown.pin(to: drilldownWrap, insets: NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0))
    }
}

// MARK: - 组行

/// 组排行行(RankingRowView 紧凑档):通用行排版 + 交互——点行展开、悬停 / 展开时
/// primary 5% 圆角 8 底、悬停出「结束整组」(不悬停时透明占位,行宽不跳)、右键同入口。
/// 组 CPU% > 100%(StatusBadgeRules 同一阈值)= 行尾 CPU 数值圈红,仅 CPU 口径。
@MainActor
private final class GroupRankingRowView: RankingRowNSView {
    var onToggle: ((GroupIdentity) -> Void)?
    var onEndGroup: ((ProcessGroup) -> Void)?

    private let endButton = NSButton()
    private let chevron = ChevronView()
    private var group: ProcessGroup?
    private var isHovering = false {
        didSet {
            if isHovering != oldValue {
                endButton.alphaValue = isHovering ? 1 : 0
                needsDisplay = true
            }
        }
    }

    private var isExpanded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        endButton.isBordered = false
        endButton.bezelStyle = .inline
        endButton.image = symbolImage("xmark.octagon", size: 11, weight: .semibold)
        endButton.imagePosition = .imageOnly
        endButton.contentTintColor = Surface.negative.ns
        endButton.toolTip = "结束整组(需确认)"
        endButton.alphaValue = 0
        endButton.target = self
        endButton.action = #selector(endGroup)
        endButton.fixed(width: 18, height: 18)
        let controls = hstack([endButton, chevron], spacing: 2)
        trailing.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            controls.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(group: ProcessGroup, metric: GroupCardMetric, meterFraction: Double, isExpanded: Bool) {
        self.group = group
        let highLoad = StatusBadgeRules.groupBadge(cpuPercent: group.cpuPercent) != nil
        let valueText = switch metric {
        case .cpu: PulseFormat.cpuPercent(group.cpuPercent)
        case .memory: PulseFormat.memory(group.memoryBytes)
        }
        // 副文:进程数 + 另一指标(CPU 口径带内存,内存口径带 CPU%)。
        let subtitle = switch metric {
        case .cpu: "\(group.processes.count) 进程 · \(PulseFormat.memory(group.memoryBytes))"
        case .memory: "\(group.processes.count) 进程 · CPU \(PulseFormat.cpuPercent(group.cpuPercent))"
        }
        // 行内强调色:CPU 口径走类别样式表(孤儿橙);内存口径换内存指标色,孤儿仍橙。
        let style = group.category.cardStyle
        let accent = metric == .memory && group.category != .orphan ? Metric.memory.accentColor : style.accentColor
        setContent(
            name: group.name,
            subtitle: subtitle,
            icon: .make(bundlePath: group.bundlePath, tileSymbol: style.symbolName, tileColor: style.tileColor),
            meterFraction: meterFraction,
            tint: accent.ns,
            valueText: valueText,
            alertsHighLoad: metric == .cpu && highLoad
        )
        if isExpanded != self.isExpanded {
            self.isExpanded = isExpanded
            chevron.isExpanded = isExpanded
            needsDisplay = true
        }
        endButton.setAccessibilityLabel("结束整组 \(group.name)")
        setAccessibilityLabel("\(group.name),\(group.processes.count) 进程,\(valueText)" + (highLoad ? ",高负载" : ""))
        setAccessibilityHelp(isExpanded ? "收起组内进程列表" : "展开组内进程列表")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering || isExpanded else { return }
        Ink.primary.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    // MARK: 交互

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    /// 整行一个按钮:除结束按钮外,行内子视图一律不截获点击。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        let buttonPoint = endButton.convert(local, from: self)
        if endButton.alphaValue > 0, endButton.bounds.contains(buttonPoint) {
            return endButton
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)), let group {
            onToggle?(group.id)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        if let group {
            onToggle?(group.id)
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "结束整组…", action: #selector(endGroup), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func endGroup() {
        if let group {
            onEndGroup?(group)
        }
    }
}

/// 展开箭头:chevron.right 10 semibold tertiary,展开时顺时针转 90°(rotationEffect
/// 同义,无过渡动画);列宽 10。
@MainActor
private final class ChevronView: FlippedView {
    var isExpanded = false {
        didSet {
            if isExpanded != oldValue {
                needsDisplay = true
            }
        }
    }

    private let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Ink.tertiary]))
        )

    override init(frame: NSRect) {
        super.init(frame: frame)
        fixed(width: 10, height: 18)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = image.size
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if isExpanded {
            // 翻转坐标系(y 向下)里正角度即顺时针。
            context.rotate(by: .pi / 2)
        }
        image.draw(
            in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        context.restoreGState()
    }
}
