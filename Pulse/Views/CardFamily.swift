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

    /// 卡壳切段(popover-list):一张卡拆成多个 List 行时,各段只画自己那截底色——
    /// 卡头上圆角、卡尾下圆角、中段直角,拼起来与 `cardShell` 一致。内距由调用方给。
    func cardSlice(_ slice: CardSlice, compact: Bool) -> some View {
        let radius = CardMetrics.cornerRadius(compact: compact)
        let top: CGFloat = slice == .top ? radius : 0
        let bottom: CGFloat = slice == .bottom ? radius : 0
        return frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Surface.card,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: top, bottomLeadingRadius: bottom,
                    bottomTrailingRadius: bottom, topTrailingRadius: top
                )
            )
    }
}

enum CardSlice {
    case top, middle, bottom
}

extension EnvironmentValues {
    /// 排行卡是否摊成 List 行(popover-list):弹窗滚动区是 List 时由宿主置 true,
    /// 排行卡拆成卡头 / 每行 / 卡尾各占一行;默认 false = 整卡一个 LazyVStack(主窗口)。
    @Entry var rankingRowsInList = false
}

/// 主卡头:22pt 指标徽章 + 卡标题(12 semibold,指标色)+ 右侧附件(可选)。
struct CardHeader<Accessory: View>: View {
    let symbolName: String
    let title: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 7) {
            MetricBadge(symbolName: symbolName, tint: tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
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

/// 副卡头(明细类小卡 / 紧凑总览卡):10.5pt 指标色符号 + 12 semibold 指标色标题 +
/// 右侧 10.5 tertiary 等宽注记(可选,如「合计 …」)。标题升彩色 = ui-unify 追改
/// 2026-11-09:卡头是卡片身份,与排行卡内标题(12 semibold 指标色)同配方,P2 批次
/// 卡不再是一族灰标题。
struct CardSubHeader: View {
    let symbolName: String
    let title: String
    let tint: Color
    var note: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
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
    /// 数值列:信号强度 `-99 dBm`(~~蓝牙设备行~~ RSSI 已改行副文,ui-unify 追改
    /// 2026-11-09;保留给未来需要定宽 RSSI 列的卡)。
    static let rssiValue: CGFloat = 32
    /// ~~行内电量条宽(蓝牙设备行)~~ superseded(同上):行内 meter 一律
    /// `RowMetrics.meterWidth`(120 / 52)。
    static let meterCompact: CGFloat = 44
    /// 同上,superseded。
    static let meter: CGFloat = 64

    /// 令牌全按 12pt 量宽;行升舒适档(14.5)时按字号等比放大(ui-unify 追改
    /// 2026-11-09)——否则"—"行与真读数行列宽不等,同卡数值列 / 标签列错位。
    static func scaled(_ width: CGFloat, fontSize: CGFloat) -> CGFloat {
        ceil(width * fontSize / 12)
    }
}

/// 卡内实体行(ui-unify 追改 2026-11-09,DESIGN.md §Components「卡内行两形态边界」):
/// 行描述一台设备 / 一个对象(蓝牙设备、输出设备、容器、dev server)时用这形态——
/// 行首类型图标 + 名称 + 可选副文(弱信号:RSSI / pid)+ 尾部自定义列(meter、数值列),
/// 尺寸全走 `RowMetrics` 两档,与排行 / 清理列表行同语言。图标色由调用方给:
/// 活跃态取所在页指标色,非活跃 `{colors.state-inactive}`(代替旧 6pt 状态圆点)。
struct CardEntityRow<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let name: String
    var sub: String?
    let compact: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: RowMetrics.spacing(compact: compact)) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 13 : 16, weight: .medium))
                .frame(width: RowMetrics.iconSize(compact: compact))
                .frame(maxHeight: .infinity, alignment: .center)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: RowMetrics.nameFontSize(compact: compact), weight: .medium))
                    .lineLimit(1)
                if let sub {
                    Text(sub)
                        .font(.system(size: RowMetrics.subFontSize(compact: compact)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: RowMetrics.spacing(compact: compact))
            trailing()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// 卡内读数行(ui-unify 追改 2026-11-09,DESIGN.md「卡内行两形态边界」):行描述一个
/// 测量(派生温度 / 风扇 / 功率域 / 卷占用 / 流量累计 / 温度明细)——标签吃满剩余宽度、
/// meter(可选,`RowMetrics.meterWidth` 定宽)与数值列贴右,与排行行同一竖线结构;
/// 无图标。字号全走 RowMetrics 两档。
struct CardReadingRow: View {
    let label: String
    var labelStyle: HierarchicalShapeStyle = .primary
    var labelWeight: Font.Weight = .medium
    /// nil = 无 meter(温度明细 / 流量累计:读数本身就是全部信息)。
    var meter: (fraction: Double, tint: Color)?
    let value: String
    var valueMinWidth: CGFloat?
    var valueStyle: HierarchicalShapeStyle = .primary
    let compact: Bool

    var body: some View {
        HStack(spacing: RowMetrics.spacing(compact: compact)) {
            Text(label)
                .font(.system(size: RowMetrics.nameFontSize(compact: compact), weight: labelWeight))
                .foregroundStyle(labelStyle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let meter {
                MeterBar(fraction: meter.fraction, tint: meter.tint)
                    .frame(width: RowMetrics.meterWidth(compact: compact))
            }
            CardRowValue(
                text: value,
                minWidth: valueMinWidth,
                style: valueStyle,
                fontSize: RowMetrics.valueFontSize(compact: compact),
                weight: .semibold
            )
        }
    }
}

/// 卡内明细行数值:`monospacedDigit` 右对齐,`minWidth` 取 `CardRowWidth` 令牌
/// (nil = 不定宽;令牌按 12pt 量,这里随 fontSize 等比放大)。字号字重随所在行走
/// RowMetrics 两档(ui-unify 追改 2026-11-09,默认 12 常规 = 旧口径;行内传
/// `RowMetrics.valueFontSize` + semibold 与排行数值列同款)。
struct CardRowValue: View {
    let text: String
    var minWidth: CGFloat?
    var style: HierarchicalShapeStyle = .secondary
    var fontSize: CGFloat = 12
    var weight: Font.Weight = .regular

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(style)
            .frame(minWidth: minWidth.map { CardRowWidth.scaled($0, fontSize: fontSize) }, alignment: .trailing)
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

/// 卡内空态:安静的一句(12 medium secondary)+ 可选说明(10.5 tertiary),居中。
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
                .font(.system(size: 12, weight: .medium))
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

/// 自适应列数的卡片网格:列数 = 内容宽容纳的最多列(单卡最小宽 + 列距),
/// 夹在 1…上限——比系统 `.adaptive` 多一个**上限**(ultrawide 不出更多列)。
/// 宽度经 `onGeometryChange` 读取,只在跨档时改状态,拖拽缩放不逐帧重排。
/// 唯一实现(2026-11-10 合一):此前 MetricTabStack 与清理总览各有一份逐行
/// 相同的私有副本,仅差三个数值——单卡最小宽 / 列距 / 列数上限由调用方按
/// DESIGN.md 令牌传入(指标页 340·16·4,清理总览 340·12·2)。
struct AdaptiveCardGrid<Card: View>: View {
    /// 初值取默认窗宽(880)的档位,首帧即正确;onGeometryChange 随后按实测纠正。
    @State private var columnCount = 2
    let minimumCardWidth: CGFloat
    let spacing: CGFloat
    let maximumColumns: Int
    @ViewBuilder let cards: () -> Card

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: spacing),
                count: columnCount
            ),
            spacing: spacing
        ) {
            cards()
        }
        .onGeometryChange(for: Int.self) { proxy in
            let perColumn = minimumCardWidth + spacing
            let fitted = Int((proxy.size.width + spacing) / perColumn)
            return min(maximumColumns, max(1, fitted))
        } action: { newValue in
            if newValue != columnCount {
                columnCount = newValue
            }
        }
    }
}
