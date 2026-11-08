import SwiftUI

// MARK: - 统一 chip(ui-unify/01,DESIGN.md v1.1)

///
/// 全 app 状态 chip 的唯一实现:胶囊、tint 15% 底 + 同色文字、semibold。
/// 此前五种手写(HotProcessChip / TierChip / InUseChip / StateChip / 指标卡
/// 状态 chip)细节互相漂移(字号 10~11.5、内距 5×1~10×3、透明度 0.14~0.15),
/// 2026-11-08 归一。语义 tint 由调用方给(positive / negative / caution /
/// inkTertiary / 指标色),本组件只管形。
struct ChipView: View {
    enum Profile {
        /// 行内独立元素(11 semibold,内距 10×3)——安全档、在用保护、指标卡状态。
        case regular
        /// 挤在名称后的行内小签(10.5 semibold,内距 5×1,定宽不换形)——最忙进程名。
        case inline

        var fontSize: CGFloat {
            self == .regular ? 11 : 10.5
        }

        var horizontalPadding: CGFloat {
            self == .regular ? 10 : 5
        }

        var verticalPadding: CGFloat {
            self == .regular ? 3 : 1
        }

        var fixedSize: Bool {
            self == .inline
        }
    }

    let text: String
    let tint: Color
    var profile: Profile = .regular
    var systemImage: String?
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: profile.fontSize, weight: .semibold))
            }
            Text(text)
                .font(.system(size: profile.fontSize, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, profile.horizontalPadding)
        .padding(.vertical, profile.verticalPadding)
        .background(tint.opacity(0.15), in: .capsule)
        .fixedSize(horizontal: profile.fixedSize, vertical: true)
        .modifier(ChipHelp(help: help))
    }
}

/// help 为 nil 时不挂 tooltip(空串会弹出空气泡)。
private struct ChipHelp: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        if let help {
            content.help(help)
        } else {
            content
        }
    }
}

#Preview("统一 chip 两形态") {
    VStack(alignment: .leading, spacing: 12) {
        ChipView(text: "可安全清理", tint: Surface.positive)
        ChipView(text: "先检查", tint: Surface.caution)
        ChipView(text: "在用保护 · 终端与构建正在此项目", tint: Surface.inkTertiary)
        ChipView(text: "高负载", tint: Surface.negative, systemImage: "exclamationmark.triangle.fill")
        ChipView(text: "NodeBundleProcess", tint: Surface.negative, profile: .inline)
    }
    .padding(16)
    .frame(width: 340)
    .background(Surface.window)
}
