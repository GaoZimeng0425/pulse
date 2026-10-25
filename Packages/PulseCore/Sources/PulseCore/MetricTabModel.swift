import Foundation

// MARK: - 指标 tab 内容模型(工单 P0.6-03):弹窗图标 tab / 主窗口药丸 tab 的共享逻辑

/// 指标 tab(工单 03):弹窗与主窗口共用同一组 tab——总览 / CPU / 内存 / 磁盘
/// (工单 05)/ 网络(工单 06)/ 电池(工单 02)/ 历史(工单 04)。展示序
/// (`allCases`)同时是键盘 ←/→ 的移动轴:总览最左、历史最右。
public enum MetricTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case cpu
    case memory
    case gpu
    case sensors
    case peripherals
    case disk
    case network
    case containers
    case battery
    case history

    public var id: String {
        rawValue
    }

    /// 中文标题:药丸 tab 文字、无障碍标签共用。
    public var title: String {
        switch self {
        case .overview: "总览"
        case .cpu: "CPU"
        case .memory: "内存"
        case .gpu: "GPU"
        case .sensors: "传感器"
        case .peripherals: "外设"
        case .disk: "磁盘"
        case .network: "网络"
        case .containers: "容器"
        case .battery: "电池"
        case .history: "历史"
        }
    }

    /// 图标 tab 的 SF Symbol(弹窗顶部无文字 tab)。
    public var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "circle.hexagongrid.fill"
        case .sensors: "thermometer.medium"
        case .peripherals: "headphones"
        case .disk: "internaldrive"
        case .network: "network"
        case .containers: "cube.box.fill"
        case .battery: "battery.100percent"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// 选中态强调色色源(工单 02 令牌表):总览以系统 CPU 负载为主视角取 cpu,
    /// CPU/内存/磁盘/网络/电池各取自家令牌;历史页默认主视角是系统负载(工单 04
    /// 展示以系统负载为主、CPU 双口径注明),卡内曲线色另随所选指标取。
    /// 选中胶囊、meter、图表全由令牌派生。
    public var accent: Metric {
        switch self {
        case .overview: .cpu
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .sensors: .sensors
        case .peripherals: .bluetooth
        case .disk: .disk
        case .network: .network
        case .containers: .containers
        case .battery: .battery
        case .history: .cpu
        }
    }

    /// 展示轴(工单 p1-history/02):无内建电池的机器隐藏电池页——主窗口与弹窗
    /// 同轴(2026-10-20 用户拍板:每个 tab 两处一致,弹窗也有历史页),同时是 tab
    /// 渲染序与键盘 ←/→ 的移动范围(两端夹紧的端点随之收缩)。
    public static func displayAxis(hasBattery: Bool) -> [MetricTab] {
        hasBattery ? allCases : allCases.filter { $0 != .battery }
    }
}

/// tab 选中状态 + 键盘切换语义(纯逻辑):←/→ 沿**展示轴**(displayAxis,
/// 默认全部)移动,**两端夹紧不回绕**——可预期的键盘行为,不做环游。
/// 视图焦点与按键接线(SwiftUI)属手动验收,这里只钉状态机。
public struct MetricTabSelection: Equatable, Sendable {
    /// 渲染序与键盘移动轴:无电池机器不含电池页(工单 02)。
    public private(set) var axis: [MetricTab]
    /// 当前 tab:tab 条点击与键盘切换都直接写(能点到的必然在轴上)。
    public var current: MetricTab

    public init(current: MetricTab = .overview, axis: [MetricTab] = MetricTab.allCases) {
        self.axis = axis
        // 轴外 tab(如无电池机器深链注入 .battery)不留悬空选中:回落总览。
        self.current = axis.contains(current) ? current : .overview
    }

    /// 电池页可用性变化(工单 02):换轴;被隐藏的当前 tab 回落总览。
    public mutating func setAxis(_ newAxis: [MetricTab]) {
        axis = newAxis
        if !newAxis.contains(current) {
            current = .overview
        }
    }

    /// ← 键:切向轴上前一个;已在最左则不动。
    public mutating func moveLeft() {
        move(offset: -1)
    }

    /// → 键:切向轴后一个;已在最右则不动。
    public mutating func moveRight() {
        move(offset: 1)
    }

    private mutating func move(offset: Int) {
        guard let index = axis.firstIndex(of: current) else { return }
        current = axis[clamped(index + offset, in: axis.startIndex ..< axis.count)]
    }
}

private func clamped(_ value: Int, in range: Range<Int>) -> Int {
    Swift.min(Swift.max(value, range.lowerBound), range.upperBound - 1)
}

// MARK: - 模块排行可见性判据(工单 01)

public extension MetricTab {
    /// 承载模块排行卡的 tab(电池·能耗影响 / 磁盘·读写最多 / 网络·每进程流量)。
    /// 主窗口可见性接线的判据来源(纯数据,成员资格由单测钉死)。
    static let moduleRankingTabs: Set<MetricTab> = [.battery, .disk, .network]

    /// 当前 tab 是否开排行采样闸(工单 01:模块页可见才跑 5s/30s 低频档)。
    var hostsModuleRanking: Bool {
        Self.moduleRankingTabs.contains(self)
    }
}

// MARK: - 传感器家族可见性判据(p2-review/05)

/// 5s UI 档随可见性门控的传感器家族(历史 30s 档不看闸,spec Story 24 成本纪律)。
/// 家族与 feature 一一对应:GPU 利用率 / ANE+五路功率(同 Energy Model 订阅,
/// 与 GPU 分立)/ SMC 温度风扇 / 蓝牙 / 容器。声音事件驱动不设家族。
public enum MetricSensorFamily: String, CaseIterable, Sendable, Hashable {
    case gpu
    case power
    case smc
    case bluetooth
    case containers
}

public extension MetricTab {
    /// 本 tab 实际展示哪些传感器家族(`MetricTabStack` 的卡片组成,口径住数据层
    /// 供 `MonitorVisibility.shows(_:)` 消费;成员资格由单测钉死,与视图层改动
    /// 对齐时同步)。总览的 GPU 卡吃 GPU 家族;CPU/内存/排行类 tab 无家族内容。
    var displayedFamilies: Set<MetricSensorFamily> {
        switch self {
        case .overview: [.gpu]
        case .gpu: [.gpu, .power]
        case .sensors: [.smc]
        case .peripherals: [.bluetooth]
        case .containers: [.containers]
        case .cpu, .memory, .disk, .network, .battery, .history: []
        }
    }
}

// MARK: - 组卡读数口径(工单 03 纠偏:应用行回紧凑形态)

/// 组卡的大数字口径:CPU tab(与总览)以 CPU% 为主读数、内存为副文;
/// 内存 tab 互换(内存大数字 + CPU% 副文)。meter 随口径同换。
public enum GroupCardMetric: Equatable, Sendable {
    case cpu
    case memory
}

// MARK: - 内存环形分段(Memory by App 卡)

/// Memory by App 环形卡(工单 03)的一段:top-5 组各一段,尾部聚合成"其他"段
/// (`isOther = true`,图例用通用符号)。fraction = 该段字节 / 全部组内存合计。
/// `id` = 该段的组身份(工单 00 类型化);"其他"段不是组,身份为 nil。
public struct MemoryRingSegment: Identifiable, Equatable, Sendable {
    /// 组身份;"其他"聚合段为 nil(不是组,不冒充组身份)。
    public let id: GroupIdentity?
    public let name: String
    /// App 组的 .app bundle 目录(图例取应用图标);"其他"段与其余类别为 nil。
    public var bundlePath: String? {
        id?.bundlePath
    }

    /// 组类别(图例兜底符号);"其他"段为 nil。
    public var category: GroupCategory? {
        id?.category
    }

    public let bytes: UInt64
    /// 0–1,占全部组内存合计的比例。
    public let fraction: Double
    public let isOther: Bool

    public init(id: GroupIdentity? = nil, name: String, bytes: UInt64, fraction: Double, isOther: Bool) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.fraction = fraction
        self.isOther = isOther
    }
}

// MARK: - 单 tab 展示内容(纯逻辑)

/// 单个 tab 的展示内容(工单 03):由全部组 + tab 一次性折叠出该 tab UI 所需的
/// 全部口径——组卡榜单、组卡读数口径、内存环形分段与两个 meter 榜首。
/// "哪个 tab 展示什么"只有这一个出处,弹窗与主窗口共用;单测即本接缝。
public struct MetricTabContent: Equatable, Sendable {
    /// Memory by App 环形分段:top-5 + 其他(工单 03 拍板口径)。
    public static let memorySegmentLimit = 5

    public let tab: MetricTab
    /// 本 tab 的组卡榜单(降序口径随 tab;同值次键 id 升序,跨采样轮稳定)。
    public let ranking: [ProcessGroup]
    /// 组卡读数口径(大数字/meter 随它切换)。
    public let metric: GroupCardMetric
    /// Memory by App 环形分段;空组或全零内存 → 空(由空态兜底,不出坏图)。
    public let memorySegments: [MemoryRingSegment]
    /// 全部组内存合计(环心大数字)。
    public let memoryTotalBytes: UInt64
    /// 内存 meter 归一榜首(工单 02 口径:当前全部组的最大值)。
    public let memoryLeaderBytes: UInt64
    /// CPU meter 归一榜首。
    public let cpuLeader: Double

    /// 折叠入口:总览/CPU/磁盘/电池 tab 按组 CPU% 降序(与引擎既定序一致;电池/
    /// 磁盘页不排组,榜单沿用 CPU 序供弹窗"当前最忙"卡),内存 tab 按内存降序;
    /// 分段基于全部组(与榜单口径无关,内存 tab 之外的 tab 也可渲染)。
    /// 历史 tab(工单 04)不渲染排行,走 CPU 序穷举兜底(轴外的弹窗根本切不到)。
    public static func build(groups: [ProcessGroup], tab: MetricTab) -> MetricTabContent {
        // 榜单与两个 meter 榜首走 Leaderboard 内核;零值组照常上榜是组 tab 的站点口径(有意不过滤)。
        let ranked: [ProcessGroup]
        let metric: GroupCardMetric
        switch tab {
        case .overview, .cpu, .gpu, .sensors, .peripherals, .disk, .network, .containers, .battery, .history:
            ranked = Leaderboard.ranked(groups, by: \.cpuPercent, id: \.id)
            metric = .cpu
        case .memory:
            ranked = Leaderboard.ranked(groups, by: \.memoryBytes, id: \.id)
            metric = .memory
        }

        let totalBytes = groups.reduce(UInt64(0)) { $0 + $1.memoryBytes }

        return MetricTabContent(
            tab: tab,
            ranking: ranked,
            metric: metric,
            memorySegments: segments(for: groups, totalBytes: totalBytes),
            memoryTotalBytes: totalBytes,
            memoryLeaderBytes: Leaderboard.leader(groups, by: \.memoryBytes),
            cpuLeader: Leaderboard.leader(groups, by: \.cpuPercent)
        )
    }

    /// 环形分段:零内存组先剔除(0 字节的段不可见、图例只添噪声),top-5 各一段,
    /// 尾部聚合"其他"(余量 > 0 才造);全零/空 → 空。
    private static func segments(for groups: [ProcessGroup], totalBytes: UInt64) -> [MemoryRingSegment] {
        guard totalBytes > 0 else { return [] }

        // 零字节组剔除是分段的站点口径,有意不收进 Leaderboard 内核(组 tab 榜单保留零值组)。
        let nonZero = groups.filter { $0.memoryBytes > 0 }
        let rankedByMemory = Leaderboard.ranked(nonZero, by: \.memoryBytes, id: \.id)
        let top = rankedByMemory.prefix(memorySegmentLimit)

        var segments = top.map { group in
            MemoryRingSegment(
                id: group.id,
                name: group.name,
                bytes: group.memoryBytes,
                fraction: Double(group.memoryBytes) / Double(totalBytes),
                isOther: false
            )
        }

        let otherBytes = totalBytes - top.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        if otherBytes > 0 {
            segments.append(
                MemoryRingSegment(
                    id: nil,
                    name: "其他",
                    bytes: otherBytes,
                    fraction: Double(otherBytes) / Double(totalBytes),
                    isOther: true
                )
            )
        }
        return segments
    }

    public init(
        tab: MetricTab,
        ranking: [ProcessGroup],
        metric: GroupCardMetric,
        memorySegments: [MemoryRingSegment],
        memoryTotalBytes: UInt64,
        memoryLeaderBytes: UInt64,
        cpuLeader: Double
    ) {
        self.tab = tab
        self.ranking = ranking
        self.metric = metric
        self.memorySegments = memorySegments
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryLeaderBytes = memoryLeaderBytes
        self.cpuLeader = cpuLeader
    }
}
