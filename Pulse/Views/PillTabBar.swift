import PulseCore
import SwiftUI

// MARK: - 通用药丸 tab 条(用户拍板 2026-10-22:tab 是通用组件样式)

/// 药丸 tab 的展示单元:标题 + 可选 SF Symbol + 选中态强调色。
/// 视觉配方见 DESIGN.md §Components `PillTabBar`。
struct PillTabItem {
    /// 无障碍标签、悬停提示与(按模式)药丸文字共用一份文案。
    let title: String
    /// 未选中纯图标形态的符号;nil = 无图标药丸(此时文字必须恒显)。
    var symbol: String?
    /// 选中胶囊底(15%)与前景色。
    let tint: Color
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
/// 约束:`.selectedOnly` 的每项必须有 `symbol`,否则未选中药丸为空。
struct PillTabBar<Item: Hashable>: View {
    enum TextVisibility {
        /// 未选中纯图标、选中图标 + 文字(工具栏形态)。
        case selectedOnly
        /// 文字恒显。
        case always
    }

    let items: [Item]
    @Binding var selection: Item
    var textVisibility: TextVisibility = .always
    let item: (Item) -> PillTabItem

    /// 第一参数裸传(items 语义自明),其余带标签;item 映射放尾随闭包。
    init(
        _ items: [Item],
        selection: Binding<Item>,
        textVisibility: TextVisibility = .always,
        item: @escaping (Item) -> PillTabItem
    ) {
        self.items = items
        _selection = selection
        self.textVisibility = textVisibility
        self.item = item
    }

    var body: some View {
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
                        .font(.system(size: 11, weight: .medium))
                }
                if showsText(isSelected) {
                    Text(spec.title)
                        // 选中文字从图标侧展开淡入;胶囊随之生长、其余药丸滑移让位。
                        .transition(
                            .scale(scale: 0.6, anchor: .leading).combined(with: .opacity)
                        )
                }
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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

#Preview("药丸 tab 条:历史页两种用法") {
    @Previewable @State var metric: HistoryMetricKey = .systemLoad
    @Previewable @State var range: HistoryRange = .hour1
    VStack(alignment: .leading, spacing: 16) {
        // 工具栏同形态:未选中纯图标、选中展开文字(各指标色)
        PillTabBar(
            HistoryMetricKey.allCases, selection: $metric, textVisibility: .selectedOnly
        ) { key in
            PillTabItem(title: key.title, symbol: key.symbolName, tint: key.accent.accentColor)
        }
        // 文字恒显形态:色调跟随所选指标
        PillTabBar(HistoryRange.allCases, selection: $range) { span in
            PillTabItem(title: span.title, tint: metric.accent.accentColor)
        }
    }
    .padding(16)
    .frame(width: 340)
}
