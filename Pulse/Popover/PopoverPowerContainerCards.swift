import AppKit
import PulseCore
import SwiftUI

// MARK: - GPU 页五路功率卡 + 容器卡 AppKit 版(popover-appkit/06)

/// 五路功率卡紧凑档(PowerDomainsCardView 同值):副卡头「五路功率」+ 注记「合计 …」/
/// 在场域各一行(标签 36 + meter 按五路榜首归一 + 瓦数 ≥56,行距 6);行色取
/// `PowerDomain.tint`(与历史页功率分项同一出处);缺席域不出现,读数缺失安静占位。
@MainActor
final class PowerDomainsCardNSView: ObservingView {
    private let reading: @MainActor () -> PowerReading?
    private let header: CardSubHeaderView
    private let rowsStack = vstack([], spacing: 6)
    private var rows: [MeterDetailRowView] = []
    private let empty = EmptyStateView()
    private var domainTints: [PowerDomain: NSColor] = [:]

    init(reading: @escaping @MainActor () -> PowerReading?) {
        self.reading = reading
        header = CardSubHeaderView(symbolName: "bolt.horizontal.fill", title: "五路功率", tint: Metric.gpu.accentColor.ns)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = makeDetailCard([header, rowsStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let reading = reading()
        header.setNote(reading.map { "合计 \(PulseFormat.watts($0.totalWatts))" })
        let domainRows = reading.map(PowerDomainsCardView.rows(for:)) ?? []
        rowsStack.isHidden = domainRows.isEmpty
        empty.isHidden = !domainRows.isEmpty
        empty.set(title: reading == nil ? "功率暂不可用" : "暂无在场功率通道")
        let leader = domainRows.map(\.watts).max() ?? 0
        syncRows(&rows, count: domainRows.count, in: rowsStack) {
            MeterDetailRowView(labelWidth: CardRowWidth.shortLabel, valueMinWidth: CardRowWidth.quantityValue)
        }
        for (row, domainRow) in zip(rows, domainRows) {
            row.set(
                title: domainRow.title,
                fraction: MeterNormalization.fraction(domainRow.watts, leader: leader),
                value: PulseFormat.watts(domainRow.watts),
                tint: tint(for: domainRow.domain)
            )
        }
    }

    /// 域色缓存:令牌桥接一次,meter 比较 tint 时同一对象不重画。
    private func tint(for domain: PowerDomain) -> NSColor {
        if let cached = domainTints[domain] {
            return cached
        }
        let color = domain.tint.ns
        domainTints[domain] = color
        return color
    }
}

/// 容器卡紧凑档(ContainersCardView 同值):副卡头「容器」+ 注记「N 台 · M 运行中」/
/// 每台一行(前 6 台,行距 6;运行中置顶是 `ContainersReading` 的不变量,照序画);
/// 引擎缺席或无容器安静占位。
@MainActor
final class ContainersCardNSView: ObservingView {
    private static let visibleLimit = 6

    private let reading: @MainActor () -> ContainersReading?
    private let tint = Metric.containers.accentColor.ns
    private let header: CardSubHeaderView
    private let rowsStack = vstack([], spacing: 6)
    private var rows: [ContainerRowView] = []
    private let empty = EmptyStateView()

    init(reading: @escaping @MainActor () -> ContainersReading?) {
        self.reading = reading
        header = CardSubHeaderView(symbolName: "cube.box.fill", title: "容器", tint: tint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = makeDetailCard([header, rowsStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let reading = reading()
        let containers = reading?.containers ?? []
        header.setNote(containers.isEmpty ? nil : "\(containers.count) 台 · \(containers.filter(\.isRunning).count) 运行中")
        rowsStack.isHidden = containers.isEmpty
        empty.isHidden = !containers.isEmpty
        empty.set(title: reading?.engineReachable == true ? "无容器" : "Docker / OrbStack 未运行")
        let visible = Array(containers.prefix(Self.visibleLimit))
        syncRows(&rows, count: visible.count, in: rowsStack) { ContainerRowView(tint: tint) }
        for (row, container) in zip(rows, visible) {
            row.set(container)
        }
    }
}

/// 容器行(间距 8):6pt 状态点(运行中 = 容器色,否则 inactive)+ 名称(12 medium)
/// + 弹性空白(≥8)+ CPU%(≥48,secondary)+ 内存(≥56,tertiary)。
@MainActor
final class ContainerRowView: NSStackView {
    private let tint: NSColor
    private let dot = DotView(diameter: 6)
    private let nameLabel = makeNameLabel()
    private let cpuLabel = makeRowValue(minWidth: CardRowWidth.decimalPercentValue)
    private let memoryLabel = makeRowValue(minWidth: CardRowWidth.quantityValue, color: Ink.tertiary)

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false
        for view in [dot, nameLabel, spacer(minLength: 8), cpuLabel, memoryLabel] {
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ container: ContainerRow) {
        let dotColor = container.isRunning ? tint : DetailInk.inactive
        if dot.color != dotColor {
            dot.color = dotColor
        }
        nameLabel.setText(container.name)
        cpuLabel.setText(container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
        memoryLabel.setText(container.memoryBytes.map { PulseFormat.memory($0) } ?? "—")
    }
}
