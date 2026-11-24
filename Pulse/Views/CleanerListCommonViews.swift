import AppKit
import PulseCore
import SwiftUI

// 清单家族:尺寸表(CleanerListMetrics)、勾选框(CleanerCheckBox)、全部清单子页的壳(JunkListSection)。

// MARK: - 清单家族

//
// 清单卡本体(JunkListCard)在 CleanerJunkViews.swift;应用 / 清理历史子页也从这里取
// 尺寸表与勾选框。

/// 清理页全页走舒适密度档,各张清单与确认单的行尺寸从这里取:共享值(字号 / 图标 /
/// meter / 内距)全部委托 `RowMetrics` 舒适档——主窗口行两档制里的舒适档,与排行页
/// 同档同源,不自己定数,也不借弹窗用的紧凑档。这里只留清理页专属参数(缩进 / 勾选框 /
/// 数值列口径)。同一档里,带边框的动作按钮(bordered / borderedProminent)一律
/// `.large`,segmented 保持 regular。
enum CleanerListMetrics {
    /// 行内水平内距(组头/项目行/动作条与行对齐)。
    static let rowInset: CGFloat = RowMetrics.rowInset(compact: false)
    static let spacing: CGFloat = RowMetrics.spacing(compact: false)
    static let iconSize: CGFloat = RowMetrics.iconSize(compact: false)
    static let titleFontSize: CGFloat = RowMetrics.nameFontSize(compact: false)
    /// 副文/路径行字号。
    static let subFontSize: CGFloat = RowMetrics.subFontSize(compact: false)
    static let valueFontSize: CGFloat = RowMetrics.valueFontSize(compact: false)
    static let meterWidth: CGFloat = RowMetrics.meterWidth(compact: false)
    static let rowVerticalPadding: CGFloat = RowMetrics.rowVerticalPadding(compact: false)
    /// 大卡内子项行的缩进量:子项只缩进,不套小卡(项目大卡与应用卡的残留区同用)。
    static let indentLeading: CGFloat = 28
    /// 卡内裸行(项目产物子项)的上下内距,与独立小卡的行同为 10。
    static let bareRowVerticalPadding: CGFloat = 10

    /// 数值**定宽列**(排行同法:按最宽现实读数以实际绘制字体量宽)。同卡各行同一
    /// 竖线,不许按内容撑宽。
    static let valueWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: valueFontSize, weight: .semibold)
        let widest = ["999.9 GB", "99.9 TB"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + 2
    }()

    /// 应用行的数值列(valueWidth + 「部分」附标留量;垃圾行不带附标用 valueWidth)。
    static let valueWidthWithMark: CGFloat = valueWidth + 30

    /// 自绘勾选框边长。
    static let checkBoxSize: CGFloat = 20
}

/// 清理页统一勾选框,自绘:off 空心、on 实心带勾、mixed 实心带横线、disabled 压暗。
/// 纯显示件——点击语义在宿主(整行可点,不逼用户点小方块)。
struct CleanerCheckBox: View {
    enum CheckState {
        case off
        case on
        case mixed
    }

    let state: CheckState
    var tint: Color = Surface.cleanAccent
    var disabled = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(state == .off ? Color.clear : tint)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(state == .off ? Surface.inkTertiary : tint, lineWidth: 1.5)
            Image(systemName: state == .mixed ? "minus" : "checkmark")
                .font(.system(size: IconSize.inline, weight: .bold))
                .foregroundStyle(.white)
                .opacity(state == .off ? 0 : 1)
        }
        .frame(width: CleanerListMetrics.checkBoxSize, height: CleanerListMetrics.checkBoxSize)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(state == .on ? "已勾选" : state == .mixed ? "部分勾选" : "未勾选")
        .accessibilityHidden(true) // 装饰件:可勾语义由宿主行宣布,避免双朗读
    }
}

/// 全部清单子页:按扫描态切三形状——未扫描给 CTA,扫描中给提示,完成给清单卡。
/// `groupFilter` = 总览下钻品类(nil = 全量)。
struct JunkListSection: View {
    let model: CleanerModel
    /// 轻桥落点(p4-uninstaller/05):地图「这块能清」切过来时待定位的组;
    /// 透传给清单卡(JunkListCard):滚动到组头并短暂高亮,消费后自清。
    var pendingGroup: Binding<JunkGroup?> = .constant(nil)
    /// 总览下钻品类(p6-cleaner/03):非 nil = 只显示该品类 + 顶部「‹ 总览」返回行。
    var groupFilter: Binding<JunkGroup?> = .constant(nil)
    /// 返回行回调(下钻态才有):回总览并清过滤——切换由壳层做(它持有 subTab)。
    var onBackToOverview: (() -> Void)?

    var body: some View {
        // flex:1 链路(section 层):壳层传下的 .infinity 在这接力,
        // 否则 switch 按内容自适应把信号吞了。
        bodyContent
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var bodyContent: some View {
        switch model.phase {
        case .idle:
            // 扫描前就给出扫描根指引(2026-11-02 用户实测找不到入口:配置只在
            // 设置窗「清理」页,主窗口这边扫之前看不到任何提示)。
            VStack(alignment: .leading, spacing: 4) {
                CardEmptyState(
                    title: model.isRestoringCache ? "正在恢复上次扫描结果…" : "先扫一遍,看看能回收多少",
                    detail: model.isRestoringCache
                        ? "从缓存读回上次结果(约一秒;机器满载时稍等)"
                        : "点右上「扫描整台 Mac」——白名单识别,未识别的目录不会出现",
                    actionTitle: model.isRestoringCache ? nil : "开始扫描",
                    action: model.isRestoringCache ? nil : { model.startScan() }
                )
                if !model.hasScanRoots {
                    Text("想清项目产物(node_modules 等)?先到 设置 → 清理 配置项目目录:工具栏齿轮打开设置,勾选建议目录或自添(如 ~/Documents/Learn/macos)。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .cardShell(compact: false)
        case .scanning:
            CardEmptyState(
                title: "正在扫描",
                detail: "扫描结束后这里出现可回收清单(进度在「空间地图」子页)"
            )
            .cardShell(compact: false)
        case .finished:
            JunkListCard(
                model: model,
                pendingGroup: pendingGroup,
                groupFilter: groupFilter,
                onBackToOverview: onBackToOverview
            )
        }
    }
}
