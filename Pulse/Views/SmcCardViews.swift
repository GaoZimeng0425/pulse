import PulseCore
import SwiftUI

// MARK: - 传感器页卡片(p2-sensors/04)

// 数据形状(命名表/解码/坏值防御/派生/风扇归一)在核心层 SmcModel + SmcNamingTable
// (纯逻辑,单测覆盖);本文件只做 SwiftUI 外观——派生读数卡 + 风扇卡 +
// 温度明细折叠卡,走预览 + 手动验收。弹窗只放派生卡(p2-review/04 A 拍板,见
// MetricTabStack `.sensors`),风扇卡与明细卡只在主窗口出现。

/// 派生读数卡(GLOSSARY「派生传感器」):Average/Hottest × CPU/GPU/SoC 六行 + 最快风扇
/// (p2-review/08 ①;弹窗传感器 tab 唯一的卡,风扇信息全靠这一行承载)。温度 meter
/// 以 110°C 恒定域归一(温度域稳定,不随榜首跳);风扇 meter 按该扇上下限归一。
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
                    fanRow(reading?.fastestFan, fanCount: reading?.fans.count ?? 0)
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
        row(
            title,
            fraction: value.map { min(max($0 / Self.scaleMax, 0), 1) } ?? 0,
            valueText: value.map { String(format: "%.1f°C", $0) } ?? "—"
        )
    }

    /// 最快风扇行:无风扇 / 全读不到 → "—" 占位(不伪造 0 rpm);多扇时数值前带扇名,
    /// 让"哪一台在转"一眼可读(spec Story 7),单扇省掉扇名。
    private func fanRow(_ fan: SmcFanReading?, fanCount: Int) -> some View {
        let valueText = fan.map { fan in
            fanCount > 1 ? "\(SmcFanText.title(fan)) · \(SmcFanText.speed(fan))" : SmcFanText.speed(fan)
        } ?? "—"
        return row("最快风扇", fraction: fan?.speedFraction ?? 0, valueText: valueText)
    }

    private func row(_ title: String, fraction: Double, valueText: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 64, alignment: .leading)
            MeterBar(fraction: fraction, tint: Metric.sensors.accentColor)
            Text(valueText)
                .lineLimit(1)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

/// 风扇卡(主窗口):每扇一行,meter 按该扇上下限归一(p2-review/04 C 拍板,
/// `SmcFanReading.speedFraction`)并标出上下限——全部风扇上下限相同时只在卡头注记写一次,
/// 不同时逐行写在各扇行下(两处不同时出现);无扇机安静占位。
struct SmcFansCardView: View {
    let reading: SmcReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "fanblades.fill",
                title: "风扇",
                tint: Metric.sensors.accentColor,
                note: sharedLimitsNote
            )
            if let fans = reading?.fans, !fans.isEmpty {
                VStack(spacing: 6) {
                    ForEach(fans) { fan in
                        fanRow(fan, showsLimits: sharedLimitsNote == nil && fan.hasSpeedRange)
                    }
                }
            } else {
                CardEmptyState(title: "无风扇或暂不可用")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private func fanRow(_ fan: SmcFanReading, showsLimits: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(SmcFanText.title(fan))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                MeterBar(fraction: fan.speedFraction, tint: Metric.sensors.accentColor)
                Text(SmcFanText.speed(fan))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            if showsLimits {
                Text(SmcFanText.limits(fan))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 全部风扇上下限相同(常见:双扇同型号)且可用作标尺时,卡头注记写一次;
    /// 否则 nil,改由各扇行下逐行标注(上下限读不到的扇不标,与空条同一口径)。
    private var sharedLimitsNote: String? {
        guard let fans = reading?.fans, let first = fans.first, first.hasSpeedRange,
              fans.allSatisfy({ $0.minRpm == first.minRpm && $0.maxRpm == first.maxRpm })
        else { return nil }
        return SmcFanText.limits(first)
    }
}

/// 风扇文案(派生卡最快风扇行与风扇卡共用,一处定义)。
private enum SmcFanText {
    /// 扇名:SMC F?ID 原文,读不到用"风扇 N"(序号从 1 数)。
    static func title(_ fan: SmcFanReading) -> String {
        fan.name ?? "风扇 \(fan.id + 1)"
    }

    /// 转速:rpm 0 是真读数(低负载停转常态),写"停转"而非"0 rpm"——
    /// 读者要的是"转没转",0 rpm 易被看成读失败(DESIGN.md §Components 传感器卡)。
    static func speed(_ fan: SmcFanReading) -> String {
        fan.rpm == 0 ? "停转" : "\(fan.rpm) rpm"
    }

    static func limits(_ fan: SmcFanReading) -> String {
        "下限 \(fan.minRpm) · 上限 \(fan.maxRpm) rpm"
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
                // SoC 组(2026-10-23 审计④:SoC 派生键从 .sensor 归 .soc 独立成节)。
                ForEach([SmcSensorGroup.cpu, .gpu, .soc, .system, .sensor], id: \.self) { group in
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

// MARK: - 预览(合成载荷走核心 builder,与 Live 同一条折算路径)

private enum SmcPreviewData {
    /// fpe2 编码((b0<<6)+(b1>>2) 的逆)。
    static func fpe2(_ rpm: Int) -> [UInt8] {
        [UInt8((rpm >> 6) & 0xFF), UInt8((rpm & 0x3F) << 2)]
    }

    static func reading(fans: [(rpm: Int, min: Int, max: Int)]) -> SmcReading? {
        var keys = [
            SmcRawKey(key: "Tp01", dataType: "sp78", bytes: [55, 128]),
            SmcRawKey(key: "Tp05", dataType: "sp78", bytes: [61, 0]),
            SmcRawKey(key: "Tg05", dataType: "sp78", bytes: [48, 0]),
            SmcRawKey(key: "FNum", dataType: "ui8 ", bytes: [UInt8(fans.count)]),
        ]
        for (index, fan) in fans.enumerated() {
            keys += [
                SmcRawKey(key: "F\(index)Ac", dataType: "fpe2", bytes: fpe2(fan.rpm)),
                SmcRawKey(key: "F\(index)Mn", dataType: "fpe2", bytes: fpe2(fan.min)),
                SmcRawKey(key: "F\(index)Mx", dataType: "fpe2", bytes: fpe2(fan.max)),
            ]
        }
        return SmcReadingBuilder.make(from: SmcSnapshot(keys: keys, takenAt: .now), previous: nil)
    }
}

#Preview("派生卡 · 弹窗(双扇)") {
    SmcDerivedCardView(
        reading: SmcPreviewData.reading(fans: [(2400, 2300, 6500), (3200, 2300, 6000)]),
        isCompact: true
    )
    .frame(width: 336)
    .padding()
}

#Preview("派生卡 · 无风扇") {
    SmcDerivedCardView(reading: SmcPreviewData.reading(fans: []), isCompact: true)
        .frame(width: 336)
        .padding()
}

#Preview("风扇卡 · 上下限各异 / 停转") {
    VStack(spacing: 16) {
        SmcFansCardView(reading: SmcPreviewData.reading(fans: [(0, 2300, 6500), (4400, 2300, 6000)]))
        SmcFansCardView(reading: SmcPreviewData.reading(fans: [(3200, 2300, 6500), (3000, 2300, 6500)]))
    }
    .frame(width: 420)
    .padding()
}
