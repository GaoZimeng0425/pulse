import PulseCore
import SwiftUI

// MARK: - 指标卡内容模型(工单 P0.6-05,参考文档 §2.2 / OG 左图)

// 取数 + 格式化的折叠规则;字段带 SwiftUI Color(色点 / chip tint),故留 app。
// 排版在 OverviewCards.swift 的 MetricCardView。

/// 指标卡的一列小统计(标签 + 数值,可带色点:内存卡 App/联动/压缩)。
struct MetricCardStat: Identifiable {
    let label: String
    let value: String
    var dot: Color?

    var id: String {
        label
    }
}

/// 状态 chip(Vitals 的 `✓ Normal`):全圆 pill,tint 14% 底 + 同色文字。
struct MetricCardChip {
    let title: String
    let systemImage: String
    let tint: Color
}

extension StatusBadge {
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

    var tint: Color {
        metric.accentColor
    }
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
            MetricCardChip(title: pressure.title, systemImage: "exclamationmark.circle.fill", tint: Surface.warning)
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

    /// GPU 卡(p2-sensors/02):大数字 = 总利用率,四列小统计 = Renderer /
    /// Tiler / 显存在用 / 显存分配;走势 = 利用率环(0–100 恒定域)。
    /// 读数缺失(首轮前 / 无加速器)显示占位,不伪造;AGC 关电时 note 注明
    /// "电源管理已关电"(利用率 0 是正常态,调研 §2.4 防御点)。
    static func gpu(_ reading: GpuReading?, trend: [Double]) -> MetricCardModel {
        guard let reading else {
            return MetricCardModel(
                metric: .gpu,
                title: "GPU",
                symbolName: "circle.hexagongrid.fill",
                caption: "利用率",
                figureValue: "—",
                figureUnit: "%",
                chip: nil,
                note: "",
                stats: [],
                trend: [],
                domainMax: 100
            )
        }
        return MetricCardModel(
            metric: .gpu,
            title: "GPU",
            symbolName: "circle.hexagongrid.fill",
            caption: {
                let parts = [reading.modelName, reading.coreCount.map { "\($0) 核" }].compactMap(\.self)
                return parts.isEmpty ? "利用率" : "利用率 · " + parts.joined(separator: " · ")
            }(),
            figureValue: PulseFormat.cpuPercentNumber(reading.utilizationPercent),
            figureUnit: "%",
            chip: nil,
            note: reading.poweredOff ? "电源管理已关电" : "",
            stats: [
                MetricCardStat(label: "Renderer", value: reading.rendererPercent.map(PulseFormat.cpuPercent) ?? "—"),
                MetricCardStat(label: "Tiler", value: reading.tilerPercent.map(PulseFormat.cpuPercent) ?? "—"),
                MetricCardStat(
                    label: "显存在用",
                    value: reading.inUseBytes.map { PulseFormat.systemMemory(UInt64(max(0, $0))) } ?? "—"
                ),
                MetricCardStat(
                    label: "显存分配",
                    value: reading.allocatedBytes.map { PulseFormat.systemMemory(UInt64(max(0, $0))) } ?? "—"
                ),
            ],
            trend: trend,
            domainMax: 100
        )
    }

    /// ANE 卡(p2-sensors/03):大数字 = ANE 瓦数(GLOSSARY「五路功率」之 A 路),
    /// 四列小统计 = 归一化(芯片上限表,M4=6W)/ 五路合计 / 峰值;走势 = ANE 瓦数环。
    /// 强调色沿用 GPU 页(ANE 无独立令牌——Neural 与 Memory 同色,独立 tab 时再议,
    /// 口径记 p2-sensors/03)。读数缺失(订阅缺席/首轮前/通道不在)占位不伪造;
    /// 首读/断档轮 = 0 W 是差分语义(PowerAccumulator),显示 0 不是坏数。
    static func ane(
        power: PowerReading?,
        normalizedPercent: Double?,
        trend: [Double]
    ) -> MetricCardModel {
        guard let aneWatts = power?.watts[.ane] else {
            return MetricCardModel(
                metric: .gpu,
                title: "ANE",
                symbolName: "brain.filled",
                caption: "Neural Engine 功率",
                figureValue: "—",
                figureUnit: "W",
                chip: nil,
                note: "",
                stats: [],
                trend: [],
                domainMax: 1
            )
        }
        return MetricCardModel(
            metric: .gpu,
            title: "ANE",
            symbolName: "brain.filled",
            caption: "Neural Engine 功率",
            figureValue: aneWatts < 10 ? String(format: "%.1f", aneWatts) : String(format: "%.0f", aneWatts),
            figureUnit: "W",
            chip: nil,
            note: normalizedPercent.map { String(format: "归一化 %.0f%%", $0) } ?? "",
            stats: [
                MetricCardStat(label: "归一化", value: normalizedPercent.map { String(format: "%.0f%%", $0) } ?? "—"),
                MetricCardStat(
                    label: "五路合计",
                    value: power.map { PowerDomainsCardView.wattsText($0.totalWatts) } ?? "—"
                ),
                MetricCardStat(label: "峰值", value: trend.max().map { PowerDomainsCardView.wattsText($0) } ?? "—"),
            ],
            trend: trend,
            domainMax: max(1, trend.max() ?? 1)
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
            MetricCardChip(title: title, systemImage: "clock.badge.checkmark", tint: Surface.warning)
        case .discharging:
            MetricCardChip(title: title, systemImage: "battery.50percent", tint: Surface.inkTertiary)
        }
    }
}
