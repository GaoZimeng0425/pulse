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

// MARK: - 状态徽章语言(工单 P0.6-04 语义,评审 F1 并入 05 chip 实现)

/// 状态徽章:两态语言——✓正常(空载)与 高负载(警示)。外观不复刻 04 的
/// 独立组件,统一映射到 05 的 `MetricCardChip`(经 `MetricChipView` 渲染)——
/// 徽章 = 值得注意的偏差,出现在指标卡大数字旁与排行行名内。
enum StatusBadge: Equatable, Sendable {
    /// ✓ 正常:系统空载(参考文档 §2.2 "✓ Normal" 绿 chip 同款)。
    case normal
    /// 高负载:系统负载越红线,或组 CPU% 超 100%。
    case high

    /// 映射到 05 的 chip:正常 = 空载绿;高负载 = 危险红(不是孤儿橙——孤儿橙
    /// 专属"来历不明"语义,高负载是另一码事)。
    var chip: MetricCardChip {
        switch self {
        case .normal:
            MetricCardChip(title: "正常", systemImage: "checkmark", tint: Surface.positive)
        case .high:
            MetricCardChip(title: "高负载", systemImage: "exclamationmark.triangle.fill", tint: Surface.negative)
        }
    }
}

/// 徽章阈值规则(纯逻辑,单测见 StatusBadgeTests)。
/// 系统 = 三档语言(空载 ✓正常 / 高负载 / 中间静默);组卡只挂高负载警示——
/// 组级 ✓正常 会满屏绿 chip,与"徽章 = 值得注意的偏差"的语义冲突。
enum StatusBadgeRules {
    /// 组 CPU% 高负载线:**> 100%** 才算(恰好 100% = 单核满载,是正常可达值,不算;
    /// 工单钉死的边界)。GLOSSARY:组 CPU% 单核为 100%,445% ≈ 4.5 个核满载。
    static let groupHighLoadCPUThreshold: Double = 100
    /// 系统空载线:负载 < 30% 挂 ✓正常(恰 30% 落入静默档)。
    static let systemIdleLoadThreshold: Double = 30
    /// 系统高负载线:> 70%,与菜单栏变红同一口径(SystemMonitor.redThreshold,
    /// 字面量直写避免 MainActor 隔离引用;两处相等由单测 @MainActor 断言钉死)。
    static let systemHighLoadThreshold: Double = 70

    /// 系统负载徽章:> 70% → .high;< 30% → .normal;中间静默(nil,不挂 chip)。
    static func systemBadge(load: Double) -> StatusBadge? {
        if load > systemHighLoadThreshold { return .high }
        if load < systemIdleLoadThreshold { return .normal }
        return nil
    }

    /// 组卡徽章:组 CPU% > 100% → .high,否则不挂。
    static func groupBadge(cpuPercent: Double) -> StatusBadge? {
        cpuPercent > groupHighLoadCPUThreshold ? .high : nil
    }
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
    /// CPU 卡:当前负载 + 用户 / 系统 / 窗口均值;系统负载三档徽章
    /// (<30% ✓正常 / >70% 高负载 / 中间静默)挂大数字旁(工单 04 语义)。
    static func cpu(
        breakdown: CPULoadBreakdown,
        load: Double,
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
            chip: StatusBadgeRules.systemBadge(load: load)?.chip,
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
    /// 构成分段走 MemoryCompositionKey 单表(评审 F5):名称与色点唯一出处,
    /// 与 by-Type 环形卡同表;总览/主卡的统计列不展示"缓存"(05 形态拍板)。
    static func memory(_ memory: MemoryBreakdown?, trend: [UInt64], host: HostInfo) -> MetricCardModel {
        let total = PulseFormat.physicalMemoryTotal(memory?.totalBytes ?? host.physicalMemoryBytes)
        let figure = memory.map { PulseFormat.systemMemoryFigure($0.usedBytes) } ?? (value: "—", unit: "")
        let statKeys: [MemoryCompositionKey] = [.app, .wired, .compressed, .free]
        return MetricCardModel(
            metric: .memory,
            title: "内存",
            symbolName: "memorychip",
            caption: "已用 · 共 \(total)",
            figureValue: figure.value,
            figureUnit: figure.unit,
            chip: memory.map { pressureChip($0.pressure) },
            note: "共 \(total)",
            stats: statKeys.map { key in
                MetricCardStat(
                    label: key.title,
                    value: memory.map { PulseFormat.systemMemory($0.bytes(for: key)) } ?? "—",
                    dot: key == .free ? nil : key.color
                )
            },
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
            MetricCardChip(title: pressure.title, systemImage: "exclamationmark.triangle.fill", tint: Surface.negative)
        }
    }

    /// 电池卡(工单 02):大数字 = 电量,chip = 充电状态,四列小统计 =
    /// 剩余时间(充电时"充满还需")/ 健康度 / 循环次数 / 功率。
    /// 读数缺失(未首读 / 部分字段读不到)显示占位,不伪造;电池卡无走势
    /// (事件驱动,数值罕变),图表区只剩网格线。
    static func battery(_ reading: BatteryReading?) -> MetricCardModel {
        guard let reading else {
            return MetricCardModel(
                metric: .battery,
                title: "电池",
                symbolName: "battery.100percent",
                caption: "当前电量",
                figureValue: "—",
                figureUnit: "%",
                chip: nil,
                note: "",
                stats: [],
                trend: [],
                domainMax: 100
            )
        }
        let isCharging = reading.status == .charging
        return MetricCardModel(
            metric: .battery,
            title: "电池",
            symbolName: "battery.100percent",
            caption: isCharging ? "充电中 · 当前电量" : "当前电量",
            figureValue: PulseFormat.cpuPercentNumber(Double(reading.capacityPercent)),
            figureUnit: "%",
            chip: reading.status.chip,
            note: reading.status.title,
            stats: [
                MetricCardStat(
                    label: isCharging ? "充满还需" : "剩余时间",
                    value: PulseFormat.batteryTime(
                        minutes: isCharging ? reading.timeToFullMinutes : reading.timeToEmptyMinutes
                    )
                ),
                MetricCardStat(label: "健康度", value: reading.healthPercent.map { "\($0)%" } ?? "—"),
                MetricCardStat(label: "循环次数", value: reading.cycleCount.map(String.init) ?? "—"),
                MetricCardStat(label: "功率", value: reading.powerWatts.map(PulseFormat.watts) ?? "—"),
            ],
            trend: [],
            domainMax: 100
        )
    }
    /// 磁盘卡(工单 05):大数字 = 容器已用(十进制 GB,Finder 口径),四列小统计 =
    /// 实际可用(Finder「可用」importantUsage 口径)/ 可清除(两 key 差值,与
    /// 「实际可用」分开文案)/ 读取速率 / 写入速率;走势 = 读写合计流量。
    /// 读数缺失(首轮前 / 容量对账失败)显示占位,不伪造。
    static func disk(
        capacity: DiskCapacityReading?,
        throughput: DiskThroughputReading?
    ) -> MetricCardModel {
        guard let capacity else {
            return MetricCardModel(
                metric: .disk,
                title: "磁盘",
                symbolName: "internaldrive",
                caption: "已用",
                figureValue: "—",
                figureUnit: "GB",
                chip: nil,
                note: "",
                stats: [],
                trend: [],
                domainMax: 1
            )
        }
        let total = PulseFormat.diskCapacity(capacity.containerTotalBytes)
        let trend = throughput?.trend ?? []
        let trendValues = trend.map { $0.read + $0.write }
        return MetricCardModel(
            metric: .disk,
            title: "磁盘",
            symbolName: "internaldrive",
            caption: "已用 · 共 \(total)",
            figureValue: PulseFormat.diskCapacityFigure(capacity.containerUsedBytes).value,
            figureUnit: "GB",
            chip: nil,
            note: "",
            stats: [
                MetricCardStat(
                    label: "实际可用",
                    value: capacity.availableForImportantUsageBytes.map {
                        PulseFormat.diskCapacity(UInt64(max(0, $0)))
                    } ?? "—"
                ),
                MetricCardStat(
                    label: "可清除",
                    value: capacity.purgeableBytes.map { PulseFormat.diskCapacity(UInt64($0)) } ?? "—"
                ),
                MetricCardStat(
                    label: "读取",
                    value: throughput.map { PulseFormat.diskRate($0.current.readBytesPerSecond) } ?? "—"
                ),
                MetricCardStat(
                    label: "写入",
                    value: throughput.map { PulseFormat.diskRate($0.current.writeBytesPerSecond) } ?? "—"
                ),
            ],
            trend: trendValues,
            domainMax: max(1, trendValues.max() ?? 1)
        )
    }
    /// 网络卡(工单 06):大数字 = 下行速率(十进制 MB/s 口径),四列小统计 =
    /// 上行速率 / Today 合计 / 7 天合计 / 锁定接口(VPN 自动降级后的物理口);
    /// 走势 = 上 + 下合计流量。读数缺失(首轮前)与累计缺失(库缺席)显示
    /// 占位,不伪造。
    static func network(
        reading: NetworkRatesReading?,
        trend: [Double],
        totals: NetworkTotalsReading?
    ) -> MetricCardModel {
        let figure = reading.map { PulseFormat.networkRateFigure($0.rates.downBytesPerSecond) }
        return MetricCardModel(
            metric: .network,
            title: "网络",
            symbolName: "network",
            caption: reading.map {
                "下行速率 · \($0.interfaceName ?? "未知接口")"
            } ?? "下行速率",
            figureValue: figure?.value ?? "—",
            figureUnit: figure?.unit ?? "MB/s",
            chip: nil,
            note: "",
            stats: [
                MetricCardStat(
                    label: "上行",
                    value: reading.map { PulseFormat.networkRateBadge($0.rates.upBytesPerSecond) } ?? "—"
                ),
                MetricCardStat(
                    label: "Today",
                    value: totals.map {
                        PulseFormat.networkTotal($0.todayDownBytes + $0.todayUpBytes)
                    } ?? "—"
                ),
                MetricCardStat(
                    label: "7 天",
                    value: totals.map {
                        PulseFormat.networkTotal($0.weekDownBytes + $0.weekUpBytes)
                    } ?? "—"
                ),
                MetricCardStat(label: "接口", value: reading?.interfaceName ?? "—"),
            ],
            trend: trend,
            domainMax: max(1, trend.max() ?? 1)
        )
    }
}

extension BatteryChargeStatus {
    /// 状态 chip(工单 02):充电/充满 = Battery 绿;优化充电已介入 = disk 琥珀
    /// (系统接管中,非故障——调研 §2.3 的语义映射);放电 = 三级墨(常态,安静)。
    var chip: MetricCardChip {
        switch self {
        case .charging:
            MetricCardChip(title: title, systemImage: "bolt.fill", tint: Surface.positive)
        case .charged:
            MetricCardChip(title: title, systemImage: "checkmark", tint: Surface.positive)
        case .optimizedCharging:
            MetricCardChip(title: title, systemImage: "clock.badge.checkmark", tint: Metric.disk.accentColor)
        case .discharging:
            MetricCardChip(title: title, systemImage: "battery.50percent", tint: Surface.inkTertiary)
        }
    }
}

/// 指标卡:full = 主窗口总览网格(徽章 + 名称 + chevron / 34pt 大数字 / 三列小统计 /
/// 36pt 高 44 柱 strip);compact = 弹窗双列小卡(名称 / 大数字 + 一句补充 /
/// 36pt 44 柱 strip——工单 05 "指标卡底部 = strip",评审 F7 由 22pt 面积线对齐)。
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
            // 底部走势与 full 形态同款(工单 05 票面:36pt 高 44 柱 strip);
            // 面积线形态专属指标 tab 主卡(CPU tab 面积图),不在此用。
            StripChartView(values: model.trend, tint: model.tint, domainMax: model.domainMax)
                .frame(height: 36)
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
        load: 27,
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
