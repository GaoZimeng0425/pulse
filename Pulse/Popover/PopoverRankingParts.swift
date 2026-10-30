import AppKit
import PulseCore
import SwiftUI

// MARK: - 排行列表通用零件 AppKit 版(popover-appkit/03)

//
// 与 RankingList.swift 的 RankingListCard / RankingListRow 一一对应,只取紧凑档:
// 卡内标题(12.5 semibold,所在页指标色)→ 表头「应用 | 指标名」→ 行 → 可选注脚,
// 空态在卡内。度量一律读 `RankingListMetrics`(两处同源:改一处,主窗口与弹窗同改)。
// 组排行(PopoverGroupRanking)与模块排行(PopoverModuleRanking)共用本文件的卡壳与行。

/// 紧凑档常量:全部取自 `RankingListMetrics(compact: true)`,这里只做命名。
@MainActor
enum RankingRowMetrics {
    static let spacing = RankingListMetrics.spacing(compact: true)
    static let iconSize = RankingListMetrics.iconSize(compact: true)
    static let meterWidth = RankingListMetrics.meterWidth(compact: true)
    static let valueFontSize = RankingListMetrics.valueFontSize(compact: true)
    static let valueWidth = RankingListMetrics.valueWidth(compact: true)
    static let trailingWidth = RankingListMetrics.trailingWidth
    static let rowInset = RankingListMetrics.rowInset
    /// 紧凑档行竖向内距(RankingListRow `.padding(.vertical, isCompact ? 5 : 7)`)。
    static let rowVerticalInset: CGFloat = 5
}

// MARK: - 卡壳

/// 排行卡外壳(RankingListCard 紧凑档):竖排间距 2;标题下 `.padding(.bottom, 6)`、
/// 表头下 `.padding(.bottom, 2)`、注脚上 `.padding(.top, 6)` 折成自定义间距。
/// 行容器 `rowsStack` 由调用方填充;空 / 非空切换只改显隐。
@MainActor
final class RankingCardShell: NSView {
    let rowsStack = vstack([], spacing: 2)
    private let titleLabel = makeLabel(font: PFont.text(12.5, .semibold))
    private let headerLeft = makeLabel("应用", font: PFont.text(10.5, .medium), color: Ink.tertiary)
    private let headerRight = makeLabel(font: PFont.text(10.5, .medium), color: Ink.tertiary, alignment: .right)
    private let header: NSStackView
    private let empty = EmptyStateView()
    private let footnoteLabel = makeLabel(font: PFont.text(10.5), color: Ink.tertiary)
    private var currentEmpty: (String, String?)?

    init(title: String) {
        header = hstack([headerLeft, spacer(), headerRight], spacing: 8)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        // 表头右列对齐数值列右缘:越过行尾列(行内距 + 行间距 + 行尾 30)。
        header.edgeInsets = NSEdgeInsets(
            top: 0,
            left: RankingRowMetrics.rowInset,
            bottom: 0,
            right: RankingRowMetrics.rowInset + RankingRowMetrics.spacing + RankingRowMetrics.trailingWidth
        )
        let body = vstack([titleLabel, header, rowsStack, empty, footnoteLabel], spacing: 2)
        body.setCustomSpacing(2 + 6, after: titleLabel)
        body.setCustomSpacing(2 + 2, after: header)
        body.setCustomSpacing(2 + 6, after: rowsStack)
        body.setCustomSpacing(2 + 6, after: empty)
        for view in [header, rowsStack, empty] {
            view.fillWidth(of: body)
        }
        footnoteLabel.isHidden = true
        let card = CardView(content: body)
        addSubview(card)
        card.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setTitle(_ title: String, accent: NSColor) {
        titleLabel.setText(title)
        titleLabel.setColor(accent)
    }

    func setValueLabel(_ text: String) {
        headerRight.setText(text)
    }

    func setFootnote(_ text: String?) {
        footnoteLabel.setText(text ?? "")
        footnoteLabel.isHidden = text == nil
    }

    /// 空 / 非空切换:空时表头与行区隐藏、画卡内空态。
    func setEmpty(_ isEmpty: Bool, message: RankingEmptyMessage) {
        if header.isHidden != isEmpty {
            header.isHidden = isEmpty
            rowsStack.isHidden = isEmpty
        }
        if empty.isHidden == isEmpty {
            empty.isHidden = !isEmpty
        }
        if isEmpty, currentEmpty?.0 != message.title || currentEmpty?.1 != message.detail {
            currentEmpty = (message.title, message.detail)
            empty.set(title: message.title, detail: message.detail)
        }
    }
}

// MARK: - 行

/// 排行行(RankingListRow 紧凑档):图标 18 + 名称(12.5 medium,中间省略)/ 副文
/// (10.5 secondary)| 弹性空白(≥8)| meter 52 + 定宽数值列 | 行尾 30pt 列(恒占位)。
///
/// **整行一次 `draw` 画完、行高固定**(popover-appkit/09 实测):总览排行常有上百行,
/// 每行拆成 8 个子视图时,每轮文字变化都触发全栈 Auto Layout、滚动时新露出的行逐个
/// 重画,滚动实测 48%。单视图下刷新只标脏、零布局,屏外行的重画推迟到滚进视野。
/// 交互(悬停 / 点击 / 结束按钮)由子类与卡片加在外面。
@MainActor
class RankingRowNSView: FlippedView {
    private static let nameFont = PFont.text(RankingRowMetrics.valueFontSize, .medium)
    private static let subtitleFont = PFont.text(10.5)
    private static let valueFont = PFont.digits(RankingRowMetrics.valueFontSize, .semibold)
    /// 文字行高与 NSTextField 标签的固有高度同口径(拆视图版实测行距不变)。
    private static let nameHeight = NSTextField(labelWithString: "Ag").then { $0.font = nameFont }.intrinsicContentSize
        .height
    private static let subtitleHeight = NSTextField(labelWithString: "Ag").then { $0.font = subtitleFont }
        .intrinsicContentSize.height
    private static let textGap: CGFloat = 1
    static let rowHeight = max(RankingRowMetrics.iconSize, nameHeight + textGap + subtitleHeight)
        + RankingRowMetrics.rowVerticalInset * 2
    /// 高负载圈红:同色 1pt 胶囊描边、负内距外扩 4pt(随文不占版)。
    private static let ringOutset: CGFloat = 4
    private static let minimumValueScale: CGFloat = 0.8

    private var name = ""
    private var subtitle = ""
    private var icon: RankingIconSource?
    private var iconImage: NSImage?
    private var meterFraction: Double = 0
    private var tint: NSColor = .clear
    private var valueText = ""
    private var alertsHighLoad = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// 行尾 30pt 列的矩形(子类在这里摆结束按钮 / 画展开箭头)。
    var trailingRect: NSRect {
        let width = RankingRowMetrics.trailingWidth
        return NSRect(x: bounds.maxX - RankingRowMetrics.rowInset - width, y: 0, width: width, height: bounds.height)
    }

    /// 写一行内容:全部字段与上次相同则不重画(采样轮刷新只改内容,不重建行)。
    func setContent(
        name: String,
        subtitle: String,
        icon: RankingIconSource,
        meterFraction: Double,
        tint: NSColor,
        valueText: String,
        alertsHighLoad: Bool
    ) {
        if icon != self.icon {
            self.icon = icon
            iconImage = icon.image(size: RankingRowMetrics.iconSize)
            needsDisplay = true
        }
        guard name != self.name || subtitle != self.subtitle || meterFraction != self.meterFraction
            || tint != self.tint || valueText != self.valueText || alertsHighLoad != self.alertsHighLoad
        else { return }
        self.name = name
        self.subtitle = subtitle
        self.meterFraction = meterFraction
        self.tint = tint
        self.valueText = valueText
        self.alertsHighLoad = alertsHighLoad
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = RankingRowMetrics.spacing
        let inset = RankingRowMetrics.rowInset
        let midY = bounds.midY
        let trailing = trailingRect
        let valueRect = NSRect(
            x: trailing.minX - s - RankingRowMetrics.valueWidth,
            y: 0,
            width: RankingRowMetrics.valueWidth,
            height: bounds.height
        )
        let meterWidth = RankingRowMetrics.meterWidth
        let meterRect = NSRect(x: valueRect.minX - s - meterWidth, y: midY - 3, width: meterWidth, height: 6)
        let iconSize = RankingRowMetrics.iconSize
        let iconRect = NSRect(x: inset, y: midY - iconSize / 2, width: iconSize, height: iconSize)
        // 文字列吃剩余宽度:与 meter 之间隔 行间距 + 弹性空白(≥8)+ 行间距。
        let textX = iconRect.maxX + s
        let textWidth = max(0, meterRect.minX - s - 8 - s - textX)

        drawIcon(in: iconRect)
        drawText(textX: textX, width: textWidth)
        drawMeter(in: meterRect)
        drawValue(in: valueRect)
    }

    private func drawIcon(in rect: NSRect) {
        switch icon {
        case .app:
            iconImage?.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        case let .tile(_, color):
            // CategoryIconTile 同配方:圆角 = 边长 × 0.24 的实心方块 + 白符号(边长 × 0.52 semibold)。
            color.ns.setFill()
            let radius = rect.width * 0.24
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            if let symbol = iconImage {
                let size = symbol.size
                symbol.draw(
                    in: NSRect(
                        x: rect.midX - size.width / 2,
                        y: rect.midY - size.height / 2,
                        width: size.width,
                        height: size.height
                    ),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                )
            }
        case nil:
            break
        }
    }

    private func drawText(textX: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let blockHeight = Self.nameHeight + Self.textGap + Self.subtitleHeight
        let top = bounds.midY - blockHeight / 2
        Self.draw(
            name,
            font: Self.nameFont,
            color: Ink.primary,
            truncation: .byTruncatingMiddle,
            in: NSRect(x: textX, y: top, width: width, height: Self.nameHeight)
        )
        Self.draw(
            subtitle,
            font: Self.subtitleFont,
            color: Ink.secondary,
            truncation: .byTruncatingTail,
            in: NSRect(
                x: textX,
                y: top + Self.nameHeight + Self.textGap,
                width: width,
                height: Self.subtitleHeight
            )
        )
    }

    private static func draw(
        _ text: String,
        font: NSFont,
        color: NSColor,
        truncation: NSLineBreakMode,
        in rect: NSRect
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }

    private func drawMeter(in rect: NSRect) {
        let r = rect.height / 2
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        let width = rect.width * CGFloat(min(max(meterFraction, 0), 1))
        guard width > 0 else { return }
        tint.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
            xRadius: r,
            yRadius: r
        ).fill()
    }

    /// 定宽数值列:右对齐;超宽先缩字(最小 0.8,`.minimumScaleFactor(0.8)` 同义)再截断。
    private func drawValue(in column: NSRect) {
        let color = alertsHighLoad ? Surface.negative.ns : Ink.primary
        var font = Self.valueFont
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var size = (valueText as NSString).size(withAttributes: attributes)
        if size.width > column.width {
            let scale = max(Self.minimumValueScale, column.width / size.width)
            font = PFont.digits(RankingRowMetrics.valueFontSize * scale, .semibold)
            attributes[.font] = font
            size = (valueText as NSString).size(withAttributes: attributes)
        }
        let width = min(size.width, column.width)
        let textRect = NSRect(
            x: column.maxX - width,
            y: column.midY - size.height / 2,
            width: width,
            height: size.height
        )
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .right
        attributes[.paragraphStyle] = style
        (valueText as NSString).draw(in: textRect, withAttributes: attributes)
        guard alertsHighLoad else { return }
        // strokeBorder:描边落在外扩矩形之内(半线宽内缩)。
        let ring = textRect.insetBy(dx: -Self.ringOutset, dy: -Self.ringOutset).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}

// MARK: - 图标来源

/// 行图标:App 行取真实应用图标(AppIconCache 预栅格化缓存,与 SwiftUI 行同一取法),
/// 其余取类别瓦片(底色在绘制时按外观解析;白符号预渲染一次)。
enum RankingIconSource: Equatable {
    case app(bundlePath: String)
    case tile(symbolName: String, color: Color)

    /// App 行(有 bundle 路径)取应用图标;其余取类别瓦片。
    static func make(bundlePath: String?, tileSymbol: String, tileColor: Color) -> Self {
        if let bundlePath {
            return .app(bundlePath: bundlePath)
        }
        return .tile(symbolName: tileSymbol, color: tileColor)
    }

    /// App = 应用图标;瓦片 = 白色符号(瓦片底色另画)。
    @MainActor
    func image(size: CGFloat) -> NSImage? {
        switch self {
        case let .app(bundlePath):
            AppIconCache.icon(forBundle: bundlePath, pointSize: size)
        case let .tile(symbolName, _):
            NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                )
        }
    }
}

private extension NSTextField {
    func then(_ configure: (NSTextField) -> Void) -> NSTextField {
        configure(self)
        return self
    }
}
