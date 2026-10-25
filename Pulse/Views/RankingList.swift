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

/// 行配方的度量(两档):卡、行、表头三处共用,改一处即全部对齐。
enum RankingListMetrics {
    /// 行尾列宽 = 结束按钮 18 + 间距 2 + 展开箭头 10;模块排行留同宽空列。
    static let trailingWidth: CGFloat = 30
    /// 行内水平内距(表头与之对齐)。
    static let rowInset: CGFloat = 6

    static func spacing(compact: Bool) -> CGFloat {
        compact ? 8 : 10
    }

    static func iconSize(compact: Bool) -> CGFloat {
        compact ? 18 : 22
    }

    static func meterWidth(compact: Bool) -> CGFloat {
        compact ? 52 : 110
    }

    static func valueFontSize(compact: Bool) -> CGFloat {
        compact ? 12.5 : 13
    }

    /// 数值列**定宽**(全部排行共用):按最宽现实读数 "999.9 MB/s"(速率跨到 GB/s 前的
    /// 最长串)以实际绘制字体量宽 + 2pt 余量。曾是最小宽度 64 / 48,速率文案逐行撑宽、
    /// 把 meter 与名称区推得每行不同(2026-10-20 用户反馈);定宽后各排行同一竖线。
    static func valueWidth(compact: Bool) -> CGFloat {
        compact ? compactValueWidth : regularValueWidth
    }

    private static let regularValueWidth = measuredValueWidth(compact: false)
    private static let compactValueWidth = measuredValueWidth(compact: true)

    private static func measuredValueWidth(compact: Bool) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: valueFontSize(compact: compact), weight: .semibold)
        return ceil(("999.9 MB/s" as NSString).size(withAttributes: [.font: font]).width) + 2
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
        VStack(alignment: .leading, spacing: 2) {
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
            RankingListMetrics.rowInset + RankingListMetrics.spacing(compact: isCompact)
                + RankingListMetrics.trailingWidth
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
    /// 数值高负载警示(project-visibility/02 目验反馈,2026-10-26 用户拍板):
    /// 数值圈红(state-negative 1pt 胶囊描边 + 同色数字)取代行内"高负载"文字
    /// chip——chip 挤占行宽遮挡信息。仅 CPU 口径的组行会传 true(内存值不背 CPU 警示)。
    var alertsHighLoad = false
    var isCompact = false
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: RankingListMetrics.spacing(compact: isCompact)) {
            icon
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: RankingListMetrics.valueFontSize(compact: isCompact), weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    badge()
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            MeterBar(fraction: meterFraction, tint: tint)
                .frame(width: RankingListMetrics.meterWidth(compact: isCompact))
            Text(valueText)
                .font(.system(size: RankingListMetrics.valueFontSize(compact: isCompact), weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(alertsHighLoad ? Surface.negative : .primary)
                // 警示圈随文不占版:负内距外扩 4pt,数值列竖线与行高不动(描边是
                // 警示标记不是层级描边,DESIGN.md 状态 chip 节登记的拍板例外)。
                .overlay {
                    if alertsHighLoad {
                        Capsule()
                            .strokeBorder(Surface.negative, lineWidth: 1)
                            .padding(-4)
                    }
                }
                .frame(width: RankingListMetrics.valueWidth(compact: isCompact), alignment: .trailing)
            trailing()
                .frame(width: RankingListMetrics.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, RankingListMetrics.rowInset)
        .padding(.vertical, isCompact ? 5 : 7)
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
