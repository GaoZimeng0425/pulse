import SwiftUI
import AppKit

// MARK: - 指标强调色令牌(工单 P0.6-02):Pulse 从"全灰"到"每指标一色"的色源

/// 指标维度(P0.6-02):"每指标一色"的键,tab 化(工单 03)与 meter/图表从这里取色。
/// 收录参考文档 §1.1 全表中 Pulse 现阶段用得到的四项:CPU/内存有实时数据,
/// 磁盘/网络为 tab 化"更多按需"预留;GPU/Neural/电池属 P2、声音/蓝牙有意砍掉、
/// Projects 属 P1,需要时按同一张表补行(Neural 与 Memory 同色,参考文档已注明,
/// 故入表即破坏"指标间互异"前提——届时再议)。
enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
    case disk
    case network
}

/// 单指标强调色令牌:浅/深双套,0xRRGGBB。色值唯一出处是
/// docs/ui/vitals-style-reference.md §1.1(Vitals 官网 CSS `:root` 与
/// `@media(prefers-color-scheme:dark)` 两块),单测逐字面量钉死。
struct MetricAccentToken: Equatable, Sendable {
    let light: UInt32
    let dark: UInt32
}

extension Metric {
    /// 令牌表:整个 app 取指标色的唯一入口。switch 穷举保证"每指标必有双套"
    /// (新增 case 不补行即编译失败);浅深互异、指标间互异由单测守护。
    var accent: MetricAccentToken {
        switch self {
        case .cpu: MetricAccentToken(light: 0x2a78d6, dark: 0x3987e5)
        case .memory: MetricAccentToken(light: 0x4a3aa7, dark: 0x9085e9)
        case .disk: MetricAccentToken(light: 0xeda100, dark: 0xc98500)
        case .network: MetricAccentToken(light: 0x1baf7a, dark: 0x199e70)
        }
    }

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
    static let window = Color.dynamic(light: 0xffffff, dark: 0x1a1a1d)
    /// 卡片底(`--card`)。
    static let card = Color.dynamic(light: 0xf5f5f7, dark: 0x1f1f22)
    /// 卡内强调底、环形"其他/空闲"段(`--card-hi`)。
    static let cardHigh = Color.dynamic(light: 0xe8e8ed, dark: 0x27272b)
    /// 三级墨色(`--ink-3`):环形"缓存"段。
    static let inkTertiary = Color.dynamic(light: 0xa1a1a6, dark: 0x6e6e73)
    /// Projects 指标色:内存构成环的"联动"段(§2.2 by Type 配色)。
    static let projectsAccent = Color.dynamic(light: 0xeb6834, dark: 0xd95926)
    /// 正常态绿(Battery 指标色):内存压力 "正常" chip。
    static let positive = Color.dynamic(light: 0x008300, dark: 0x2fa83a)
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
