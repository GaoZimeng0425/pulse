import AppKit
import PulseCore
import SwiftUI

// 菜单栏徽标可配置(p1-history/09)的参数化位图渲染器。渲染先例的血泪教训沿用——MenuBarExtra 的 label 里
// 多张位图 Image 只渲染第一张,双徽标必须一次 ImageRenderer 合成**单张**
// 位图交系统(.renderingMode(.original),foregroundStyle 会被 NSStatusItem
// 剥掉,只有位图保得住颜色)。

// 槽位配置与数据快照在核心层 MenuBarBadgeConfiguration.swift,LRU 在 LRUBoundedCache.swift;
// 配置 → 渲染输入在 MenuBarBadgeComposer.swift。

// MARK: - 位图渲染器(参数化,单张合成)

/// 菜单栏徽标位图渲染器:渲染输入数组 → ImageRenderer → 单张 NSImage,按
/// (全部内容, 外观) 缓存——每轮采样最多一次位图化,值不变时零开销。
/// 缓存键为纯函数(单测钉死"配置变键变"):槽位顺序 / 文案 / 强调级 /
/// 外观任一变化都换键,内容相同的不同配置共享缓存不亏。
/// 缓存有界(评审修复):徽标文案逐轮变新键(网络速率数字刷新最频),
/// 无上限会常驻数周持续累积;上限 ~20 项——新旧键命中率稳态极高(负载/
/// 内存/磁盘数字变化低频,网络速率在几秒窗内来回切换仍命中),被挤出的
/// 旧键下次复访只重渲染一次(数毫秒),换来内存有界。
@MainActor
enum MenuBarBadgeRenderer {
    static let cacheCapacity = 20
    private static var cache = LRUBoundedCache<String, NSImage>(capacity: cacheCapacity)

    static func image(for contents: [MenuBarBadgeContent], colorScheme: ColorScheme) -> NSImage {
        let key = cacheKey(for: contents, colorScheme: colorScheme)
        if let cached = cache.hit(key) {
            return cached
        }

        let ink = colorScheme == .dark ? Color.white : Color.black
        let renderer = ImageRenderer(
            content: HStack(alignment: .center, spacing: 5) {
                ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                    switch content.layout {
                    case .captioned:
                        badge(
                            caption: content.caption,
                            valueText: content.text,
                            valueColor: color(for: content.emphasis, ink: ink),
                            ink: ink,
                            slotWidth: content.slotWidth
                        )
                    case .stacked:
                        stackedBadge(
                            lines: content.text.components(separatedBy: "\n"),
                            color: color(for: content.emphasis, ink: ink),
                            slotWidth: content.slotWidth
                        )
                    }
                }
            }
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let rendered: NSImage
        if let nsImage = renderer.nsImage {
            rendered = nsImage
        } else {
            // ImageRenderer 失效兜底:退回单行纯文本(不变色,但读数可见)。
            let text = contents.map(\.text).joined(separator: "  ")
            let width = ceil(MenuBarBadgeComposer.estimatedWidth(of: text)) + 4
            let fallback = NSImage(size: NSSize(width: max(16, width), height: 18))
            fallback.lockFocus()
            (text as NSString).draw(
                at: NSPoint(x: 2, y: 2),
                withAttributes: [
                    .font: NSFont.menuBarFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            fallback.unlockFocus()
            rendered = fallback
        }
        rendered.isTemplate = false // 绝不让系统把颜色又模板化掉
        cache.insert(rendered, forKey: key)
        return rendered
    }

    /// 缓存键(纯函数):外观 + 全部徽标内容。槽位配置的差异完全由内容承载
    /// (顺序 = 数组序,caption/text/emphasis 逐枚进键)。
    static func cacheKey(for contents: [MenuBarBadgeContent], colorScheme: ColorScheme) -> String {
        let body = contents
            .map { "\($0.caption)|\($0.text)|\($0.emphasis)|\($0.layout)" }
            .joined(separator: ";")
        return "\(colorScheme == .dark ? "dark" : "light")|\(body)"
    }

    /// 单枚徽标:小标签在数字上方(与可配置前的双徽标逐像素同款)。
    /// 数值行可带定宽槽(nil = 自然宽):左对齐钉住数字左缘,位数增减只向右
    /// 伸缩,位图总宽恒定——状态项宽度不再随读数抖动。槽宽是**下限**:数值
    /// 恒单行(fixedSize),超出参考串的罕见读数(>1TB 剩余的四位数)只撑宽,
    /// 绝不折行。
    private static func badge(
        caption: String,
        valueText: String,
        valueColor: Color,
        ink: Color,
        slotWidth: CGFloat?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(ink.opacity(0.55))
            Text(valueText)
                .font(.system(size: MenuBarBadgeComposer.valueFontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .fixedSize()
                .frame(minWidth: slotWidth, alignment: .leading)
        }
        .padding(.horizontal, 1)
    }

    /// 叠两行徽标(网络上下行):无小标签,两行同字号左对齐,定宽槽为下限、恒单行。
    private static func stackedBadge(lines: [String], color: Color, slotWidth: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: MenuBarBadgeComposer.stackedFontSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .fixedSize()
                    .frame(minWidth: slotWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 1)
    }

    /// 强调级 → 色:normal 墨色随外观,warning 橙,critical 红。
    private static func color(for emphasis: MenuBarBadgeContent.Emphasis, ink: Color) -> Color {
        switch emphasis {
        case .normal: ink
        case .warning: .orange
        case .critical: .red
        }
    }
}
