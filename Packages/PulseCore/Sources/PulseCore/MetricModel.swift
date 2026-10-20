import Foundation

// 指标维度与强调色令牌(色值的唯一出处);把令牌变成 SwiftUI Color 的 `accentColor` 在 app target(MetricAccent.swift)。

/// 指标维度(P0.6-02):"每指标一色"的键,tab 化(工单 03)与 meter/图表从这里取色。
/// 收录参考文档 §1.1 全表中 Pulse 现阶段用得到的项:CPU/内存有实时数据,
/// 磁盘/网络为 tab 化"更多按需"预留,电池随 P1 工单 02 传感器卡入表;
/// GPU/Neural 属 P2、声音/蓝牙有意砍掉,需要时按同一张表补行(Neural 与
/// Memory 同色,参考文档已注明,故入表即破坏"指标间互异"前提——届时再议)。
public enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case battery
}

/// 单指标强调色令牌:浅/深双套,0xRRGGBB。色值唯一出处是
/// docs/ui/vitals-style-reference.md §1.1(Vitals 官网 CSS `:root` 与
/// `@media(prefers-color-scheme:dark)` 两块),单测逐字面量钉死。
public struct MetricAccentToken: Equatable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }
}

extension Metric {
    /// 令牌表:整个 app 取指标色的唯一入口。switch 穷举保证"每指标必有双套"
    /// (新增 case 不补行即编译失败);浅深互异、指标间互异由单测守护。
    public var accent: MetricAccentToken {
        switch self {
        case .cpu: MetricAccentToken(light: 0x2a78d6, dark: 0x3987e5)
        case .memory: MetricAccentToken(light: 0x4a3aa7, dark: 0x9085e9)
        case .disk: MetricAccentToken(light: 0xeda100, dark: 0xc98500)
        case .network: MetricAccentToken(light: 0x1baf7a, dark: 0x199e70)
        case .battery: MetricAccentToken(light: 0x008300, dark: 0x2fa83a)
        }
    }
}

/// meter 归一化(纯逻辑):占比条"按当前榜单榜首归一"的取值口径。
/// 榜首(最大值)= 满条;榜首 ≤ 0(空载/空榜/首轮采样前)一律 0,
/// 不画填充也不除零;越界值夹紧到 0…1。单测见 MeterBarTests。
public enum MeterNormalization {
    public static func fraction(_ value: Double, leader: Double) -> Double {
        guard leader > 0 else { return 0 }
        return min(max(value / leader, 0), 1)
    }
}
