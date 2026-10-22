import PulseCore
import SwiftUI

// MARK: - 传感器页卡片(p2-sensors/04)

// 数据形状(命名表/解码/坏值防御/派生)在核心层 SmcModel + SmcNamingTable
// (纯逻辑,单测覆盖);本文件只做 SwiftUI 外观——派生读数卡 + 风扇卡 +
// 温度明细折叠卡,弹窗(紧凑)与主窗口共用,走预览 + 手动验收。

/// 派生读数卡(GLOSSARY「派生传感器」):Average/Hottest × CPU/GPU/系统 六行,
/// meter 以 110°C 恒定域归一(温度域稳定,不随榜首跳)。
struct SmcDerivedCardView: View {
    let reading: SmcReading?
    var isCompact = false

    private static let scaleMax = 110.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "thermometer.medium",
                title: "派生读数",
                tint: Metric.sensors.accentColor,
                note: reading.map { "\(knownCount($0)) 个命名传感器在场" }
            )
            if let derived = reading?.derived {
                VStack(spacing: 6) {
                    row("CPU 均值", derived.cpuAverage)
                    row("CPU 最热", derived.cpuHottest)
                    row("GPU 均值", derived.gpuAverage)
                    row("GPU 最热", derived.gpuHottest)
                    row("SoC 均值", derived.socAverage)
                    row("SoC 最热", derived.socHottest)
                }
            } else {
                CardEmptyState(title: "传感器暂不可用")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private func knownCount(_ reading: SmcReading) -> Int {
        reading.knownTemps.count
    }

    private func row(_ title: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 64, alignment: .leading)
            MeterBar(
                fraction: value.map { min(max($0 / Self.scaleMax, 0), 1) } ?? 0,
                tint: Metric.sensors.accentColor
            )
            Text(value.map { String(format: "%.1f°C", $0) } ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

/// 风扇卡:每扇一行(rpm + 上下限刻度 meter),无扇机(台式 Mac 少数)安静占位。
struct SmcFansCardView: View {
    let reading: SmcReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "fanblades.fill",
                title: "风扇",
                tint: Metric.sensors.accentColor,
                note: reading.map { _ in noteText }
            )
            if let fans = reading?.fans, !fans.isEmpty {
                VStack(spacing: 6) {
                    ForEach(fans) { fan in
                        HStack(spacing: 8) {
                            Text(fan.name ?? "风扇 \(fan.id + 1)")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            MeterBar(
                                fraction: Self.fraction(fan),
                                tint: Metric.sensors.accentColor
                            )
                            Text("\(fan.rpm) rpm")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                    }
                }
            } else {
                CardEmptyState(title: "无风扇或暂不可用")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private var noteText: String {
        guard let fan = reading?.fans.first, fan.maxRpm > 0 else { return "" }
        return "上限 \(fan.maxRpm) rpm"
    }

    /// 归一:以上限为满条,钳 0…1(下限以下的读数按实际比例,钳底 0)。
    static func fraction(_ fan: SmcFanReading) -> Double {
        guard fan.maxRpm > 0 else { return 0 }
        return min(max(Double(fan.rpm) / Double(fan.maxRpm), 0), 1)
    }
}

/// 温度明细折叠卡:命名传感器按组分区(CPU/GPU/系统/传感器),表外键归
/// "未知"组(GLOSSARY「传感器命名表」);各区可折叠,CPU 区主窗口默认展开、
/// 其余默认收起;弹窗紧凑档只显示每组前 6 行。
struct SmcTempsDetailCardView: View {
    let reading: SmcReading?
    var isCompact = false
    @State private var expanded: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "list.bullet.rectangle",
                title: "温度明细",
                tint: Metric.sensors.accentColor,
                note: reading.map { "\($0.knownTemps.count + $0.unknownTemps.count) 个键在场" }
            )
            if let reading {
                ForEach([SmcSensorGroup.cpu, .gpu, .system, .sensor], id: \.self) { group in
                    let rows = reading.knownTemps.filter { $0.group == group }
                    if !rows.isEmpty {
                        section(
                            key: group.rawValue,
                            title: group.title,
                            rows: rows,
                            defaultExpanded: group == .cpu && !isCompact
                        )
                    }
                }
                if !reading.unknownTemps.isEmpty {
                    section(
                        key: SmcSensorGroup.unknown.rawValue,
                        title: SmcSensorGroup.unknown.title,
                        rows: reading.unknownTemps,
                        defaultExpanded: false
                    )
                }
            } else {
                CardEmptyState(title: "明细暂不可用")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section(key: String, title: String, rows: [SmcTempReading], defaultExpanded: Bool) -> some View {
        let isOpen = expanded[key] ?? defaultExpanded
        DisclosureGroup(isExpanded: Binding(
            get: { isOpen },
            set: { expanded[key] = $0 }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.prefix(isCompact ? 6 : rows.count)) { row in
                    HStack(spacing: 8) {
                        Text(row.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f°C", row.value))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Text("\(title)(\(rows.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
