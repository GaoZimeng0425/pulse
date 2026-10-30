import AppKit

// MARK: - 走势图 AppKit 版(popover-appkit/01)

//
// 与 StripChartView / AreaTrendChartView(SwiftUI Canvas)同几何、同数值:
// 44 柱 strip(2px 柱距、2% 垫底、上圆角 2、轨道 tint 9% 圆角 8)与 56 点面积图
// (线 2px、线下 32%→0 渐变、4 条 8% 网格线、2% 垫底)。只在数据变化时重画。

/// 44 柱 strip 微柱走势:最新在最右,不足 44 个时左侧以 2% 垫底。
@MainActor
final class StripChartNSView: FlippedView {
    private static let slotCount = 44
    private static let barSpacing: CGFloat = 2
    private static let floorFraction: CGFloat = 0.02
    private static let barCornerRadius: CGFloat = 2

    private var values: [Double] = []
    private var tint: NSColor = .clear
    private var domainMax: Double?

    func set(values: [Double], tint: NSColor, domainMax: Double?) {
        let window = Array(values.suffix(Self.slotCount))
        guard window != self.values || tint != self.tint || domainMax != self.domainMax else { return }
        self.values = window
        self.tint = tint
        self.domainMax = domainMax
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let slots = Self.slotCount
        let spacing = Self.barSpacing
        let size = bounds.size
        let barWidth = max(1, (size.width - spacing * CGFloat(slots - 1)) / CGFloat(slots))
        let normalizer = domainMax ?? max(values.max() ?? 0, 1)

        tint.setFill()
        for slot in 0 ..< slots {
            let dataIndex = slot - (slots - values.count)
            let fraction: CGFloat = if dataIndex >= 0 {
                max(Self.floorFraction, CGFloat(min(max(values[dataIndex] / normalizer, 0), 1)))
            } else {
                Self.floorFraction
            }
            let barHeight = fraction * size.height
            let rect = CGRect(
                x: CGFloat(slot) * (barWidth + spacing),
                y: size.height - barHeight,
                width: barWidth,
                height: barHeight
            )
            let radius = min(Self.barCornerRadius, barWidth / 2, barHeight / 2)
            topRoundedRect(rect, radius: radius).fill()
        }
    }

    /// 仅上两角圆的矩形(flipped 坐标:minY 为顶)。
    private func topRoundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: 180, endAngle: 270
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: 270, endAngle: 360
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }
}

/// 56 点面积走势:线 tint 2px、线下 tint 32%→0 渐变、4 条水平网格线。
@MainActor
final class AreaTrendChartNSView: FlippedView {
    private static let pointCount = 56
    private static let floorFraction: CGFloat = 0.02
    private static let gridLineFractions: [CGFloat] = [0.08, 0.37, 0.66, 0.96]

    private var values: [Double] = []
    private var tint: NSColor = .clear
    private var domainMax: Double = 100

    func set(values: [Double], tint: NSColor, domainMax: Double) {
        let window = Array(values.suffix(Self.pointCount))
        let domain = max(domainMax, 1)
        guard window != self.values || tint != self.tint || domain != self.domainMax else { return }
        self.values = window
        self.tint = tint
        self.domainMax = domain
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.size
        let grid = NSBezierPath()
        for fraction in Self.gridLineFractions {
            let y = size.height * fraction
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: size.width, y: y))
        }
        grid.lineWidth = 1
        // 网格线:--line 口径(primary 8%),labelColor 动态随外观。
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        grid.stroke()

        let count = Self.pointCount
        guard !values.isEmpty else { return }
        var points: [NSPoint] = []
        points.reserveCapacity(count)
        for index in 0 ..< count {
            let dataIndex = index - (count - values.count)
            let normalized = dataIndex >= 0 ? min(max(values[dataIndex] / domainMax, 0), 1) : 0
            let fraction = max(Self.floorFraction, CGFloat(normalized))
            let x = size.width * CGFloat(index) / CGFloat(count - 1)
            points.append(NSPoint(x: x, y: size.height * (1 - fraction)))
        }

        let line = NSBezierPath()
        line.move(to: points[0])
        for point in points.dropFirst() {
            line.line(to: point)
        }
        let area = NSBezierPath()
        area.move(to: points[0])
        for point in points.dropFirst() {
            area.line(to: point)
        }
        area.line(to: NSPoint(x: points[count - 1].x, y: size.height))
        area.line(to: NSPoint(x: points[0].x, y: size.height))
        area.close()

        // flipped 视图里 angle 90 指向 +y = 视觉向下(顶 32% → 底 0)。
        NSGradient(starting: tint.withAlphaComponent(0.32), ending: tint.withAlphaComponent(0))?
            .draw(in: area, angle: 90)
        line.lineWidth = 2
        tint.setStroke()
        line.stroke()
    }
}
