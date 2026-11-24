import SwiftUI

// MARK: - 图标尺寸档位(DESIGN.md `{icons.*}`)

/// 自由摆放的符号图标(SF Symbol)的字号档位:同一类图标全 app 一个大小,新图标
/// 从这里挑档,不自己写数。随容器走的图标不归这里——状态芯片里的符号随芯片档位,
/// 类别图标瓦里的符号按瓦片边长折算;设置图标砖与弹窗图标页签条里的符号是各自
/// 规格里的定值。
enum IconSize {
    /// 排序、展开收起的上下小箭头。
    static let chevron: CGFloat = 9

    /// 行内符号:行尾右箭头、卡头符号、小按钮里的符号、状态符号、勾选框对勾、页签条图标。
    static let inline: CGFloat = 11

    /// 空态大符号。
    static let emptyState: CGFloat = 26

    /// 行首类型符号,随行两档制(紧凑 = 弹窗,舒适 = 主窗口);外框见 RowMetrics.iconSize。
    static func leading(compact: Bool) -> CGFloat {
        compact ? 13 : 16
    }
}
