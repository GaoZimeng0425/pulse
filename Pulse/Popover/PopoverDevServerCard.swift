import AppKit
import PulseCore
import SwiftUI

// MARK: - dev server 卡 AppKit 版(popover-appkit/02)

/// dev server 卡紧凑档(DevServerCardView 同值):卡头(terminal 徽章 + 「Dev server」+ 右侧 11 semibold
/// 等宽 secondary 计数)/ 竖向间距 12 / 行列表(行距 8)/ 「全部停止」胶囊 + 10.5 tertiary 注记(间距 6)。
/// 无 server 时卡内安静空态。全部停止只上抛请求,确认在 KillRequestFlow 关口。
@MainActor
final class DevServerCardNSView: ObservingView {
    private let monitor: SystemMonitor
    private let model: DashboardModel
    private let count = makeLabel(font: PFont.digits(11, .semibold), color: Ink.secondary, alignment: .right)
    private let empty = EmptyStateView()
    private let list = vstack([], spacing: 8)
    private let actions: NSStackView
    private var rows: [DevServerRowView] = []

    init(monitor: SystemMonitor, model: DashboardModel) {
        self.monitor = monitor
        self.model = model
        let stopAll = CapsuleActionButton(title: KillCopy.stopAllActionTitle)
        stopAll.toolTip = "经确认后向全部 dev server 发送结束信号,绝不自动执行"
        let note = makeLabel("停止需逐个确认,绝不自动杀", font: PFont.text(10.5), color: Ink.tertiary)
        actions = hstack([stopAll, note], spacing: 6)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stopAll.onClick = { [weak self] in
            guard let self else { return }
            self.model.requestStopAllDevServers(self.monitor.devServers.servers)
        }
        empty.set(
            title: "没有在跑的 dev server",
            detail: "vite、next dev、vitest watch 等开发服务出现时,会在这里列出闲置时长与监听端口"
        )
        let header = makeCardHeader(
            symbolName: "terminal",
            title: "Dev server",
            tint: Metric.cpu.accentColor.ns,
            accessory: count
        )
        let body = vstack([header, empty, list, actions], spacing: 12)
        for view in [header, empty, list] {
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
        let servers = monitor.devServers.servers
        let isEmpty = servers.isEmpty
        count.isHidden = isEmpty
        count.setText("\(servers.count)")
        empty.isHidden = !isEmpty
        list.isHidden = isEmpty
        actions.isHidden = isEmpty
        while rows.count < servers.count {
            let row = DevServerRowView()
            rows.append(row)
            list.addArrangedSubview(row)
            row.fillWidth(of: list)
        }
        while rows.count > servers.count {
            rows.removeLast().removeFromSuperview()
        }
        for (row, server) in zip(rows, servers) {
            row.set(server)
        }
    }
}

/// 一行 server:名(12 medium)/ pid(10.5 等宽 tertiary,行距 1)左列;右侧闲置(11 semibold,
/// 闲置琥珀 / 否则 secondary)、内存(11 medium 等宽 secondary)、端口(11 等宽 secondary),
/// 列距 10、与名首基线对齐;名与右列之间弹性 ≥8。
@MainActor
private final class DevServerRowView: FlippedView {
    private let name = makeLabel(font: PFont.text(12, .medium))
    private let pid = makeLabel(font: PFont.digits(10.5), color: Ink.tertiary)
    private let idle = makeLabel(font: PFont.text(11, .semibold), color: Ink.secondary)
    private let memory = makeLabel(font: PFont.digits(11, .medium), color: Ink.secondary)
    private let ports = makeLabel(font: PFont.digits(11), color: Ink.secondary)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [idle, memory, ports] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view in [name, pid, idle, memory, ports] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            pid.leadingAnchor.constraint(equalTo: leadingAnchor),
            pid.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            pid.bottomAnchor.constraint(equalTo: bottomAnchor),
            pid.trailingAnchor.constraint(lessThanOrEqualTo: idle.leadingAnchor, constant: -8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: idle.leadingAnchor, constant: -8),
            ports.trailingAnchor.constraint(equalTo: trailingAnchor),
            memory.trailingAnchor.constraint(equalTo: ports.leadingAnchor, constant: -10),
            idle.trailingAnchor.constraint(equalTo: memory.leadingAnchor, constant: -10),
            idle.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            memory.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            ports.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ server: DevServerStatus) {
        name.setText(server.displayName)
        pid.setText("pid \(server.pid)")
        // 闲置列:时长为 0(刚起)如实显示"闲置 0 秒"。
        idle.setText(server.idleSeconds.map { "闲置 \(PulseFormat.duration(seconds: $0))" } ?? "未闲置")
        idle.setColor(server.isIdle ? Metric.disk.accentColor.ns : Ink.secondary)
        memory.setText(PulseFormat.memory(server.memoryBytes))
        // 端口列:无监听端口如实占位(不伪造)。
        ports.setText(
            server.listeningPorts.isEmpty
                ? "无监听端口"
                : server.listeningPorts.map { ":\($0)" }.joined(separator: " ")
        )
        setAccessibilityLabel([name, pid, idle, memory, ports].map(\.stringValue).joined(separator: ","))
    }
}

/// 危险动作胶囊按钮(「全部停止」):12 semibold negative 字 + negative 10% 胶囊底,内距 10×4;
/// `.buttonStyle(.plain)` 同样无悬停 / 按下视觉,松开且仍在按钮内才触发。
@MainActor
final class CapsuleActionButton: FlippedView {
    var onClick: (() -> Void)?
    private let label: NSTextField

    init(title: String) {
        label = makeLabel(title, font: PFont.text(12, .semibold), color: Surface.negative.ns)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pin(to: self, insets: NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        Surface.negative.ns.withAlphaComponent(0.1).setFill()
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
