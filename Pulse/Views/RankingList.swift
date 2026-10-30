import AppKit
import PulseCore
import SwiftUI

// MARK: - 排行列表通用组件(2026-10-20 用户拍板:各 tab 的排序列表一个样)

//
// 组排行(当前最忙,可展开 / 可结束)与模块排行(能耗影响 / 读写最多 / 每进程流量,
// 只读)共用同一张卡与同一行配方:卡内标题(12.5 semibold,所在页指标色)→ 表头
// (应用 | 指标名)→ 行 → 可选注脚;空态在卡内。行尾恒留一列(组排行放结束按钮与
// 展开箭头,模块排行留空),所有排行的 meter 与数值落在同一条竖线上。
// 卡形态:full = {rounded.card} 18 + {spacing.card-padding} 16;compact(弹窗)=
// {rounded.card-compact} 12 + {spacing.card-padding-compact} 12。

/// 数值列口径:同一张卡内各行同宽(竖线对齐),不同卡按自己的读数量宽。
enum RankingValueColumn: CustomStringConvertible {
    /// 组排行:CPU%(十余核满载 4 位)/ 内存。
    case standard
    /// 模块排行:速率与 CPU 时间(最宽 "999.9 MB/s")。
    case rate

    /// 量宽样本:各口径现实最宽读数。
    var widestReadings: [String] {
        switch self {
        case .standard: ["9999%", "99.9 GB", "999 MB"]
        case .rate: ["999.9 MB/s"]
        }
    }

    var description: String {
        switch self {
        case .standard: "标准"
        case .rate: "速率"
        }
    }
}

/// 行配方的度量(两档):卡、行、表头三处共用,改一处即全部对齐。
enum RankingListMetrics {
    /// 行尾列宽 = 结束按钮 + 间距 + 展开箭头 10;模块排行留同宽空列。
    /// 全尺寸 18 + 2 + 10;弹窗 14 + 0 + 10(2026-10-30 用户拍板:右侧图标收紧)。
    static func trailingWidth(compact: Bool) -> CGFloat {
        compact ? 24 : 30
    }

    /// 行尾结束按钮的点击框边长(图标字号不变,只收紧留白)。
    static func endButtonSize(compact: Bool) -> CGFloat {
        compact ? 14 : 18
    }

    static func trailingControlSpacing(compact: Bool) -> CGFloat {
        compact ? 0 : 2
    }

    /// 行内水平内距(表头与之对齐)。
    static let rowInset: CGFloat = 6

    static func spacing(compact: Bool) -> CGFloat {
        compact ? 8 : 10
    }

    /// 名称区 → meter 的最小间距:弹窗 4(2026-10-30 用户拍板 meter 左右收紧)。
    static func meterLeadingGap(compact: Bool) -> CGFloat {
        compact ? 4 : 8
    }

    /// meter → 数值、数值 → 行尾列的间距:弹窗收紧到 4(2026-10-30 用户拍板),
    /// 全尺寸沿用通用间距。
    static func valueSpacing(compact: Bool) -> CGFloat {
        compact ? 4 : spacing(compact: false)
    }

    static func iconSize(compact: Bool) -> CGFloat {
        compact ? 18 : 22
    }

    static func meterWidth(compact: Bool) -> CGFloat {
        compact ? 52 : 110
    }

    /// 名称字号(数值弹窗档已单独调小,名称不随)。
    static func nameFontSize(compact: Bool) -> CGFloat {
        compact ? 12.5 : 13
    }

    /// 数值字号:弹窗 11.5(2026-10-30 用户拍板"数字改小一点",原与名称同 12.5)。
    static func valueFontSize(compact: Bool) -> CGFloat {
        compact ? 11.5 : 13
    }

    /// 数值列**定宽**:按该口径最宽现实读数以实际绘制字体量宽 + 2pt 余量。曾是最小宽度
    /// 64 / 48,速率文案逐行撑宽、把 meter 与名称区推得每行不同(2026-10-20 用户反馈);
    /// 定宽后同卡各行同一竖线。组排行曾与速率排行共用 "999.9 MB/s" 宽,CPU 读数短、
    /// 右对齐后 meter 与数字隔一大截、名称区被挤窄(2026-10-30 用户反馈)→ 分两口径。
    static func valueWidth(compact: Bool, column: RankingValueColumn = .rate) -> CGFloat {
        switch (column, compact) {
        case (.standard, true): compactStandardWidth
        case (.standard, false): regularStandardWidth
        case (.rate, true): compactRateWidth
        case (.rate, false): regularRateWidth
        }
    }

    private static let regularStandardWidth = measuredValueWidth(compact: false, column: .standard)
    private static let compactStandardWidth = measuredValueWidth(compact: true, column: .standard)
    private static let regularRateWidth = measuredValueWidth(compact: false, column: .rate)
    private static let compactRateWidth = measuredValueWidth(compact: true, column: .rate)

    private static func measuredValueWidth(compact: Bool, column: RankingValueColumn) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: valueFontSize(compact: compact), weight: .semibold)
        let widest = column.widestReadings
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + 2
    }
}

/// 空态文案:标题一句 + 可选说明(卡内由 CardEmptyState 绘制)。
struct RankingEmptyMessage {
    let title: String
    var detail: String?
}

/// 排行卡外壳:标题 / 表头 / 行 / 注脚 / 空态。行内容由调用方给(RankingListRow)。
struct RankingListCard<Rows: View>: View {
    let title: String
    /// 标题色 = 所在页的指标色。
    let accent: Color
    /// 表头右列的指标名("CPU" / "内存" / "CPU 时间" / "读写" / "流量")。
    let valueLabel: String
    var isCompact = false
    let isEmpty: Bool
    let emptyMessage: RankingEmptyMessage
    /// 卡底注脚(数据节拍等);nil 不画。
    var footnote: String?
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        // 惰性栈(popover-appkit/10):排行常有上百行,普通 VStack 全部建出,弹窗开期
        // 悬停命中检测 / 滚动 / 每秒刷新都按全部行付费(鼠标移动 ~33%、滚动 ~41%);
        // 惰性后只建视口内的行(→ ~7% / ~25%)。外层滚动区同为 LazyVStack 才生效。
        LazyVStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.bottom, 6)
            if isEmpty {
                CardEmptyState(title: emptyMessage.title, detail: emptyMessage.detail)
            } else {
                columnHeader
                rows()
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 表头右列对齐数值列右缘(越过行尾列)。
    private var columnHeader: some View {
        HStack {
            Text("应用")
            Spacer()
            Text(valueLabel)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.leading, RankingListMetrics.rowInset)
        .padding(
            .trailing,
            RankingListMetrics.rowInset + RankingListMetrics.valueSpacing(compact: isCompact)
                + RankingListMetrics.trailingWidth(compact: isCompact)
        )
        .padding(.bottom, 2)
    }
}

/// 排行行:图标 + 名称(可挂徽章)/ 副文 | meter + 数值 | 行尾列(恒占位)。
/// 只管排版;点击 / 悬停 / 右键等交互由调用方包在外面。
struct RankingListRow<Badge: View, Trailing: View>: View {
    let name: String
    let subtitle: String
    let bundlePath: String?
    /// 非 App 行的类别瓦片(符号 + 底色)。
    let tileSymbol: String
    let tileColor: Color
    let meterFraction: Double
    let tint: Color
    let valueText: String
    /// 数值高负载警示:state-negative 红字(2026-10-26 圈红取代"高负载"文字 chip;
    /// 2026-10-30 用户拍板去圈只留红字,最忙进程名改挂名称后 chip)。
    /// 仅 CPU 口径的组行会传 true(内存值不背 CPU 警示)。
    var alertsHighLoad = false
    /// 数值列口径:组排行传 .standard(读数短,列窄);模块排行默认 .rate。
    var valueColumn = RankingValueColumn.rate
    var isCompact = false
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: RankingListMetrics.spacing(compact: isCompact)) {
            icon
                .frame(width: iconSize, height: iconSize)
            // 名称区吃满剩余宽度,meter 贴右;二者之间只留 meterLeadingGap(外层通用间距
            // 只管图标→名称,否则名称→meter 会叠两份间距)。
            HStack(spacing: RankingListMetrics.meterLeadingGap(compact: isCompact)) {
                nameColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                valueColumnView
            }
        }
        .padding(.horizontal, RankingListMetrics.rowInset)
        .padding(.vertical, isCompact ? 5 : 7)
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: RankingListMetrics.nameFontSize(compact: isCompact), weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                badge()
            }
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var valueColumnView: some View {
        HStack(spacing: RankingListMetrics.valueSpacing(compact: isCompact)) {
            MeterBar(fraction: meterFraction, tint: tint)
                .frame(width: RankingListMetrics.meterWidth(compact: isCompact))
            Text(valueText)
                .font(.system(size: RankingListMetrics.valueFontSize(compact: isCompact), weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(alertsHighLoad ? Surface.negative : .primary)
                .frame(
                    width: RankingListMetrics.valueWidth(compact: isCompact, column: valueColumn),
                    alignment: .trailing
                )
            trailing()
                .frame(width: RankingListMetrics.trailingWidth(compact: isCompact), alignment: .trailing)
        }
    }

    private var iconSize: CGFloat {
        RankingListMetrics.iconSize(compact: isCompact)
    }

    /// App 行取真实应用图标;其余取类别瓦片(外壳底色 + 白符号)。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath {
            Image(nsImage: AppIconCache.icon(forBundle: bundlePath, pointSize: iconSize))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            CategoryIconTile(symbolName: tileSymbol, color: tileColor, size: iconSize)
        }
    }
}

extension RankingListRow where Badge == EmptyView, Trailing == EmptyView {
    /// 只读行(模块排行):无徽章,行尾列留空占位。
    init(
        name: String,
        subtitle: String,
        bundlePath: String?,
        tileSymbol: String,
        tileColor: Color,
        meterFraction: Double,
        tint: Color,
        valueText: String,
        isCompact: Bool = false
    ) {
        self.init(
            name: name, subtitle: subtitle, bundlePath: bundlePath,
            tileSymbol: tileSymbol, tileColor: tileColor,
            meterFraction: meterFraction, tint: tint, valueText: valueText,
            isCompact: isCompact,
            badge: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

// MARK: - 应用图标缓存(arch-review-2026-10-18/04;resident-cost/01 3c 预栅格化)

/// 应用图标按(bundle 路径, 显示点尺寸)缓存并**预栅格化**:排行行与环形图例每次重绘
/// 都要图标,`NSWorkspace.icon` 的原图带多档大尺寸表示,直接绘制每次都要把大图缩到
/// 16–22pt(真机探针 ~118µs/次;LaunchServices 查询另付 0.7–2.5ms/miss)——主窗口
/// 开着时是采样里的显眼热点。取图后按显示尺寸(点 × 屏幕缩放)栅格化成小位图
/// (~135µs 一次),此后每次绘制 ~8µs(15 倍);首次解码 ~3ms 一次性。图标在进程
/// 生命期内几乎不变;NSCache 在内存吃紧时自行回收。栅格化失败退回原图,行为同改前。
@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forBundle path: String, pointSize: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(path)@\(Int((pointSize * scale).rounded()))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let source = NSWorkspace.shared.icon(forFile: path)
        let icon = rasterized(source: source, pointSize: pointSize, scale: scale) ?? source
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// 按显示尺寸栅格化:像素 = 点 × 屏幕缩放(位图 rep 先设点尺寸再建上下文,
    /// CTM 才按缩放折算);高质量插值从原图一次降采样。
    private static func rasterized(source: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Int((pointSize * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pointSize, height: pointSize)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        return image
    }
}
