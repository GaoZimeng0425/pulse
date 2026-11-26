import PulseCore
import SwiftUI

// MARK: - 通用药丸 tab 条(用户拍板 2026-10-22:tab 是通用组件样式)

/// 药丸 tab 的展示单元:标题 + 可选 SF Symbol + 选中态强调色。
/// 视觉配方见 DESIGN.md §Components「药丸页签条」。
struct PillTabItem {
    /// 无障碍标签、悬停提示与(按模式)药丸文字共用一份文案。
    let title: String
    /// 未选中纯图标形态的符号;nil = 无图标药丸(此时文字必须恒显)。
    var symbol: String?
    /// 选中胶囊底(15%)与前景色。
    let tint: Color
}

/// 三档尺寸(DESIGN.md §Components「药丸页签条」):`.regular` = 显式 12 medium +
/// 内距 9×5(工具栏/历史页);`.comfortable` = 清理页舒适密度档(14.5 medium +
/// 内距 14×8,高≈34)——工具栏与弹窗的宽度预算不许被这档波及;`.compact` = 弹窗卡头
/// 上的小切换(11 medium + 内距 7×3,玻璃外裹 3)。
enum PillTabSize {
    case regular
    case comfortable
    case compact

    var fontSize: CGFloat {
        switch self {
        case .regular: 12
        case .comfortable: 14.5
        case .compact: 11
        }
    }

    /// 药丸内距(水平 × 垂直)。
    var pillPadding: (horizontal: CGFloat, vertical: CGFloat) {
        switch self {
        case .regular: (9, 5)
        case .comfortable: (14, 8)
        case .compact: (7, 3)
        }
    }

    /// 玻璃外裹与药丸之间的内距。
    var glassPadding: CGFloat {
        self == .compact ? 3 : 4
    }
}

/// 通用药丸 tab 条:主窗口工具栏 tab(经 `MetricPillTabBar` 薄封装)与历史页
/// 指标 / 范围切换共用的同一视觉配方——选中 = 该项强调色 15% 胶囊底 + 同色
/// 前景,未选中 = secondary 前景无底;内距 9(水平)×5(垂直)、药丸间距 4;
/// 切换 0.2s snappy(选中文字从图标侧展开、胶囊生长、其余药丸滑移让位)。
///
/// `textVisibility`:
/// - `.selectedOnly` = 主窗口工具栏形态:未选中纯图标、选中才展开文字
///   (多 tab 竞争宽度时总量恒定的根治法,工单 P1 验收走查拍板)。
/// - `.always` = 文字恒显(项数少、宽度无竞争的场合,如历史页范围切换)。
///
/// 玻璃外裹(用户拍板 2026-10-22:历史页要与工具栏同款玻璃包裹):工具栏的
/// 玻璃胶囊是 macOS 26 工具栏自动给 `.principal` 内容套的,不是我们画的;
/// 内容页没有这层系统包裹,`isGlassContainer = true` 时自备同款——药丸外
/// 留 4pt 内距再套系统 Liquid Glass(`glassEffect()`,系统材质,不自绘底)。
/// 工具栏用法保持 false,避免双重玻璃。
///
/// 约束:`.selectedOnly` 的每项必须有 `symbol`,否则未选中药丸为空。
struct PillTabBar<Item: Hashable>: View {
    enum TextVisibility {
        /// 未选中纯图标、选中图标 + 文字(工具栏形态)。
        case selectedOnly
        /// 文字恒显。
        case always
    }

    typealias Size = PillTabSize

    let items: [Item]
    @Binding var selection: Item
    var textVisibility: TextVisibility = .always
    var isGlassContainer = false
    var size: Size = .regular
    let item: (Item) -> PillTabItem

    /// 第一参数裸传(items 语义自明),其余带标签;item 映射放尾随闭包。
    init(
        _ items: [Item],
        selection: Binding<Item>,
        textVisibility: TextVisibility = .always,
        isGlassContainer: Bool = false,
        size: Size = .regular,
        item: @escaping (Item) -> PillTabItem
    ) {
        self.items = items
        _selection = selection
        self.textVisibility = textVisibility
        self.isGlassContainer = isGlassContainer
        self.size = size
        self.item = item
    }

    var body: some View {
        if isGlassContainer {
            // 与工具栏同配方:首尾(及上下)药丸离玻璃胶囊边 4pt,不贴边。
            bar
                .padding(size.glassPadding)
                .glassEffect()
        } else {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { value in
                pill(for: value)
            }
        }
        // 选中态变化(点按)统一走这条动画:文字展开/收起 + 胶囊宽度过渡。
        .animation(.snappy(duration: 0.2), value: selection)
    }

    private func pill(for value: Item) -> some View {
        let spec = item(value)
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            HStack(spacing: 5) {
                if let symbol = spec.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: IconSize.inline, weight: .medium))
                }
                if showsText(isSelected) {
                    Text(spec.title)
                        // 选中文字从图标侧展开淡入;胶囊随之生长、其余药丸滑移让位。
                        .transition(
                            .scale(scale: 0.6, anchor: .leading).combined(with: .opacity)
                        )
                }
            }
            .font(.system(size: size.fontSize, weight: .medium))
            .padding(.horizontal, size.pillPadding.horizontal)
            .padding(.vertical, size.pillPadding.vertical)
            .foregroundStyle(isSelected ? spec.tint : Color.secondary)
            .background(
                isSelected ? spec.tint.opacity(0.15) : Color.clear,
                in: .capsule
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spec.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(spec.title)
    }

    private func showsText(_ isSelected: Bool) -> Bool {
        textVisibility == .always || isSelected
    }
}

// MARK: - 卡头玻璃按钮(DESIGN.md §Components「卡头玻璃按钮」)

/// 卡头上的主动作按钮:胶囊形系统 Liquid Glass,与内容页里的玻璃药丸条同材质、同高——
/// 药丸条高 = 文字 + 药丸内距 ×2 + 外裹 ×2,按钮把两层合成一层;水平内距 = 外裹 + 药丸
/// 水平内距,文字起点与旁边药丸条里的文字对齐。尺寸档跟旁边的药丸条走(常规 / 紧凑)。
/// 不自绘底、不加描边。
struct HeaderGlassButtonStyle: ButtonStyle {
    /// 与同一配件槽里药丸条的尺寸档一致。
    var size: PillTabSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        let pill = size.pillPadding
        return configuration.label
            .font(.system(size: size.fontSize, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, size.glassPadding + pill.horizontal)
            .padding(.vertical, size.glassPadding + pill.vertical)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

#Preview("药丸 tab 条:历史页两种用法") {
    @Previewable @State var metric: HistoryMetricKey = .systemLoad
    @Previewable @State var range: HistoryRange = .hour1
    VStack(alignment: .leading, spacing: 16) {
        // 工具栏同形态:未选中纯图标、选中展开文字(各指标色)+ 玻璃外裹
        PillTabBar(
            HistoryMetricKey.allCases,
            selection: $metric,
            textVisibility: .selectedOnly,
            isGlassContainer: true
        ) { key in
            PillTabItem(title: key.title, symbol: key.symbolName, tint: key.accent.accentColor)
        }
        // 文字恒显形态:色调跟随所选指标 + 玻璃外裹
        PillTabBar(HistoryRange.allCases, selection: $range, isGlassContainer: true) { span in
            PillTabItem(title: span.title, tint: metric.accent.accentColor)
        }
    }
    .padding(16)
    .frame(width: 340)
}
