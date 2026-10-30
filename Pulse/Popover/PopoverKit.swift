import AppKit
import SwiftUI

// MARK: - AppKit 面板基础件(popover-appkit/01)

//
// 颜色 / 字体 / 文本 / 符号的桥接点:数值一律出自 DESIGN.md 令牌,颜色从 SwiftUI 令牌
// (`Metric.accentColor` / `Surface.*`,唯一出处不变)经 `NSColor(Color)` 桥接——
// `Color.dynamic` 本身就是动态 NSColor,桥接后浅深外观照常自适应。
// 动态色只在 `draw(_:)` / 文本渲染里解析;不要把它们转成 CGColor 塞进 layer
// (layer 不会随外观切换重新解析)。

/// 原点在左上的视图(SwiftUI 同向):卡片手工布局与竖向排版都按自上而下算。
class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

extension Color {
    /// SwiftUI 令牌 → NSColor(动态色保留浅深自适应)。
    var ns: NSColor {
        NSColor(self)
    }
}

/// 文字层级色(DESIGN.md:文字层级只用系统语义 primary / secondary / tertiary)。
enum Ink {
    static let primary = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let tertiary = NSColor.tertiaryLabelColor
}

/// 字体令牌(DESIGN.md §Typography)。
enum PFont {
    static func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// 数字读数:系统字体 + 等宽数字(`monospacedDigit`)。
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// 大数字:圆体 + 等宽数字(`FigureText` 同配方)。
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = (base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor)
            .addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]],
            ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// 单行标签:不可选、不换行、超长尾部省略。
@MainActor
func makeLabel(
    _ text: String = "",
    font: NSFont,
    color: NSColor = Ink.primary,
    alignment: NSTextAlignment = .left
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

extension NSTextField {
    /// 值未变不写:写 stringValue 会让标签重新量尺寸、失效布局,读数每轮相同的
    /// 字段(标题、单位)不该跟着采样轮翻搅。
    func setText(_ text: String) {
        if stringValue != text {
            stringValue = text
        }
    }

    func setColor(_ color: NSColor) {
        if textColor != color {
            textColor = color
        }
    }
}

/// SF Symbol 图像(字号 / 字重同 SwiftUI `.font(.system(size:weight:))`)。
@MainActor
func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// 符号视图:着色走 `contentTintColor`(动态色随外观自适应)。
@MainActor
func makeSymbolView(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, tint: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = symbolImage(name, size: size, weight: weight)
    view.contentTintColor = tint
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
}

/// 横 / 竖排 NSStackView 便捷构造(SwiftUI HStack / VStack 对应物)。
@MainActor
func hstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = spacing
    stack.alignment = alignment
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

@MainActor
func vstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.spacing = spacing
    stack.alignment = alignment
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

/// 弹性空白(SwiftUI `Spacer`):低抱紧、低抗压,吃掉横排剩余宽度。
@MainActor
func spacer(minLength: CGFloat = 0) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: minLength).isActive = true
    return view
}

extension NSView {
    /// 四边贴齐父视图(带内距)。
    func pin(to parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// 定宽 / 定高(SwiftUI `.frame(width:height:)`)。
    @discardableResult
    func fixed(width: CGFloat? = nil, height: CGFloat? = nil) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        if let width {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if let height {
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return self
    }

    /// 撑满父栈宽度(SwiftUI `.frame(maxWidth: .infinity)` 在竖排里的对应物)。
    func fillWidth(of stack: NSStackView) {
        widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

/// 不响应鼠标的透明容器:让点击 / 悬停穿透给下层(卡片整卡可点时,卡内标签不截获)。
class PassthroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
