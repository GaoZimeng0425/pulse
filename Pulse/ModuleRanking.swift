import Foundation

// MARK: - 模块排行聚合(工单 01 UI 层):每 pid 读数字典 → 按组聚合的排行行
// 数据层只交每 pid 的差分/速率字典;展示要的是"按组聚合"的榜。pid → 组走
// 最新一轮归组结果(RankingBoard 传入主干同轮的 groups,组内成员即 pid 清单)——不重跑归组
// 引擎:归组需要 cwd / argv / 父链全套输入,主窗口采样循环已经算好,这里只查表。
// 快照里查不到的 pid(采样间隙新起 / 刚退出 / 受限查询)聚进"其他进程"桶:
// 不伪造组身份,图标由视图给通用符号瓦片。纯函数,单测见 ModuleRankingAggregatorTests。

/// 模块排行行(共用卡 ModuleRankingCardView 的渲染单元)。纯值类型。
struct ModuleRankingRow: Identifiable, Equatable, Sendable {
    /// 行身份 = 组规范键;"其他进程"桶不是组,用自有常量键(种类前缀约定保证不撞)。
    let id: String
    let name: String
    /// App 组的 .app bundle 目录(视图取真实应用图标);其余为 nil。
    let bundlePath: String?
    /// 非 App 组的类别(视图取类别瓦片样式);"其他进程"桶为 nil(通用符号)。
    let fallbackCategory: GroupCategory?
    /// 主值展示原值(能耗 = 秒 / 磁盘网络 = 字节每秒);排序与 meter 不用它,
    /// 用聚合层内部的 rankValue 口径(见各入口注释)。
    let primary: Double
    let primaryText: String
    let subtitle: String
    /// meter 占比:按 rankValue 全表榜首归一(MeterNormalization 现有口径)。
    let meterFraction: Double
}

enum ModuleRankingAggregator {
    /// "其他进程"桶的行键。
    static let otherProcessesKey = "other-processes"

    /// 能耗副文"唤醒/秒"的分母 = 能耗档的**约定窗长**(数据层
    /// ProcessRankingLedgers.energyWindow,唯一出处)。数据层对能耗故意不出速率
    /// (复合分是窗口差分),这里按窗长折算每秒,与卡底"5 秒一档"注脚同口径。
    private static let energyWindowSeconds = ProcessRankingLedgers.energyWindow

    /// 单 pid 原始读数(聚合输入):rankValue = 排序与 meter 归一口径;
    /// primary = 主值展示原值;secondaryA/B = 副文原值(语义随指标)。
    /// 文案在归组**之后**从合计值格式化——组行数值必须等于成员之和,
    /// 先格式化再拼字符串就加不回去了。
    private struct Readings: Sendable {
        var rankValue: Double
        var primary: Double
        var secondaryA: Double
        var secondaryB: Double = 0
    }

    /// 电池页·能耗影响行(工单 01):主值 = 本档 CPU 时间(秒,一位小数),
    /// 副文 = 唤醒/秒;排序与 meter 按复合分 impact——唤醒重的进程名次不亏
    /// (主值只管展示,复合分才是"影响"的口径)。
    static func energyRows(
        impacts: [pid_t: ProcessEnergyImpact],
        groups: [ProcessGroup]
    ) -> [ModuleRankingRow] {
        let readings = impacts.mapValues { impact in
            Readings(
                rankValue: Double(impact.impact),
                primary: Double(impact.cpuNanosDelta) / 1_000_000_000,
                secondaryA: Double(impact.wakeupsDelta) / energyWindowSeconds
            )
        }
        return rows(readings, groups: groups) { aggregate in
            (
                primaryText: PulseFormat.cpuSeconds(aggregate.primary),
                subtitle: "唤醒 \(PulseFormat.wakeupsPerSecond(aggregate.secondaryA))"
            )
        }
    }

    /// 磁盘页·读写最多行(工单 01):主值 = 读 + 写总速率;副文分列读写。
    static func diskRows(
        rates: [pid_t: ProcessDiskRates],
        groups: [ProcessGroup]
    ) -> [ModuleRankingRow] {
        let readings = rates.mapValues { rate in
            Readings(
                rankValue: rate.readBytesPerSec + rate.writeBytesPerSec,
                primary: rate.readBytesPerSec + rate.writeBytesPerSec,
                secondaryA: rate.readBytesPerSec,
                secondaryB: rate.writeBytesPerSec
            )
        }
        return rows(readings, groups: groups) { aggregate in
            (
                primaryText: PulseFormat.diskRate(aggregate.primary),
                subtitle: "读 \(PulseFormat.diskRate(aggregate.secondaryA)) · 写 \(PulseFormat.diskRate(aggregate.secondaryB))"
            )
        }
    }

    /// 网络页·每进程流量行(工单 01):主值 = 下 + 上总速率;副文箭头分列。
    static func networkRows(
        rates: [pid_t: ProcessNetworkRates],
        groups: [ProcessGroup]
    ) -> [ModuleRankingRow] {
        let readings = rates.mapValues { rate in
            Readings(
                rankValue: rate.downBytesPerSec + rate.upBytesPerSec,
                primary: rate.downBytesPerSec + rate.upBytesPerSec,
                secondaryA: rate.downBytesPerSec,
                secondaryB: rate.upBytesPerSec
            )
        }
        return rows(readings, groups: groups) { aggregate in
            (
                primaryText: PulseFormat.networkRateBadge(aggregate.primary),
                subtitle: "↓\(PulseFormat.networkRateBadge(aggregate.secondaryA)) ↑\(PulseFormat.networkRateBadge(aggregate.secondaryB))"
            )
        }
    }

    // MARK: 聚合主体(三指标共用)

    /// 归组 + 排序 + 归一 + 格式化的共同骨架:
    /// 1. 零值行剔除——0 差分 / 0 速率的进程是纯噪声(与 MemoryRingSegment
    ///    零字节分段同口径);全零时出空榜,交卡片空态安静兜底;
    /// 2. 有组的按组身份合计,快照外的 pid 全进"其他进程"桶;
    /// 3. 主值降序(次键规范键字典序,与组榜单同款,跨采样轮稳定)——
    ///    排序与 meter 榜首走 Leaderboard 内核,与组卡榜单同一份口径。
    private static func rows(
        _ readingsByPID: [pid_t: Readings],
        groups: [ProcessGroup],
        format: (Readings) -> (primaryText: String, subtitle: String)
    ) -> [ModuleRankingRow] {
        // 零值行剔除是模块排行的站点口径,有意不收进 Leaderboard 内核(组 tab 保留零值组)。
        let active = readingsByPID.filter { $0.value.rankValue > 0 }

        // pid → 组:归组引擎保证一个 pid 只归一组,查表即归组(后写覆盖不可能发生)。
        var groupByPID: [pid_t: ProcessGroup] = [:]
        for group in groups {
            for process in group.processes {
                groupByPID[process.pid] = group
            }
        }

        var totalsByID: [String: Readings] = [:]
        var metaByID: [String: (name: String, bundlePath: String?, category: GroupCategory?)] = [:]
        var other = Readings(rankValue: 0, primary: 0, secondaryA: 0)
        var otherCount = 0
        for (pid, readings) in active {
            if let group = groupByPID[pid] {
                let key = group.id.stableKey
                metaByID[key] = (group.name, group.bundlePath, group.category)
                var total = totalsByID[key] ?? Readings(rankValue: 0, primary: 0, secondaryA: 0)
                total.rankValue += readings.rankValue
                total.primary += readings.primary
                total.secondaryA += readings.secondaryA
                total.secondaryB += readings.secondaryB
                totalsByID[key] = total
            } else {
                other.rankValue += readings.rankValue
                other.primary += readings.primary
                other.secondaryA += readings.secondaryA
                other.secondaryB += readings.secondaryB
                otherCount += 1
            }
        }
        if otherCount > 0 {
            totalsByID[otherProcessesKey] = other
            metaByID[otherProcessesKey] = ("其他进程", nil, nil)
        }

        // meter 归一榜首 = 当前行集 rankValue 最大值(MeterNormalization:榜首满条,
        // 空榜/空载不除零)。行集非空时 leader > 0(零值行已剔除)。
        let leader = Leaderboard.leader(totalsByID.values, by: \.rankValue)

        return Leaderboard.ranked(totalsByID, by: { $0.value.rankValue }, id: { $0.key })
            .map { key, readings in
                let meta = metaByID[key]!
                let text = format(readings)
                return ModuleRankingRow(
                    id: key,
                    name: meta.name,
                    bundlePath: meta.bundlePath,
                    fallbackCategory: meta.category,
                    primary: readings.primary,
                    primaryText: text.primaryText,
                    subtitle: text.subtitle,
                    meterFraction: MeterNormalization.fraction(readings.rankValue, leader: leader)
                )
            }
    }
}
