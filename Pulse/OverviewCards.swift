import SwiftUI

// MARK: - 总览指标卡(工单 P0.6-05,参考文档 §2.2 / OG 左图)

/// 指标卡的一列小统计(标签 + 数值,可带色点:内存卡 App/联动/压缩)。
struct MetricCardStat: Identifiable {
    let label: String
    let value: String
    var dot: Color?

    var id: String { label }
}

/// 状态 chip(Vitals 的 `✓ Normal`):全圆 pill,tint 14% 底 + 同色文字。
struct MetricCardChip {
    let title: String
    let systemImage: String
    let tint: Color
}

/// 一张指标卡的全部展示内容。builder 只做取数与格式化,视图只管排版。
struct MetricCardModel {
    let metric: Metric
    let title: String
    let symbolName: String
    /// 大数字上方的小标签("当前" / "已用 · 共 64 GB")。
    let caption: String
    let figureValue: String
    let figureUnit: String
    var chip: MetricCardChip?
    /// 紧凑卡大数字右侧的一句补充(弹窗双列卡没有三列统计的位置)。
    let note: String
    /// 小统计:总览卡取前 3 列,tab 主卡全部展示。
    let stats: [MetricCardStat]
    let trend: [Double]
    /// 走势归一上限:CPU 固定 0–100,内存 = 物理总量。
    let domainMax: Double

    var tint: Color { metric.accentColor }
}

extension MetricCardModel {
    /// CPU 卡:当前负载 + 用户 / 系统 / 窗口均值。
    static func cpu(
        breakdown: CPULoadBreakdown,
        statistics: SeriesStatistics?,
        trend: [Double]
    ) -> MetricCardModel {
        let average = statistics.map { PulseFormat.cpuPercent($0.average) } ?? "—"
        return MetricCardModel(
            metric: .cpu,
            title: "CPU",
            symbolName: "cpu",
            caption: "当前",
            figureValue: PulseFormat.cpuPercentNumber(breakdown.total),
            figureUnit: "%",
            note: "均值 \(average)",
            stats: [
                MetricCardStat(label: "用户", value: PulseFormat.cpuPercent(breakdown.user)),
                MetricCardStat(label: "系统", value: PulseFormat.cpuPercent(breakdown.system)),
                MetricCardStat(label: "均值", value: average),
                MetricCardStat(label: "峰值", value: statistics.map { PulseFormat.cpuPercent($0.peak) } ?? "—"),
            ],
            trend: trend,
            domainMax: 100
        )
    }

    /// 内存卡:已用 / 物理总量 + 压力 chip + App / 联动 / 压缩构成。
    /// 读数缺失(首轮前 / 读失败)显示占位,不伪造。
    static func memory(_ memory: MemoryBreakdown?, trend: [UInt64], host: HostInfo) -> MetricCardModel {
        let total = PulseFormat.physicalMemoryTotal(memory?.totalBytes ?? host.physicalMemoryBytes)
        let figure = memory.map { PulseFormat.systemMemoryFigure($0.usedBytes) } ?? (value: "—", unit: "")
        let format: (KeyPath<MemoryBreakdown, UInt64>) -> String = { keyPath in
            memory.map { PulseFormat.systemMemory($0[keyPath: keyPath]) } ?? "—"
        }
        return MetricCardModel(
            metric: .memory,
            title: "内存",
            symbolName: "memorychip",
            caption: "已用 · 共 \(total)",
            figureValue: figure.value,
            figureUnit: figure.unit,
            chip: memory.map { pressureChip($0.pressure) },
            note: "共 \(total)",
            stats: [
                MetricCardStat(label: "App", value: format(\.appBytes), dot: Metric.cpu.accentColor),
                MetricCardStat(label: "联动", value: format(\.wiredBytes), dot: Surface.projectsAccent),
                MetricCardStat(label: "压缩", value: format(\.compressedBytes), dot: Metric.network.accentColor),
                MetricCardStat(label: "空闲", value: format(\.freeBytes)),
            ],
            trend: trend.map { Double($0) },
            domainMax: Double(memory?.totalBytes ?? host.physicalMemoryBytes)
        )
    }

    static func pressureChip(_ pressure: MemoryPressure) -> MetricCardChip {
        switch pressure {
        case .normal:
            MetricCardChip(title: pressure.title, systemImage: "checkmark.circle.fill", tint: Surface.positive)
        case .warning:
            MetricCardChip(title: pressure.title, systemImage: "exclamationmark.circle.fill", tint: Metric.disk.accentColor)
        case .critical:
            MetricCardChip(title: pressure.title, systemImage: "exclamationmark.triangle.fill", tint: .red)
        }
    }
}

/// 指标卡:full = 主窗口总览网格(徽章 + 名称 + chevron / 34pt 大数字 / 三列小统计 /
/// 36pt 高 44 柱 strip);compact = 弹窗双列小卡(名称 / 大数字 + 一句补充 / 细走势线)。
/// 整卡可点,跳到对应指标 tab(Vitals `data-goto`)。
struct MetricCardView: View {
    enum Style {
        case full
        case compact
    }

    let model: MetricCardModel
    var style: Style = .full
    let onOpen: () -> Void

    /// 总览卡三列小统计(§2.2)。
    private static let overviewStatCount = 3

    var body: some View {
        Button(action: onOpen) {
            Group {
                switch style {
                case .full: fullBody
                case .compact: compactBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: .rect(cornerRadius: style == .full ? 18 : 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开\(model.title)详情")
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                MetricBadge(symbolName: model.symbolName, tint: model.tint)
                Text(model.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(model.tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    FigureText(value: model.figureValue, unit: model.figureUnit, size: 34)
                    Spacer(minLength: 8)
                    if let chip = model.chip {
                        MetricChipView(chip: chip)
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.stats.prefix(Self.overviewStatCount)) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let dot = stat.dot {
                                Circle().fill(dot).frame(width: 6, height: 6)
                            }
                            Text(stat.label)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        Text(stat.value)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            StripChartView(values: model.trend, tint: model.tint, domainMax: model.domainMax)
                .frame(height: 36)
        }
        .padding(16)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: model.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.tint)
                Text(model.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                FigureText(value: model.figureValue, unit: model.figureUnit, size: 22)
                Spacer(minLength: 4)
                Text(model.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            AreaTrendChartView(values: model.trend, tint: model.tint, domainMax: model.domainMax, showsGrid: false)
                .frame(height: 22)
        }
        .padding(10)
    }
}

/// 大数字(§1.2 figure):圆体加粗 + tabular + 负字距,单位约半号、基线对齐。
struct FigureText: View {
    let value: String
    let unit: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .kerning(-size * 0.02)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// 图标徽章(§1.3 `.badge`):22×22,tint 16% 底,圆角 7。
struct MetricBadge: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 7))
    }
}

/// 状态 chip(§3-6):全圆 pill,tint 14% 底 + 同色文字与图标。
struct MetricChipView: View {
    let chip: MetricCardChip

    var body: some View {
        Label(chip.title, systemImage: chip.systemImage)
            .labelStyle(ChipLabelStyle())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(chip.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(chip.tint.opacity(0.14), in: .capsule)
    }

    private struct ChipLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon.font(.system(size: 9.5))
                configuration.title
            }
        }
    }
}

/// 分区标题(主窗口 "此刻" / "当前最忙",SHOT1 `Worth a Look` 同款)。
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("指标卡") {
    let host = HostInfo(chipName: "Apple M4 Pro", coreCount: 12, physicalMemoryBytes: 51_539_607_552)
    let trend: [Double] = (0..<44).map { Double(($0 * 7) % 40 + 10) }
    let memory = MemoryBreakdown(
        totalBytes: 51_539_607_552, appBytes: 21_000_000_000, wiredBytes: 6_000_000_000,
        compressedBytes: 9_000_000_000, cachedBytes: 8_000_000_000, pressure: .normal
    )
    let cpu = MetricCardModel.cpu(
        breakdown: CPULoadBreakdown(total: 27, user: 19, system: 8),
        statistics: SeriesStatistics(count: 10, average: 36, peak: 71, minimum: 4),
        trend: trend
    )
    let mem = MetricCardModel.memory(memory, trend: [], host: host)
    return VStack(spacing: 16) {
        HStack(spacing: 16) {
            MetricCardView(model: cpu) {}
            MetricCardView(model: mem) {}
        }
        HStack(spacing: 8) {
            MetricCardView(model: cpu, style: .compact) {}
            MetricCardView(model: mem, style: .compact) {}
        }
        .frame(width: 330)
    }
    .padding(24)
    .frame(width: 720)
    .background(Surface.window)
}
