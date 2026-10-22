import PulseCore
import SwiftUI

// MARK: - 五路功率区(p2-sensors/03,GLOSSARY「五路功率」)

// 数据形状(通道映射/单位换算/差分)在核心层 PowerModel(纯逻辑,单测覆盖);
// 本文件只做 SwiftUI 外观,与流量累计明细卡同层——tab 主卡之下的补充卡,
// 走预览 + 手动验收(spec 测试决策)。

/// 五路功率区:在场域各一行(名称 + 瓦数 + meter 按五路榜首归一),合计随
/// 副标题走。读数缺失(订阅缺席/首轮前)给安静占位;通道缺席的域不出现,
/// 不伪造。行色:CPU/GPU/RAM 各取自家指标色,ANE 与 SoC 无独立令牌
/// (Neural 与 Memory 同色问题、SoC 无指标身份)——ANE 沿用 GPU 页强调色,
/// SoC 用三级墨(中性),口径记 p2-sensors/03。
struct PowerDomainsCardView: View {
    let reading: PowerReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "bolt.horizontal.fill",
                title: "五路功率",
                tint: Metric.gpu.accentColor,
                note: reading.map { "合计 \(Self.wattsText($0.totalWatts))" }
            )
            if let reading {
                let rows = Self.rows(for: reading)
                let leader = rows.map(\.watts).max() ?? 0
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 36, alignment: .leading)
                            MeterBar(fraction: MeterNormalization.fraction(row.watts, leader: leader), tint: row.tint)
                            Text(Self.wattsText(row.watts))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                }
                if rows.isEmpty {
                    CardEmptyState(title: "暂无在场功率通道")
                }
            } else {
                CardEmptyState(title: "功率暂不可用")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 行折叠(域 → 行;缺席域不出现)

    struct DomainRow: Identifiable {
        let domain: PowerDomain
        let watts: Double
        var id: String {
            domain.rawValue
        }

        var title: String {
            domain.title
        }

        var tint: Color {
            switch domain {
            case .cpu: Metric.cpu.accentColor
            case .gpu, .ane: Metric.gpu.accentColor
            case .ram: Metric.memory.accentColor
            case .soc: Surface.inkTertiary
            }
        }
    }

    static func rows(for reading: PowerReading) -> [DomainRow] {
        PowerDomain.allCases.compactMap { domain in
            reading.watts[domain].map { DomainRow(domain: domain, watts: $0) }
        }
    }

    /// 瓦数文案:<10 W 一位小数,≥10 W 取整。
    static func wattsText(_ watts: Double) -> String {
        watts < 10 ? String(format: "%.1f W", watts) : String(format: "%.0f W", watts)
    }
}
