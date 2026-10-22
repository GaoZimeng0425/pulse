import Foundation

// 指标维度与强调色令牌(色值的唯一出处);把令牌变成 SwiftUI Color 的 `accentColor` 在 app target(MetricAccent.swift)。

/// 指标维度(P0.6-02):"每指标一色"的键,tab 化(工单 03)与 meter/图表从这里取色。
/// 收录参考文档 §1.1 全表中 Pulse 现阶段用得到的项:CPU/内存有实时数据,
/// 磁盘/网络为 tab 化"更多按需"预留,电池随 P1 工单 02 传感器卡入表;
/// GPU 随 P2 工单 p2-sensors/02 入表;sensors(温度/风扇,p2-sensors/04)是
/// **Pulse 扩展行**——参考文档无温度面板独立色,自补珊瑚暖色(与 Disk 琥珀、
/// state-negative 红均拉开);Neural 与 Memory 同色(参考文档已注明),
/// 入表即破坏"指标间互异"前提——03 票再议;声音/蓝牙有意砍掉,需要时按表补行。
public enum Metric: String, CaseIterable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case battery
    case gpu
    case sensors
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

public extension Metric {
    /// 令牌表:整个 app 取指标色的唯一入口。switch 穷举保证"每指标必有双套"
    /// (新增 case 不补行即编译失败);浅深互异、指标间互异由单测守护。
    var accent: MetricAccentToken {
        switch self {
        case .cpu: MetricAccentToken(light: 0x2A78D6, dark: 0x3987E5)
        case .memory: MetricAccentToken(light: 0x4A3AA7, dark: 0x9085E9)
        case .disk: MetricAccentToken(light: 0xEDA100, dark: 0xC98500)
        case .network: MetricAccentToken(light: 0x1BAF7A, dark: 0x199E70)
        case .battery: MetricAccentToken(light: 0x008300, dark: 0x2FA83A)
        case .gpu: MetricAccentToken(light: 0xE87BA4, dark: 0xD55181)
        case .sensors: MetricAccentToken(light: 0xD96A4E, dark: 0xE07B5F)
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
