import AppKit
import PulseCore
import SwiftUI

// MARK: - 明细小卡共用件(popover-appkit/05、06、07)

//
// 传感器 / 外设 / 功率 / 容器 / 磁盘 / 网络明细卡共用:卡身竖排、行视图按需复用、
// 「标签 + meter + 数值」行与状态点色。数值同 SwiftUI 原版(CardFamily.swift /
// 各 *CardViews.swift),定宽列取 `CardRowWidth`(DESIGN.md `{layout.row-*}`)。

/// 状态点"停 / 未连接"色(`Surface.inactive` = secondary 40%,DESIGN.md `{colors.state-inactive}`)。
/// 直接用系统动态色加透明度,draw 时按当前外观解析。
@MainActor
enum DetailInk {
    static let inactive = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
}

/// 明细卡卡身:副卡头 + 内容块,竖向间距 8(原版 `VStack(alignment: .leading, spacing: 8)`),
/// 每个子块撑满卡宽。返回已套卡壳(紧凑档 12 圆角 + 12 内距)的视图。
@MainActor
func makeDetailCard(_ views: [NSView], spacing: CGFloat = 8) -> CardView {
    let body = vstack(views, spacing: spacing)
    for view in views {
        view.fillWidth(of: body)
    }
    return CardView(content: body)
}

/// 横排行(SwiftUI `HStack(spacing:)` 撑满行宽):`.fill` 分布,剩余宽度交给最低抱紧的
/// 子视图(meter 条 / spacer),文字列按内容宽。
@MainActor
func makeDetailRow(
    _ views: [NSView],
    spacing: CGFloat = 8,
    alignment: NSLayoutConstraint.Attribute = .centerY
) -> NSStackView {
    let row = hstack(views, spacing: spacing, alignment: alignment)
    row.distribution = .fill
    return row
}

/// 行视图复用:只在行数变化时增删(不每轮全拆全建),新增行撑满父栈宽。
@MainActor
func syncRows<Row: NSView>(_ rows: inout [Row], count: Int, in stack: NSStackView, make: () -> Row) {
    while rows.count > count {
        rows.removeLast().removeFromSuperview()
    }
    while rows.count < count {
        let row = make()
        stack.addArrangedSubview(row)
        row.fillWidth(of: stack)
        rows.append(row)
    }
}

/// 名称列标签:12 medium primary,超长尾部省略;抗压最低,行宽不够时先截它。
@MainActor
func makeNameLabel(weight: NSFont.Weight = .medium) -> NSTextField {
    let label = makeLabel(font: PFont.text(12, weight))
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

/// 「标签(定宽)+ meter(吃剩余宽)+ 数值(最小宽)」行,横向间距 8:
/// 传感器派生卡(标签 64 / 数值 52)与五路功率卡(标签 36 / 数值 56)同形。
@MainActor
final class MeterDetailRowView: NSStackView {
    private let titleLabel = makeLabel(font: PFont.text(12, .medium))
    private let meter = MeterBarView()
    private let valueLabel: NSTextField

    init(labelWidth: CGFloat, valueMinWidth: CGFloat) {
        valueLabel = makeRowValue(minWidth: valueMinWidth)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.fixed(width: labelWidth)
        addArrangedSubview(titleLabel)
        addArrangedSubview(meter)
        addArrangedSubview(valueLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func set(title: String, fraction: Double, value: String, tint: NSColor) {
        titleLabel.setText(title)
        meter.fraction = fraction
        meter.tint = tint
        valueLabel.setText(value)
    }
}
