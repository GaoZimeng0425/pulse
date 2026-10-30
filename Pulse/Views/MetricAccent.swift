import AppKit
import PulseCore
import SwiftUI

// MARK: - 指标强调色令牌(工单 P0.6-02):Pulse 从"全灰"到"每指标一色"的色源

extension Metric {
    /// 浅深自适应强调色:浅色外观取 light、深色取 dark(令牌表即色值)。
    /// 动态 NSColor provider 让同一 `Color` 随系统外观切换;浅深切换的观感
    /// 属预览 + 手动验收(spec 测试决策:UI 不写单元测试)。
    var accentColor: Color {
        Color.dynamic(light: accent.light, dark: accent.dark)
    }
}

// MARK: - 表面令牌(工单 P0.6-05,参考文档 §1.1 中性色)

/// 窗底 / 卡底 / 卡内抬升底 + 环形图用到的辅助色。Vitals 的层级只有
/// "窗 > 卡 > 卡内元素"三级:卡与窗底只差一档,不描边不投影(§1.4)。
enum Surface {
    /// 窗口 / 弹窗本体底(`--raised`)。
    static let window = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1A1D)
    /// 卡片底(`--card`)。
    static let card = Color.dynamic(light: 0xF5F5F7, dark: 0x1F1F22)
    /// 卡内强调底、环形"其他/空闲"段(`--card-hi`)。
    static let cardHigh = Color.dynamic(light: 0xE8E8ED, dark: 0x27272B)
    /// 三级墨色(`--ink-3`):环形"缓存"段。
    static let inkTertiary = Color.dynamic(light: 0xA1A1A6, dark: 0x6E6E73)
    /// Projects 指标色:内存构成环的"联动"段(§2.2 by Type 配色)。
    static let projectsAccent = Color.dynamic(light: 0xEB6834, dark: 0xD95926)
    /// 正常态绿 = Battery 指标色(§1.1):内存压力 "正常" chip 与电池卡状态
    /// chip 同源(工单 02 起 Metric.battery 入表,此处改为别名,不再抄第二份 hex)。
    static let positive = Metric.battery.accentColor
    /// 危险色(参考文档 §1.1 `--red`):内存压力 "紧张"、高负载警示 chip、
    /// 结束整组图标等"值得注意的负面偏差"的唯一出处(深色补系统红暗色变体,
    /// 参考文档未给暗色值)。
    static let negative = Color.dynamic(light: 0xE0352B, dark: 0xFF453A)
    /// 警示色(`{colors.state-warning}`,琥珀):内存压力"偏高"、优化充电介入、触发中
    /// 告警横幅等"值得留意但未到危险"的唯一出处——取 Disk 指标色的别名,不抄第二份 hex。
    static let warning = Metric.disk.accentColor
    /// 状态点"停 / 未连接"(`{colors.state-inactive}`,p2-review/03 入表):系统 secondary
    /// 降到 40%——与亮起态的指标色点成对,不是文字层级,所以单立令牌而非用 `.tertiary`。
    /// 容器行(未运行)与蓝牙设备行(未连接)共用。
    static let inactive = Color.secondary.opacity(0.4)
}

// MARK: - 类别身份色(arch-review-2026-10-18/02 中8)

extension GroupCategory {
    /// 类别身份色(非 App 组的图标瓦片底色;孤儿另作组行强调色)的唯一出处,
    /// 与 Metric 指标色同级。孤儿 = 橙(GLOSSARY:"UI 中橙色高亮——它往往正是问题所在"),
    /// 有意不与 `{colors.state-warning}` 琥珀合并:孤儿是身份,不是强调级。
    var identityColor: Color {
        switch self {
        case .app: Self.appIdentity
        case .project: Metric.cpu.accentColor
        case .system: Self.systemIdentity
        case .backgroundService: Metric.network.accentColor
        case .orphan: Self.orphanIdentity
        }
    }

    /// app 组渲染走真实应用图标,此色仅样式表完备性的理论兜底。
    private static let appIdentity = Color.dynamic(light: 0xA2845E, dark: 0xAC8E68)
    private static let systemIdentity = Color.dynamic(light: 0x8E8E93, dark: 0x98989D)
    private static let orphanIdentity = Color.dynamic(light: 0xFF9500, dark: 0xFF9F0A)
}

// MARK: - 内存构成单表(工单 P0.6-05,评审 F5 去重)

/// 内存 by-Type 分段的展示键(名称 + 色):总览内存卡统计点与 by-Type 环形卡
/// 分段的唯一出处——模式同 `GroupCategory.cardStyle` 单表,改配色只动这里。
/// 段色 = §2.2 by Type 配色:App = CPU 蓝 / 联动 = Projects 橙 / 压缩 = Network 绿 /
/// 缓存 = ink-3 / 空闲 = card-hi。
enum MemoryCompositionKey: String, CaseIterable, Identifiable, Sendable {
    case app
    case wired
    case compressed
    case cached
    case free

    var id: String {
        rawValue
    }

    /// 中文段名:内存卡统计点标签与环形图例共用。
    var title: String {
        switch self {
        case .app: "App"
        case .wired: "联动"
        case .compressed: "压缩"
        case .cached: "缓存"
        case .free: "空闲"
        }
    }

    /// 段色(单表;by-Type 环与统计点色点都从这里取)。
    var color: Color {
        switch self {
        case .app: Metric.cpu.accentColor
        case .wired: Surface.projectsAccent
        case .compressed: Metric.network.accentColor
        case .cached: Surface.inkTertiary
        case .free: Surface.cardHigh
        }
    }
}

extension MemoryBreakdown {
    /// 单表键 → 构成字节(映射纯逻辑,单测见 SystemStatsTests)。
    func bytes(for key: MemoryCompositionKey) -> UInt64 {
        switch key {
        case .app: appBytes
        case .wired: wiredBytes
        case .compressed: compressedBytes
        case .cached: cachedBytes
        case .free: freeBytes
        }
    }
}

extension Color {
    /// 浅深自适应色:动态 NSColor provider 让同一 `Color` 随系统外观切换。
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    /// 0xRRGGBB → 不透明 sRGB 颜色(令牌表 hex 的唯一解码点)。
    convenience init(srgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
