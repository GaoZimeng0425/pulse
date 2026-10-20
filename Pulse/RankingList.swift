import SwiftUI
import AppKit

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

    static func spacing(compact: Bool) -> CGFloat { compact ? 8 : 10 }
    static func iconSize(compact: Bool) -> CGFloat { compact ? 18 : 22 }
    static func meterWidth(compact: Bool) -> CGFloat { compact ? 52 : 110 }
    static func valueWidth(compact: Bool) -> CGFloat { compact ? 48 : 64 }
}

/// 空态文案:标题一句 + 可选说明(与 dev server 卡空态同族的安静两行)。
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
                emptyState
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
        .padding(isCompact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: isCompact ? 12 : 18))
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

    private var emptyState: some View {
        VStack(spacing: 2) {
            Text(emptyMessage.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail = emptyMessage.detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
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
                        .font(.system(size: isCompact ? 12.5 : 13, weight: .medium))
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
                .font(.system(size: isCompact ? 12.5 : 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: RankingListMetrics.valueWidth(compact: isCompact), alignment: .trailing)
            trailing()
                .frame(width: RankingListMetrics.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, RankingListMetrics.rowInset)
        .padding(.vertical, isCompact ? 5 : 7)
    }

    private var iconSize: CGFloat { RankingListMetrics.iconSize(compact: isCompact) }

    /// App 行取真实应用图标;其余取类别瓦片(外壳底色 + 白符号)。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
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
