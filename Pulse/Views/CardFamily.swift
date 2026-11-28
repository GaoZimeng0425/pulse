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
/// `symbolName` nil = 无徽章只留标题(用户拍板 agent-tab/05:每日消耗卡头删徽章)。
struct CardHeader<Accessory: View>: View {
    let symbolName: String?
    let title: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 7) {
            if let symbolName {
                MetricBadge(symbolName: symbolName, tint: tint)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
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
                .font(.system(size: IconSize.inline, weight: .semibold))
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

/// 数值列定宽的量法(DESIGN.md「数值列定宽」):一组现实读数以实际绘制字体(等宽数字)
/// 量宽,取最宽、向上取整,再留 2 余量。各处的列宽常量都从这里量,不各写一份。
func measuredReadingsWidth(_ readings: [String], fontSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
    let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
    let widest = readings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    return ceil(widest) + 2
}

/// 卡内实体行(DESIGN.md §Components「卡片家族零件」):
/// 行描述一台设备 / 一个对象(蓝牙设备、输出设备、容器、dev server)时用这形态——
/// 行首类型图标 + 名称 + 可选副文(弱信号:RSSI / pid)+ 尾部自定义列(meter、数值列),
/// 尺寸全走 `RowMetrics` 两档,与排行 / 清理列表行同语言。图标色由调用方给:
/// 活跃态取所在页指标色,非活跃 `{colors.state-inactive}`(代替旧 6pt 状态圆点)。
/// `image` 给真实物件图标(app 图标;app-volume/01)——有它时行首画图标本体
/// (iconSize 见方、圆角 5 收边),无它回 SF Symbol。
struct CardEntityRow<Trailing: View>: View {
    let systemImage: String
    var image: NSImage?
    let tint: Color
    let name: String
    var sub: String?
    let compact: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: RowMetrics.spacing(compact: compact)) {
            iconView
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

    /// 行首图标:真物件图标(app-volume/01)或 SF Symbol 分支。
    @ViewBuilder
    private var iconView: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            // tint 统一由调用点的链尾 foregroundStyle 上(与真图标分支同一处)。
            Image(systemName: systemImage)
                .font(.system(size: IconSize.leading(compact: compact), weight: .medium))
        }
    }
}

/// 卡内读数行(DESIGN.md §Components「卡片家族零件」):行描述一个
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

/// 自适应列数的卡片网格(数据驱动):列数 = 内容宽容纳的最多列(单卡最小宽 +
/// 列距),夹在 1…上限——比系统 `.adaptive` 多一个**上限**(ultrawide 不出更多列)。
/// 排布交给 `AdaptiveColumnsLayout`:行高取该行最高一张、末行不满自动满宽。行内的
/// 弹性框在卡壳外面,卡底色不跟着拉伸,同排卡只在自然高相同时看着齐(尚未改成先撑框
/// 后铺底)。不用 LazyVGrid
/// (行内不拉齐高度)也不用 GridItem minimum(硬下限,窄容器溢出裁剪)。
/// 数值由调用方按 DESIGN.md 令牌传入(指标页 340·16·3,清理总览 340·12·2)。
struct AdaptiveCardGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let minimumCardWidth: CGFloat
    let spacing: CGFloat
    let maximumColumns: Int
    /// 单卡最大宽(nil = 不封顶;现无调用方,参数保留)。
    var maximumCardWidth: CGFloat?
    @ViewBuilder let card: (Item) -> Card

    init(
        items: [Item],
        minimumCardWidth: CGFloat,
        spacing: CGFloat,
        maximumColumns: Int,
        maximumCardWidth: CGFloat? = nil,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.items = items
        self.minimumCardWidth = minimumCardWidth
        self.spacing = spacing
        self.maximumColumns = maximumColumns
        self.maximumCardWidth = maximumCardWidth
        self.card = card
    }

    var body: some View {
        AdaptiveColumnsLayout(
            minimumItemWidth: minimumCardWidth,
            spacing: spacing,
            maximumColumns: maximumColumns
        ) {
            ForEach(items) { item in
                card(item)
                    .frame(maxWidth: maximumCardWidth, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// 按宽度定列数的等高网格(main-window-native-list,2026-11-28):列数 = 提案宽容纳的
/// 最多列(单项最小宽 + 列距),夹在 1…上限;逐行等高——行高 = 该行各项在列宽下
/// 不限高时量出的最高值,再把「列宽 × 行高」明确提给每一项(EqualHeightRow 同一机制);
/// 末行不满时各项变宽铺满。
/// 为什么是 Layout 而不是「onGeometryChange 量宽 → @State 列数」:原生列表先在离屏按
/// 列宽量行高、再把内容装进可见行,两处是不同的视图实例,状态式列数各算各的,行高与
/// 内容对不上;行内 `.frame(maxHeight: .infinity)` 在不限高的量法下更会把整行量成
/// 天文数字(主窗口接原生列表时总览页实测滚动范围 3.5e13pt)。Layout 由提案宽当场
/// 决定列数,量高与显示同一结果,拖拽缩放也是逐帧确定。
struct AdaptiveColumnsLayout: Layout {
    let minimumItemWidth: CGFloat
    let spacing: CGFloat
    let maximumColumns: Int

    /// 同一宽度下的行高(sizeThatFits 算一次,placeSubviews 复用;子视图变了即作废)。
    struct Cache {
        var width: CGFloat?
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews _: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // 不给宽(问理想尺寸)时按单列、最宽一项自然宽回答。
        guard let width = proposal.width else {
            let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
        }
        let heights = rowHeights(width: width, subviews: subviews, cache: &cache)
        let total = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let heights = rowHeights(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in zip(rows(width: bounds.width, count: subviews.count), heights) {
            let column = columnWidth(total: bounds.width, count: row.count)
            for (offset, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(offset) * (column + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: column, height: height)
                )
            }
            y += height + spacing
        }
    }

    /// 列数:宽能容纳的最多列,夹在 1…上限。
    func columnCount(width: CGFloat) -> Int {
        let fitted = Int((width + spacing) / (minimumItemWidth + spacing))
        return min(maximumColumns, max(1, fitted))
    }

    private func rows(width: CGFloat, count: Int) -> [Range<Int>] {
        let columns = columnCount(width: width)
        return stride(from: 0, to: count, by: columns).map { $0 ..< min($0 + columns, count) }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if let cached = cache.width, abs(cached - width) < 0.5 {
            return cache.rowHeights
        }
        let heights = rows(width: width, count: subviews.count).map { row in
            let column = columnWidth(total: width, count: row.count)
            return row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        cache = Cache(width: width, rowHeights: heights)
        return heights
    }

    private func columnWidth(total: CGFloat, count: Int) -> CGFloat {
        (total - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1))
    }
}

/// 同行等高横排(agent-tab/14):一排卡,列等宽,整行按最高的一张定高,再把
/// 「列宽 × 行高」明确提给每一张。行内等高只认这一种机制——不要用
/// `.frame(maxHeight: .infinity)` 靠宿主的高度提案去撑:弹窗原生列表量高时高度
/// 没有上限,弹性框会把整页量成天文数字;滚动区里框撑开了,底色若画在框里面
/// 也不跟着变高。所以卡自己要先撑框、后铺底色
/// (`.frame(maxHeight: .infinity, alignment: .top)` 写在 `.background` 之前)。
/// `sizeThatFits` 不理会宿主的高度提案,行高只由内容决定;末行卡少时各卡
/// 自动变宽铺满整行。
struct EqualHeightRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.naturalWidth(of: subviews, spacing: spacing)
        return CGSize(width: width, height: rowHeight(width: width, subviews: subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = rowHeight(width: bounds.width, subviews: subviews)
        let column = Self.columnWidth(total: bounds.width, count: subviews.count, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: column, height: height)
            )
        }
    }

    /// 行高 = 各卡在自己的列宽下、不限高时量出的最高值。
    private func rowHeight(width: CGFloat, subviews: Subviews) -> CGFloat {
        let column = Self.columnWidth(total: width, count: subviews.count, spacing: spacing)
        return subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
    }

    private static func columnWidth(total: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        (total - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1))
    }

    /// 宿主没给宽(问理想尺寸)时,按各卡自然宽之和。
    private static func naturalWidth(of subviews: Subviews, spacing: CGFloat) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + spacing * CGFloat(max(subviews.count - 1, 0))
    }
}
