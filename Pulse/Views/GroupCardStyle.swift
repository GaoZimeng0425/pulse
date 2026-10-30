import PulseCore
import SwiftUI

// 组卡样式表 / 类别图标瓦片 / 处置失败弹窗:主窗口与弹窗(AppKit 版,popover-appkit)共用。
// 原在 DashboardView.swift;弹窗 SwiftUI 版退场后(popover-appkit/09)只剩这些共用件。

/// 组卡样式表(工单 05/09,评审 T6):每个类别一份完整样式
/// (SF Symbol + 瓦片色 + 指标强调色)。孤儿进程的橙色高亮(GLOSSARY:
/// 它往往正是问题所在)是表中的一行,而非散落在视图里的 `.orphan` 特判。
struct GroupCardStyle {
    let symbolName: String
    /// 外壳底色(2026-10-16 用户反馈):非 bundle 组没有真实应用图标,裸 SF Symbol
    /// 夹在真 App 图标之间显得突兀——改为实心圆角方块 + 白符号,形态对齐 app logo。
    let tileColor: Color
    /// 指标强调色:CPU 口径下驱动卡内 meter(孤儿橙)。工单 03 tab 化后
    /// 内存口径由 RankingRowView 按当前 tab 的指标另行覆盖(孤儿仍橙,语义不变)。
    let accentColor: Color
}

/// 类别图标的"外壳":实心圆角方块 + 白色符号,形态对齐真实 app 图标。
struct CategoryIconTile: View {
    let symbolName: String
    let color: Color
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension GroupCategory {
    /// 组卡的类别样式:bundle 组由 UI 直接取应用图标,此表服务项目与兜底类别
    /// (spec:符号图 + 孤儿橙色);各类别符号互不相同——"可辨识的类别标记"。
    /// 颜色一律取类别身份色(`identityColor`,MetricAccent.swift 唯一出处)。
    var cardStyle: GroupCardStyle {
        switch self {
        case .app:
            GroupCardStyle(symbolName: "shippingbox", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .project:
            // 项目组统一图标:folder(目录 = 项目的自然隐喻,与 Vitals 的 Projects 概念
            // 一致;旧 hammer 读作"构建工具",用户反馈怪)。
            GroupCardStyle(symbolName: "folder", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .system:
            GroupCardStyle(symbolName: "cpu", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .backgroundService:
            GroupCardStyle(symbolName: "gearshape", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .orphan:
            GroupCardStyle(symbolName: "exclamationmark.triangle", tileColor: identityColor, accentColor: identityColor)
        }
    }

    /// 组卡图标的 SF Symbol(样式表的符号字段,单测经此断言映射完备且互异)。
    var cardSymbolName: String {
        cardStyle.symbolName
    }
}

// MARK: - 处置失败弹窗(p0/08;确认与编排在 KillRequestFlow.swift)

/// 处置失败汇总弹窗:**有失败才弹**(标题 / 正文 / "知道了"按钮与工单 08 一致)。
struct KillFailureAlert: ViewModifier {
    @Binding var report: KillReport?

    func body(content: Content) -> some View {
        content.alert(
            report?.failureAlertTitle ?? "",
            isPresented: Binding(
                get: { report?.hasFailures == true },
                set: {
                    if !$0 {
                        report = nil
                    }
                }
            )
        ) {
            Button("知道了") { report = nil }
        } message: {
            Text(report?.failureAlertMessage ?? "")
        }
    }
}
