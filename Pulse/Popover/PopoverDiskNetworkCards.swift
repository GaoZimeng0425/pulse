import AppKit
import PulseCore
import SwiftUI

// MARK: - 磁盘页各卷明细 / 本地快照 + 网络页流量累计 AppKit 版(popover-appkit/07)

/// 各卷已用明细紧凑档(DiskVolumeBreakdownView 同值):副卡头「各卷明细」+ 注记「合计 …」/
/// Data 卷在首(medium primary),其后其余同容器卷与「其他卷」差额(regular secondary);
/// 每行 = 标签 + 已用(12 semibold)在上、4pt 比例条在下(行内 6,行间 8)。
@MainActor
final class DiskVolumeBreakdownCardNSView: ObservingView {
    private let capacity: @MainActor () -> DiskCapacityReading?
    private let tint = Metric.disk.accentColor.ns
    private let header: CardSubHeaderView
    private let rowsStack = vstack([], spacing: 8)
    private var rows: [DiskVolumeRowView] = []
    private let empty = EmptyStateView()

    init(capacity: @escaping @MainActor () -> DiskCapacityReading?) {
        self.capacity = capacity
        header = CardSubHeaderView(symbolName: "externaldrive", title: "各卷明细", tint: tint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        empty.set(title: "容量对账暂不可用")
        let card = makeDetailCard([header, rowsStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let capacity = capacity()
        header.setNote(capacity.map { "合计 \(PulseFormat.diskCapacity($0.containerUsedBytes))" })
        rowsStack.isHidden = capacity == nil
        empty.isHidden = capacity != nil
        guard let capacity else { return }
        let volumes = [capacity.dataVolume] + capacity.otherVolumes + (capacity.unaccounted.map { [$0] } ?? [])
        syncRows(&rows, count: volumes.count, in: rowsStack) { DiskVolumeRowView(tint: tint) }
        for (index, (row, volume)) in zip(rows, volumes).enumerated() {
            row.set(volume, totalBytes: capacity.containerUsedBytes, prominent: index == 0)
        }
    }
}

/// 各卷行:标签(12,Data 卷 medium primary / 其余 regular secondary,吃剩余宽)+ 间距 8 +
/// 已用(12 semibold 等宽)首基线对齐;其下 4pt 比例条(间距 6)。
@MainActor
final class DiskVolumeRowView: NSStackView {
    private let label = makeNameLabel(weight: .regular)
    private let value = makeLabel(font: PFont.digits(12, .semibold), alignment: .right)
    private let bar: DiskVolumeBarView
    private var shownProminent: Bool?

    init(tint: NSColor) {
        bar = DiskVolumeBarView(tint: tint)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 首基线对齐行不放无基线的 spacer:标签低抱紧吃掉剩余宽(文字左对齐,视觉同 Spacer)。
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = makeDetailRow([label, value], spacing: 8, alignment: .firstBaseline)
        addArrangedSubview(line)
        addArrangedSubview(bar)
        line.fillWidth(of: self)
        bar.fillWidth(of: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ volume: DiskVolumeUsage, totalBytes: UInt64, prominent: Bool) {
        if shownProminent != prominent {
            shownProminent = prominent
            label.font = PFont.text(12, prominent ? .medium : .regular)
            label.textColor = prominent ? Ink.primary : Ink.secondary
            bar.prominent = prominent
        }
        label.setText(volume.label)
        value.setText(PulseFormat.diskCapacity(volume.usedBytes))
        bar.fraction = totalBytes > 0 ? Double(volume.usedBytes) / Double(totalBytes) : 0
    }
}

/// 各卷比例条:4pt 胶囊,轨道 `Surface.cardHigh`,填充 = 磁盘色(Data 卷 90% / 其余 55%),
/// 宽度 = 占容器已用比例(钳 ≤1,最少 2pt)。
@MainActor
final class DiskVolumeBarView: FlippedView {
    private let tint: NSColor
    var fraction: Double = 0 {
        didSet {
            if fraction != oldValue {
                needsDisplay = true
            }
        }
    }

    var prominent = false {
        didSet {
            if prominent != oldValue {
                needsDisplay = true
            }
        }
    }

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        fixed(height: 4)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Surface.cardHigh.ns.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let width = max(2, bounds.width * CGFloat(min(1, max(fraction, 0))))
        tint.withAlphaComponent(prominent ? 0.9 : 0.55).setFill()
        let fill = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}

/// 本地快照列表紧凑档(DiskSnapshotsCardView 同值):副卡头「本地快照」/ 最旧在前前 6 行
/// (行间 8),超出折叠成「…共 N 个」(10.5 tertiary);空 =「暂无本地快照」,
/// 读不到 =「快照信息不可用」(不伪造)。
@MainActor
final class DiskSnapshotsCardNSView: ObservingView {
    private static let visibleLimit = 6

    private let listing: @MainActor () -> DiskSnapshotListing?
    private let tint = Metric.disk.accentColor.ns
    private let rowsStack = vstack([], spacing: 8)
    private var rows: [DiskSnapshotRowView] = []
    private let moreLabel = makeLabel(font: PFont.text(10.5), color: Ink.tertiary)
    private let empty = EmptyStateView()

    init(listing: @escaping @MainActor () -> DiskSnapshotListing?) {
        self.listing = listing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let header = CardSubHeaderView(symbolName: "clock.arrow.circlepath", title: "本地快照", tint: tint)
        let card = makeDetailCard([header, rowsStack, moreLabel, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        var snapshots: [DiskSnapshot] = []
        switch listing() {
        case let .listing(list) where !list.isEmpty:
            snapshots = list
        case .listing:
            empty.set(title: "暂无本地快照")
        case .unavailable, nil:
            // 快照读不到(rc<0 / 非 APFS 卷):占位,不伪造。
            empty.set(title: "快照信息不可用")
        }
        rowsStack.isHidden = snapshots.isEmpty
        empty.isHidden = !snapshots.isEmpty
        moreLabel.isHidden = snapshots.count <= Self.visibleLimit
        moreLabel.setText("…共 \(snapshots.count) 个")
        let visible = Array(snapshots.prefix(Self.visibleLimit))
        syncRows(&rows, count: visible.count, in: rowsStack) { DiskSnapshotRowView(tint: tint) }
        for (row, snapshot) in zip(rows, visible) {
            row.set(snapshot)
        }
    }
}

/// 快照行(竖向间距 1):类型(12 medium;Time Machine = 磁盘色,其余 secondary)+ 间距 8
/// + 创建时间(10.5 secondary 等宽)首基线对齐;其下快照全名(10 tertiary,中间省略)。
@MainActor
final class DiskSnapshotRowView: NSStackView {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private let tint: NSColor
    private let kindLabel = makeNameLabel()
    private let dateLabel = makeLabel(font: PFont.digits(10.5), color: Ink.secondary, alignment: .right)
    private let nameLabel = makeLabel(font: PFont.text(10), color: Ink.tertiary)
    private var shownSnapshot: DiskSnapshot?

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 1
        translatesAutoresizingMaskIntoConstraints = false
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kindLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = makeDetailRow([kindLabel, dateLabel], spacing: 8, alignment: .firstBaseline)
        addArrangedSubview(line)
        addArrangedSubview(nameLabel)
        line.fillWidth(of: self)
        nameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ snapshot: DiskSnapshot) {
        guard shownSnapshot != snapshot else { return }
        shownSnapshot = snapshot
        kindLabel.setText(snapshot.kindTitle)
        kindLabel.setColor(snapshot.isTimeMachine ? tint : Ink.secondary)
        dateLabel.setText(Self.dateFormatter.string(from: snapshot.createdAt))
        nameLabel.setText(snapshot.name)
    }
}

/// 流量累计明细紧凑档(NetworkTotalsCardView 同值):副卡头「流量累计」+ 注记「7 天合计 …」/
/// 今日下行(primary 标签 + semibold 数值)、今日上行、7 天下行、7 天上行(secondary 标签 +
/// regular 数值),每行上下各 2 内距、行间 8;读数缺失安静占位。
@MainActor
final class NetworkTotalsCardNSView: ObservingView {
    private static let titles = ["今日下行", "今日上行", "7 天下行", "7 天上行"]

    private let totals: @MainActor () -> NetworkTotalsReading?
    private let header: CardSubHeaderView
    private let rowsStack = vstack([], spacing: 8)
    private var values: [NSTextField] = []
    private let empty = EmptyStateView()

    init(totals: @escaping @MainActor () -> NetworkTotalsReading?) {
        self.totals = totals
        header = CardSubHeaderView(symbolName: "network", title: "流量累计", tint: Metric.network.accentColor.ns)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (index, title) in Self.titles.enumerated() {
            let prominent = index == 0
            let label = makeLabel(title, font: PFont.text(12), color: prominent ? Ink.primary : Ink.secondary)
            let value = makeLabel(font: PFont.digits(12, prominent ? .semibold : .regular), alignment: .right)
            value.setContentHuggingPriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = makeDetailRow([label, spacer(), value], spacing: 0)
            row.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
            rowsStack.addArrangedSubview(row)
            row.fillWidth(of: rowsStack)
            values.append(value)
        }
        empty.set(title: "累计暂不可用")
        let card = makeDetailCard([header, rowsStack, empty])
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let totals = totals()
        header.setNote(totals.map { "7 天合计 \(PulseFormat.networkTotal($0.weekDownBytes + $0.weekUpBytes))" })
        rowsStack.isHidden = totals == nil
        empty.isHidden = totals != nil
        guard let totals else { return }
        let bytes = [totals.todayDownBytes, totals.todayUpBytes, totals.weekDownBytes, totals.weekUpBytes]
        for (value, amount) in zip(values, bytes) {
            value.setText(PulseFormat.networkTotal(amount))
        }
    }
}
