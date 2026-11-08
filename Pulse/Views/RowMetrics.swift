import SwiftUI

// MARK: - 列表行两档制(ui-unify/01,DESIGN.md v1.1)

///
/// 全 app 列表行的唯一尺寸出处:紧凑档(弹窗)/ 舒适档(主窗口一切列表行)。
/// 此前排行(RankingListMetrics)、清理(CleanerListMetrics)、sheet 清单行三套
/// 并存、字号漂移(12.5 / 13 / 13.5 / 14.5 混用),2026-11-08 用户拍板归一两档
/// (方案 A:排行也升舒适档)。页面专属参数(排行行尾列、清理缩进 / 勾选框)留在
/// 各自 enum,共享值一律来这里取,不再各自定数。
enum RowMetrics {
    /// 名称字号:层级靠字重(名称 medium / 数值 semibold),不靠半号字。
    static func nameFontSize(compact: Bool) -> CGFloat {
        compact ? 12 : 14.5
    }

    /// 数值字号(调用方配 .semibold + monospacedDigit)。
    static func valueFontSize(compact: Bool) -> CGFloat {
        compact ? 12 : 14.5
    }

    /// 副文 / 路径行字号。
    static func subFontSize(compact: Bool) -> CGFloat {
        compact ? 10.5 : 12
    }

    static func iconSize(compact: Bool) -> CGFloat {
        compact ? 18 : 24
    }

    /// 行内 meter 条宽。
    static func meterWidth(compact: Bool) -> CGFloat {
        compact ? 52 : 120
    }

    /// 行内元素间距(图标→名称等)。
    static func spacing(compact: Bool) -> CGFloat {
        compact ? 8 : 10
    }

    /// 行水平内距(排行表头与之对齐)。
    static func rowInset(compact: Bool) -> CGFloat {
        compact ? 6 : 14
    }

    /// 行上下内距。
    static func rowVerticalPadding(compact: Bool) -> CGFloat {
        compact ? 5 : 10
    }
}
