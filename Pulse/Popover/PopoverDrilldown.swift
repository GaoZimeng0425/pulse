import AppKit
import PulseCore
import SwiftUI

// MARK: - 组内下钻 AppKit 版(popover-appkit/03;ProcessDrilldownView 同值)

/// 组排行行展开后的下钻区:组内进程平铺列表(顺序 = 进程 CPU% 降序,DrilldownState
/// 既定)+ 选中进程的详情。只读最近一轮采样;进程行按位置复用,行数变化才增删,
/// 详情视图只有一个,随选中行移位。底 = primary 4% 圆角 10,上下内距 4。
@MainActor
final class PopoverDrilldownView: FlippedView {
    /// 点进程行:传入新的选中 pid(再点同一行 = nil 收起)。
    var onSelect: ((pid_t?) -> Void)?
    /// 详情"结束进程":请求上抛,KillRequestFlow 的 NSAlert 关口把关。
    var onEndProcess: ((KillTarget) -> Void)?

    private let stack = vstack([], spacing: 0)
    private var rowViews: [ProcessRowNSView] = []
    private let detailView = ProcessDetailNSView()
    private var selectedPID: pid_t?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        addSubview(stack)
        stack.pin(to: self)
        detailView.onEnd = { [weak self] target in self?.onEndProcess?(target) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.primary.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    func set(group: ProcessGroup, drilldown: DrilldownState, selectedPID: pid_t?) {
        self.selectedPID = selectedPID
        let rows = drilldown.rows(for: group)
        syncRowCount(rows.count)
        var selectedIndex: Int?
        for (index, (view, row)) in zip(rowViews, rows).enumerated() {
            let isSelected = row.pid == selectedPID
            view.set(row: row, isSelected: isSelected)
            if isSelected {
                selectedIndex = index
            }
        }
        placeDetail(after: selectedIndex, detail: selectedPID.flatMap { drilldown.detail(for: $0) })
    }

    private func syncRowCount(_ count: Int) {
        while rowViews.count < count {
            let view = ProcessRowNSView()
            view.onToggle = { [weak self] pid in
                guard let self else { return }
                onSelect?(selectedPID == pid ? nil : pid)
            }
            rowViews.append(view)
        }
        while rowViews.count > count {
            rowViews.removeLast().removeFromSuperview()
        }
        // 新增行追加到栈尾(行之间的相对顺序不变;详情位置由 placeDetail 校正)。
        for view in rowViews where view.superview == nil {
            stack.addArrangedSubview(view)
            view.fillWidth(of: stack)
        }
    }

    /// 详情紧跟选中行;无选中或进程已退出(detail 为 nil)时安静收起。
    private func placeDetail(after index: Int?, detail: ProcessDetailModel?) {
        guard let index, let detail else {
            if detailView.superview != nil {
                detailView.removeFromSuperview()
            }
            return
        }
        detailView.set(detail)
        let rowView = rowViews[index]
        let arranged = stack.arrangedSubviews
        if let current = arranged.firstIndex(of: detailView), current > 0, arranged[current - 1] === rowView {
            return
        }
        if detailView.superview != nil {
            detailView.removeFromSuperview()
        }
        guard let rowPosition = stack.arrangedSubviews.firstIndex(of: rowView) else { return }
        stack.insertArrangedSubview(detailView, at: rowPosition + 1)
        detailView.fillWidth(of: stack)
    }
}

// MARK: - 进程行

/// 进程行(ProcessRowView 弹窗形态,无 meter):进程名 / pid / 宿主徽标(可选)| 弹性
/// 空白(≥12)| CPU%(最小宽 44)/ 内存(最小宽 56,secondary)。字号 caption 10、
/// 横 12 竖 4 内距;选中 = 强调色 15% 圆角 8 底。整行可点。
@MainActor
final class ProcessRowNSView: FlippedView {
    var onToggle: ((pid_t) -> Void)?

    private let nameLabel = makeLabel(font: PFont.text(10))
    private let pidLabel = makeLabel(font: PFont.digits(10), color: Ink.secondary)
    private let hostIcon = NSImageView()
    private let hostName = makeLabel(font: PFont.text(10), color: Ink.secondary)
    private let hostBadge: NSStackView
    private let cpuLabel = makeRowValue(minWidth: 44, color: Ink.primary)
    private let memoryLabel = makeRowValue(minWidth: 56, color: Ink.secondary)
    private var pid: pid_t = 0
    private var hostPath: String?
    private var isSelected = false

    override init(frame: NSRect) {
        hostIcon.translatesAutoresizingMaskIntoConstraints = false
        hostIcon.imageScaling = .scaleProportionallyUpOrDown
        hostIcon.fixed(width: 14, height: 14)
        hostBadge = hstack([hostIcon, hostName], spacing: 6)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        cpuLabel.font = PFont.digits(10)
        memoryLabel.font = PFont.digits(10)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostName.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        pidLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hostBadge.isHidden = true
        let row = hstack(
            [nameLabel, pidLabel, hostBadge, spacer(minLength: 12), cpuLabel, memoryLabel],
            spacing: 8
        )
        addSubview(row)
        row.pin(to: self, insets: NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(row: ProcessRowModel, isSelected: Bool) {
        pid = row.pid
        nameLabel.setText(row.name)
        pidLabel.setText("\(row.pid)")
        cpuLabel.setText(PulseFormat.cpuPercent(row.cpuPercent))
        memoryLabel.setText(PulseFormat.memory(row.memoryBytes))
        if row.hostBundlePath != hostPath {
            hostPath = row.hostBundlePath
            hostBadge.isHidden = hostPath == nil
            if let path = hostPath {
                hostIcon.image = AppIconCache.icon(forBundle: path, pointSize: 14)
                hostName.setText(Self.hostName(forBundle: path))
            }
        }
        if isSelected != self.isSelected {
            self.isSelected = isSelected
            needsDisplay = true
        }
        setAccessibilityLabel("\(row.name),pid \(row.pid)")
    }

    /// 宿主名:CFBundleName 读取器(App 组显示名同通道,已缓存),缺省退 bundle 目录名
    /// 去 .app 后缀(ProcessRowView.hostName 同口径)。
    private static func hostName(forBundle bundlePath: String) -> String {
        if let injected = BundleDisplayNameReader.shared.displayName(forBundleDirectory: bundlePath) {
            return injected
        }
        let directoryName = String(bundlePath.split(separator: "/").last ?? Substring(bundlePath))
        return directoryName.hasSuffix(".app") ? String(directoryName.dropLast(4)) : directoryName
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onToggle?(pid)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?(pid)
        return true
    }
}

// MARK: - 进程详情

/// 进程详情(ProcessDetailView 同值):父链 / 目录 / argv / 时长四个字段(标签 30 宽
/// secondary,字段间距 6)+ 右下"结束进程"。字号 caption 10;内距 12,底 = primary 6%
/// 圆角 8;外距横 6、底 4。文字可选中复制;argv 一个参数一行,超 88pt 纵向滚动。
@MainActor
final class ProcessDetailNSView: FlippedView {
    var onEnd: ((KillTarget) -> Void)?

    private let box = DetailBoxView()
    private let chainLabel = ProcessDetailNSView.valueLabel(truncatesMiddle: true)
    private let cwdLabel = ProcessDetailNSView.valueLabel(truncatesMiddle: true)
    private let argvBox = ArgvBoxView()
    private let argvEmpty = makeLabel("不可读", font: PFont.text(10), color: Ink.tertiary)
    private let copyButton = NSButton()
    private let uptimeLabel = makeLabel(font: PFont.digits(10))
    private let endButton = NSButton()
    private var argv: [String] = []
    private var target: KillTarget?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        configureButtons()
        argvEmpty.isHidden = true
        let argvRow = hstack([argvBox, argvEmpty, copyButton], spacing: 6, alignment: .top)
        argvBox.setContentHuggingPriority(.init(1), for: .horizontal)
        let endRow = hstack([spacer(), endButton], spacing: 8)
        let fields = [
            field("父链", chainLabel),
            field("目录", cwdLabel),
            field("argv", argvRow),
            field("时长", uptimeLabel),
            endRow,
        ]
        let body = vstack(fields, spacing: 6)
        for view in fields {
            view.fillWidth(of: body)
        }
        box.addSubview(body)
        body.pin(to: box, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        addSubview(box)
        box.pin(to: self, insets: NSEdgeInsets(top: 0, left: 6, bottom: 4, right: 6))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ detail: ProcessDetailModel) {
        let process = detail.process
        target = process.killTarget
        chainLabel.setText(detail.parentChainText)
        cwdLabel.setText(process.cwd ?? "不可读")
        cwdLabel.setColor(process.cwd == nil ? Ink.tertiary : Ink.primary)
        if process.argv != argv {
            argv = process.argv
            argvBox.isHidden = argv.isEmpty
            argvEmpty.isHidden = !argv.isEmpty
            copyButton.isHidden = argv.isEmpty
            argvBox.setArguments(argv)
        }
        uptimeLabel.setText(PulseFormat.uptime(startedAt: process.startTime, now: Date()))
    }

    private func configureButtons() {
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.image = symbolImage("doc.on.doc", size: 10)
        copyButton.contentTintColor = Ink.secondary
        copyButton.imagePosition = .imageOnly
        copyButton.toolTip = "复制完整命令行"
        copyButton.setAccessibilityLabel("复制完整命令行")
        copyButton.target = self
        copyButton.action = #selector(copyArgv)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        // `.bordered` + `.tint(negative)` + `.controlSize(.small)`:标准圆角按钮,
        // 图标与文字取 state-negative(caption 10 semibold)。
        endButton.bezelStyle = .push
        endButton.controlSize = .small
        endButton.image = symbolImage("xmark.octagon", size: 10, weight: .semibold)
        endButton.imagePosition = .imageLeading
        endButton.contentTintColor = Surface.negative.ns
        endButton.attributedTitle = NSAttributedString(string: "结束进程", attributes: [
            .font: PFont.text(10, .semibold),
            .foregroundColor: Surface.negative.ns,
        ])
        endButton.toolTip = "结束该进程(需确认)"
        endButton.target = self
        endButton.action = #selector(endProcess)
        endButton.translatesAutoresizingMaskIntoConstraints = false
    }

    /// 复制按钮:整条 argv 以空格连接成命令行写入剪贴板(ProcessDetailView 同义)。
    @objc private func copyArgv() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(argv.joined(separator: " "), forType: .string)
    }

    @objc private func endProcess() {
        if let target {
            onEnd?(target)
        }
    }

    private func field(_ label: String, _ value: NSView) -> NSStackView {
        let title = makeLabel(label, font: PFont.text(10), color: Ink.secondary)
        title.fixed(width: 30)
        value.setContentHuggingPriority(.init(1), for: .horizontal)
        return hstack([title, value], spacing: 8, alignment: .top)
    }

    private static func valueLabel(truncatesMiddle: Bool) -> NSTextField {
        let label = makeLabel(font: PFont.text(10))
        label.isSelectable = true
        if truncatesMiddle {
            label.lineBreakMode = .byTruncatingMiddle
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// 详情底块:primary 6% 圆角 8。
@MainActor
private final class DetailBoxView: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.primary.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// argv 区:一个参数一段(段距 2,长参数折行不破坏布局),可选中;内容高超过 88pt
/// 时纵向滚动(SwiftUI `ScrollView` + `.frame(maxHeight: 88)` 同义)。高度随宽度量算,
/// 只在宽度或内容变了时重量。
@MainActor
private final class ArgvBoxView: FlippedView {
    private static let maxHeight: CGFloat = 88
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    private var measuredWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        addSubview(scrollView)
        scrollView.pin(to: self)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setArguments(_ argv: [String]) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 2
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: argv.joined(separator: "\n"),
            attributes: [.font: PFont.text(10), .foregroundColor: Ink.primary, .paragraphStyle: style]
        ))
        measuredWidth = -1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, width != measuredWidth,
              let container = textView.textContainer, let manager = textView.layoutManager
        else { return }
        measuredWidth = width
        textView.frame.size.width = width
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let contentHeight = ceil(manager.usedRect(for: container).height)
        textView.frame.size.height = contentHeight
        let height = min(contentHeight, Self.maxHeight)
        if heightConstraint.constant != height {
            heightConstraint.constant = height
        }
    }
}
