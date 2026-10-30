import AppKit
import PulseCore
import SwiftUI

// MARK: - 内存双环 AppKit 版(popover-appkit/02)

//
// 与 RingCardView 紧凑档同值:卡头(徽章 + 标题)/ 竖向间距 12 / 环 104×104 + 图例横排间距 14。
// 数据唯一出处仍是 `RingCardView.memoryByType` / `.memoryByApp`(值类型工厂,只取其字段,
// 不渲染 SwiftUI):环心文字、分段、配色与主窗口同源。
//
// 扇区几何换算自 Swift Charts 的 SectorMark 参数:
// - 外径 = 绘区短边一半(Chart 无轴,绘区 = 104 框)、内径 = `innerRadius: .ratio(0.74)` × 外径;
// - 起点 12 点钟、顺时针,角度按字节占比(SectorMark 默认);
// - `angularInset: 1.2` = 每段两条径向边各向内平移 1.2pt(段间留等宽 2.4pt 缝,不是等角缝);
// - `cornerRadius(2.5)` = 每段四角 2.5pt 圆角(与内外圆及平移边相切的小圆)。
// 窄到放不下圆角的段按可容纳的最大圆角收小;连缝都放不下的段不画(与 Charts 缝吞窄段同形)。

/// 环形扇区绘制:只在分段(身份 + 字节)变化时重画。
@MainActor
final class RingSectorsNSView: FlippedView {
    private static let innerRatio: CGFloat = 0.74
    private static let angularInset: CGFloat = 1.2
    private static let cornerRadius: CGFloat = 2.5

    private var slices: [(value: Double, color: NSColor)] = []
    private var signature: [String] = []

    func set(_ ringSlices: [RingSlice]) {
        let next = ringSlices.map { "\($0.id):\($0.bytes)" }
        guard next != signature else { return }
        signature = next
        slices = ringSlices.map { (Double($0.bytes), $0.color.ns) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let total = slices.reduce(0) { $0 + $1.value }
        guard total > 0 else { return }
        let outer = min(bounds.width, bounds.height) / 2
        let geometry = SectorGeometry(
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            outer: outer,
            inner: outer * Self.innerRatio,
            inset: Self.angularInset
        )
        var start: CGFloat = 0
        for slice in slices {
            let span = CGFloat(slice.value / total) * 2 * .pi
            defer { start += span }
            guard span > 0, let path = geometry.path(from: start, to: start + span, corner: Self.cornerRadius) else {
                continue
            }
            // 动态色在 draw 里按当前外观解析(不转 CGColor)。
            slice.color.setFill()
            NSBezierPath(cgPath: path).fill()
        }
    }
}

/// 单段扇区路径。角度 θ 自 12 点钟起、顺时针为正(flipped 坐标,y 向下)。
private struct SectorGeometry {
    let center: CGPoint
    let outer: CGFloat
    let inner: CGFloat
    let inset: CGFloat

    /// θ 处、半径 ρ 的点。
    private func point(_ theta: CGFloat, _ rho: CGFloat) -> CGPoint {
        CGPoint(x: center.x + rho * sin(theta), y: center.y - rho * cos(theta))
    }

    /// θ 对应的 CG 角(flipped 坐标里角度递增 = 视觉顺时针)。
    private func cgAngle(_ theta: CGFloat) -> CGFloat {
        theta - .pi / 2
    }

    /// 窄段可容纳的最大圆角(圆角圆须同时塞进内外两侧的半段角里)。
    private func fittingCorner(span: CGFloat, preferred: CGFloat) -> CGFloat? {
        let s = sin(min(span / 2, .pi / 2))
        guard s * inner > inset else { return nil }
        let innerLimit = s < 1 ? (s * inner - inset) / (1 - s) : preferred
        let outerLimit = (s * outer - inset) / (1 + s)
        return max(0, min(preferred, innerLimit, outerLimit, (outer - inner) / 2))
    }

    func path(from theta0: CGFloat, to theta1: CGFloat, corner preferred: CGFloat) -> CGPath? {
        guard let c = fittingCorner(span: theta1 - theta0, preferred: preferred) else { return nil }
        let d = inset
        // 圆角圆心相对径向边的半角偏移:外侧圆心在半径 R−c,内侧在 r+c,离平移边 d+c。
        let alphaOuter = asin(min((d + c) / (outer - c), 1))
        let alphaInner = asin(min((d + c) / (inner + c), 1))
        let path = CGMutablePath()

        // 起边外角:圆心 θ0+αo;自"朝起边"方向(θ0+π)扫到外向径向。
        let outerStart = point(theta0 + alphaOuter, outer - c)
        path.addArc(
            center: outerStart, radius: c,
            startAngle: theta0 + .pi, endAngle: cgAngle(theta0 + alphaOuter) + 2 * .pi,
            clockwise: false
        )
        // 外弧。
        path.addArc(
            center: center, radius: outer,
            startAngle: cgAngle(theta0 + alphaOuter), endAngle: cgAngle(theta1 - alphaOuter),
            clockwise: false
        )
        // 止边外角:自外向径向扫到"朝止边"方向(θ1)。
        let outerEnd = point(theta1 - alphaOuter, outer - c)
        path.addArc(
            center: outerEnd, radius: c,
            startAngle: cgAngle(theta1 - alphaOuter), endAngle: theta1,
            clockwise: false
        )
        // 止边内角:自"朝止边"扫到内向径向。
        let innerEnd = point(theta1 - alphaInner, inner + c)
        path.addArc(
            center: innerEnd, radius: c,
            startAngle: theta1, endAngle: cgAngle(theta1 - alphaInner) + .pi,
            clockwise: false
        )
        // 内弧(逆向)。
        path.addArc(
            center: center, radius: inner,
            startAngle: cgAngle(theta1 - alphaInner), endAngle: cgAngle(theta0 + alphaInner),
            clockwise: true
        )
        // 起边内角:自内向径向扫到"朝起边"方向。
        let innerStart = point(theta0 + alphaInner, inner + c)
        path.addArc(
            center: innerStart, radius: c,
            startAngle: cgAngle(theta0 + alphaInner) + .pi, endAngle: theta0 + .pi,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// 图例图标(16×16):应用图标 / 类别砖(圆角 24%、白符号 52%)/ 8pt 色点。
@MainActor
private final class LegendIconView: FlippedView {
    private static let size: CGFloat = 16
    private let imageView = NSImageView()
    private var key = ""
    private var fill: NSColor?
    private var isDot = false

    init() {
        super.init(frame: .zero)
        fixed(width: Self.size, height: Self.size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ slice: RingSlice) {
        switch slice.icon {
        case let .app(path):
            guard key != "app:\(path)" else { return }
            key = "app:\(path)"
            imageView.image = AppIconCache.icon(forBundle: path, pointSize: Self.size)
            imageView.contentTintColor = nil
            imageView.isHidden = false
            fill = nil
            isDot = false
        case let .symbol(name, color):
            // 色随身份走,身份变才重写(颜色同 key 同值)。
            guard key != "symbol:\(name):\(slice.id)" else { return }
            key = "symbol:\(name):\(slice.id)"
            imageView.image = symbolImage(name, size: Self.size * 0.52, weight: .semibold)
            imageView.contentTintColor = .white
            imageView.isHidden = false
            fill = color.ns
            isDot = false
        case .dot:
            guard key != "dot:\(slice.id)" else { return }
            key = "dot:\(slice.id)"
            imageView.isHidden = true
            fill = slice.color.ns
            isDot = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        if isDot {
            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 8, height: 8)).fill()
        } else {
            let radius = Self.size * 0.24
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// 图例一行:图标 16 / 名称(中段省略)/ 弹性 ≥4 / 字节 semibold 等宽 / 占比 secondary ≥30 右对齐;
/// 12pt,间距 6。
@MainActor
private final class LegendRowView: NSStackView {
    private let icon = LegendIconView()
    private let name = makeLabel(font: PFont.text(12))
    private let bytes = makeLabel(font: PFont.digits(12, .semibold), alignment: .right)
    private let percent = makeRowValue(minWidth: 30)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bytes.setContentHuggingPriority(.required, for: .horizontal)
        bytes.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, name, spacer(minLength: 4), bytes, percent] {
            addArrangedSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(_ slice: RingSlice) {
        icon.set(slice)
        name.setText(slice.name)
        bytes.setText(PulseFormat.systemMemory(slice.bytes))
        percent.setText("\(Int((slice.fraction * 100).rounded()))%")
    }
}

/// 环形卡:卡头 + 环(环心 16pt 大数字 + 10.5 secondary 两字说明)+ 图例;无分段时卡内空态。
@MainActor
final class RingCardNSView: ObservingView {
    private static let ringSize: CGFloat = 104

    private let provider: @MainActor () -> RingCardView
    private let sectors = RingSectorsNSView()
    private let figure = FigureView(size: FigureSize.ringCompact)
    private let caption = makeLabel(font: PFont.text(10.5), color: Ink.secondary, alignment: .center)
    private let legend = vstack([], spacing: 6)
    private var rows: [LegendRowView] = []
    private let ringRow: NSStackView
    private let empty = EmptyStateView()

    /// `provider` 返回 RingCardView 工厂值(只读字段,不渲染)。
    init(_ provider: @escaping @MainActor () -> RingCardView) {
        self.provider = provider
        let initial = provider()
        sectors.fixed(width: Self.ringSize, height: Self.ringSize)
        let center = vstack([figure, caption], spacing: 2, alignment: .centerX)
        sectors.addSubview(center)
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: sectors.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: sectors.centerYAnchor),
        ])
        ringRow = hstack([sectors, legend], spacing: 14)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        empty.set(title: "暂无内存数据")
        let header = makeCardHeader(symbolName: initial.symbolName, title: initial.title, tint: initial.tint.ns)
        let body = vstack([header, ringRow, empty], spacing: 12)
        for view in [header, ringRow, empty] {
            view.fillWidth(of: body)
        }
        let card = CardView(content: body)
        addSubview(card)
        card.pin(to: self)
        sectors.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func update() {
        let ring = provider()
        let isEmpty = ring.slices.isEmpty
        ringRow.isHidden = isEmpty
        empty.isHidden = !isEmpty
        guard !isEmpty else { return }
        figure.set(value: ring.centerValue, unit: ring.centerUnit)
        caption.setText(ring.centerCaption)
        sectors.set(ring.slices)
        setRows(ring.slices)
    }

    private func setRows(_ slices: [RingSlice]) {
        while rows.count < slices.count {
            let row = LegendRowView()
            rows.append(row)
            legend.addArrangedSubview(row)
            row.fillWidth(of: legend)
        }
        while rows.count > slices.count {
            rows.removeLast().removeFromSuperview()
        }
        for (row, slice) in zip(rows, slices) {
            row.set(slice)
        }
    }
}

extension RingCardNSView {
    /// 内存构成(by Type):环心 = 已用占比。
    static func memoryByType(_ monitor: SystemMonitor) -> RingCardNSView {
        RingCardNSView { RingCardView.memoryByType(monitor.memory, isCompact: true) }
    }

    /// 按应用(by App):环心 = 全部组内存合计;分段走 tab 内容折叠(与 MetricTabStack 同源)。
    static func memoryByApp(_ model: DashboardModel) -> RingCardNSView {
        RingCardNSView {
            let content = model.content(tab: .memory)
            return RingCardView.memoryByApp(
                segments: content.memorySegments,
                totalBytes: content.memoryTotalBytes,
                isCompact: true
            )
        }
    }
}
