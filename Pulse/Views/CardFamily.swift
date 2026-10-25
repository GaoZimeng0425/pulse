import PulseCore
import SwiftUI

// MARK: - 卡片家族共用零件(arch-review-2026-10-18/02 中4)

//
// 卡壳 / 卡头 / 副卡头 / 统计值 / 空态的唯一实现——此前各手抄 4~9 份,细节已互相漂移。
// 数值全部出自 DESIGN.md 令牌:卡壳 = {colors.surface-card} + {rounded.card} 18 /
// {rounded.card-compact} 12 + {spacing.card-padding} 16 / {spacing.card-padding-compact} 12;
// 卡头标题 = {typography.card-title};统计值 = {typography.body} semibold;标签 =
// {typography.micro};说明 = {typography.caption}。新卡一律用这里的零件,不再手写。

/// 卡片两档的尺寸令牌。
enum CardMetrics {
    static func padding(compact: Bool) -> CGFloat {
        compact ? 12 : 16
    }

    static func cornerRadius(compact: Bool) -> CGFloat {
        compact ? 12 : 18
    }
}

extension View {
    /// 卡壳:内距 + 撑满宽度左对齐 + 卡底色圆角。`padded: false` 给自带内距的卡
    /// (总览卡 / 指标主卡,内距随版式不同)只套底色与圆角。
    func cardShell(compact: Bool, padded: Bool = true) -> some View {
        padding(padded ? CardMetrics.padding(compact: compact) : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: .rect(cornerRadius: CardMetrics.cornerRadius(compact: compact)))
    }
}

/// 主卡头:22pt 指标徽章 + 卡标题(12.5 semibold,指标色)+ 右侧附件(可选)。
struct CardHeader<Accessory: View>: View {
    let symbolName: String
    let title: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 7) {
            MetricBadge(symbolName: symbolName, tint: tint)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

extension CardHeader where Accessory == EmptyView {
    init(symbolName: String, title: String, tint: Color) {
        self.init(symbolName: symbolName, title: title, tint: tint) { EmptyView() }
    }
}

/// 副卡头(明细类小卡 / 紧凑总览卡):10pt 指标色符号 + 11 medium 次级标题 + 右侧
/// 10.5 tertiary 等宽注记(可选,如「合计 …」)。
struct CardSubHeader: View {
    let symbolName: String
    let title: String
    let tint: Color
    var note: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let note {
                Spacer(minLength: 4)
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// 卡内明细行的定宽令牌(DESIGN.md `{layout.row-*}`,p2-review/03 入表):数值列按
/// 该类读数的最宽现实文案量宽,作**最小宽**(真读数更宽时撑开,不截断);标签列定宽
/// 让同卡各行的 meter 起点对齐。新读数类型先补 DESIGN.md 表再加常量。
enum CardRowWidth {
    /// 标签列(短):三字母域名,如五路功率 "SoC" / "ANE"。
    static let shortLabel: CGFloat = 36
    /// 标签列:四个汉字 / 一个英文词,如 "最快风扇" / "Hottest"。
    static let label: CGFloat = 64
    /// 数值列:整数百分比 "100%"(音量、设备电量)。
    static let percentValue: CGFloat = 36
    /// 数值列:一位小数百分比 "99.9%"(容器 CPU)。
    static let decimalPercentValue: CGFloat = 48
    /// 数值列:温度 "99.9°C"。
    static let temperatureValue: CGFloat = 52
    /// 数值列:带单位量 "999 MB" / "99.9 W"(内存、功率)。
    static let quantityValue: CGFloat = 56
    /// 数值列:风扇转速 "9999 rpm"。
    static let rpmValue: CGFloat = 64
}

/// 卡内明细行数值:`{typography.body}` 12 常规 + `monospacedDigit`(DESIGN.md:一切数字
/// 读数等宽数字,不用整体等宽字形 `.monospaced`),右对齐,`minWidth` 取 `CardRowWidth`
/// 令牌(nil = 不定宽,如前置 Spacer 已把数值推到行尾)。层级色由调用方给(多为 secondary)。
struct CardRowValue: View {
    let text: String
    var minWidth: CGFloat?
    var style: HierarchicalShapeStyle = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(style)
            .frame(minWidth: minWidth, alignment: .trailing)
    }
}

/// 统计值:小标签(10.5 secondary,可带 6pt 色点)在上,数值(12 semibold 等宽)在下。
/// 总览卡、指标主卡(两档)共用一个字号——统计值不是大数字,不走圆体。
struct StatValue: View {
    let label: String
    let value: String
    var dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(label)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// 卡内空态:安静的一句(12.5 medium secondary)+ 可选说明(10.5 tertiary),居中。
/// 没数据是常态,不报警不催促。可选一个 `.link` 动作(授权型能力卡的
/// 开启 / 授权 / 去系统设置,与告警横幅的降级出口同款);没动作就是安静空态。
struct CardEmptyState: View {
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
