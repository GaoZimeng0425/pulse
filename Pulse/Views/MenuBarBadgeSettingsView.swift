import PulseCore
import SwiftUI

/// 菜单栏徽标设置(工单 p1-history/09):1–4 个槽位,每槽从 CPU%/RAM%/磁盘剩余%/
/// 网络上下行里选,四项可同时上屏,顺序可调(上移/下移);默认 CPU + RAM。
/// 配置以逗号连接的 rawValue 存 @AppStorage——与菜单栏标签视图同键共享,
/// 改动即时生效、重启保留;非法值由 MenuBarBadgeConfiguration 解码侧回默认。
struct MenuBarBadgeSettingsView: View {
    /// 槽位配置(与 MenuBarLoadLabel 同键共享,UserDefaults 即时广播)。
    @AppStorage("settings.menuBarBadge") private var configurationRaw = MenuBarBadgeConfiguration.default.rawValue

    /// 解码失败回默认(读路径的唯一降级点;写路径永远写合法值)。
    private var configuration: MenuBarBadgeConfiguration {
        MenuBarBadgeConfiguration(rawValue: configurationRaw) ?? .default
    }

    var body: some View {
        Form {
            Section {
                ForEach(configuration.slots.indices, id: \.self) { index in
                    slotRow(index)
                }
                if configuration.slots.count < MenuBarBadgeConfiguration.slotRange.upperBound {
                    Button("添加槽位") {
                        configurationRaw = configuration.appendingSlot().rawValue
                    }
                }
            } header: {
                Text("徽标槽位")
            } footer: {
                Text(
                    "菜单栏从左到右依次显示各槽位,四项可同时显示。"
                        + "磁盘显示剩余空间占总容量的百分比;网络上下两行分别是上行与下行速率。"
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// 单个槽位行:四选一 + 上移/下移(顺序可调)+ 移除(至少留 1 槽)。
    private func slotRow(_ index: Int) -> some View {
        LabeledContent("槽位 \(index + 1)") {
            HStack(spacing: 12) {
                Picker(
                    "槽位 \(index + 1) 指标",
                    selection: slotBinding(index)
                ) {
                    ForEach(MenuBarBadgeMetric.allCases, id: \.self) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)

                upDownButtons(index)
                removeButton(index)
            }
        }
    }

    private func slotBinding(_ index: Int) -> Binding<MenuBarBadgeMetric> {
        Binding(
            get: { Self.displayedSlot(configuration.slots, at: index) },
            set: { newValue in
                configurationRaw = configuration.replacingSlot(at: index, with: newValue).rawValue
            }
        )
    }

    /// 槽位行的显示值:ForEach 按下标标识行,**删槽位的那一帧 SwiftUI 仍按旧下标求值
    /// 被删行的 Picker**(行求值先于数组收缩),直接下标越界即崩(2026-10-21 用户删槽位
    /// 闪退)。越界回落到末槽——该行下一帧即消失,回落值只撑那一帧的显示,不写回配置
    /// (写路径 replacingSlot 自带下标守卫)。配置恒 ≥1 槽,`last` 必有值。
    static func displayedSlot(_ slots: [MenuBarBadgeMetric], at index: Int) -> MenuBarBadgeMetric {
        slots.indices.contains(index) ? slots[index] : (slots.last ?? .cpu)
    }

    /// 上移/下移:交换相邻槽位;首行无上移、末行无下移。
    private func upDownButtons(_ index: Int) -> some View {
        let slots = configuration.slots
        return HStack(spacing: 4) {
            Button {
                configurationRaw = configuration.movingSlot(at: index, direction: .up).rawValue
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == slots.startIndex)

            Button {
                configurationRaw = configuration.movingSlot(at: index, direction: .down).rawValue
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == slots.index(before: slots.endIndex))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("调整槽位 \(index + 1) 顺序")
    }

    @ViewBuilder
    private func removeButton(_ index: Int) -> some View {
        if configuration.slots.count > MenuBarBadgeConfiguration.slotRange.lowerBound {
            Button(role: .destructive) {
                configurationRaw = configuration.removingSlot(at: index).rawValue
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("移除槽位 \(index + 1)")
        }
    }
}

// MARK: - 预览(arch-review-2026-10-18/02:预览缺口补齐)

#Preview("菜单栏徽标设置") {
    MenuBarBadgeSettingsView()
        .frame(width: 480, height: 360)
}
