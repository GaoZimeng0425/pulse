import Foundation

// MARK: - 指标 tab 内容模型(工单 P0.6-03):弹窗图标 tab / 主窗口药丸 tab 的共享逻辑

/// 指标 tab(工单 03):弹窗与主窗口共用同一组 tab——总览 / CPU / 内存 / 磁盘
/// (工单 05)/ 电池(工单 02)/ 历史(工单 04),后续指标(网络,P1+)按
/// `Metric` 令牌表加 case 即可。展示序(`allCases`)同时是键盘 ←/→ 的移动轴:
/// 总览最左、历史最右。
enum MetricTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case cpu
    case memory
    case disk
    case battery
    case history

    var id: String { rawValue }

    /// 中文标题:药丸 tab 文字、无障碍标签共用。
    var title: String {
        switch self {
        case .overview: "总览"
        case .cpu: "CPU"
        case .memory: "内存"
        case .disk: "磁盘"
        case .battery: "电池"
        case .history: "历史"
        }
    }

    /// 图标 tab 的 SF Symbol(弹窗顶部无文字 tab)。
    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .battery: "battery.100percent"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// 选中态强调色色源(工单 02 令牌表):总览以系统 CPU 负载为主视角取 cpu,
    /// CPU/内存/磁盘/电池各取自家令牌;历史页默认主视角是系统负载(工单 04
    /// 展示以系统负载为主、CPU 双口径注明),卡内曲线色另随所选指标取。
    var accent: Metric {
        switch self {
        case .overview: .cpu
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .battery: .battery
        case .history: .cpu
        }
    }

    /// 展示轴(工单 02):无内建电池的机器隐藏电池页——主窗口轴同时是药丸
    /// tab 渲染序与键盘 ←/→ 的移动范围(两端夹紧的端点随之收缩)。
    static func displayAxis(hasBattery: Bool) -> [MetricTab] {
        hasBattery ? allCases : allCases.filter { $0 != .battery }
    }

    /// 弹窗轴(工单 04 拍板:popover 不加历史):displayAxis 滤掉历史页,
    /// 其余语义(电池可用性)不变。
    static func popoverAxis(hasBattery: Bool) -> [MetricTab] {
        displayAxis(hasBattery: hasBattery).filter { $0 != .history }
    }
}

/// tab 选中状态 + 键盘切换语义(纯逻辑):←/→ 沿**展示轴**(displayAxis,
/// 默认全部)移动,**两端夹紧不回绕**——可预期的键盘行为,不做环游。
/// 视图焦点与按键接线(SwiftUI)属手动验收,这里只钉状态机。
struct MetricTabSelection: Equatable, Sendable {
    /// 渲染序与键盘移动轴:无电池机器不含电池页(工单 02)。
    private(set) var axis: [MetricTab]
    /// 当前 tab:tab 条点击与键盘切换都直接写(能点到的必然在轴上)。
    var current: MetricTab

    init(current: MetricTab = .overview, axis: [MetricTab] = MetricTab.allCases) {
        self.axis = axis
        // 轴外 tab(如无电池机器深链注入 .battery)不留悬空选中:回落总览。
        self.current = axis.contains(current) ? current : .overview
    }

    /// 电池页可用性变化(工单 02):换轴;被隐藏的当前 tab 回落总览。
    mutating func setAxis(_ newAxis: [MetricTab]) {
        axis = newAxis
        if !newAxis.contains(current) {
            current = .overview
        }
    }

    /// ← 键:切向轴上前一个;已在最左则不动。
    mutating func moveLeft() {
        move(offset: -1)
    }

    /// → 键:切向轴后一个;已在最右则不动。
    mutating func moveRight() {
        move(offset: 1)
    }

    private mutating func move(offset: Int) {
        guard let index = axis.firstIndex(of: current) else { return }
        current = axis[clamped(index + offset, in: axis.startIndex..<axis.count)]
    }
}

private func clamped(_ value: Int, in range: Range<Int>) -> Int {
    Swift.min(Swift.max(value, range.lowerBound), range.upperBound - 1)
}

// MARK: - 组卡读数口径(工单 03 纠偏:应用行回紧凑形态)

/// 组卡的大数字口径:CPU tab(与总览)以 CPU% 为主读数、内存为副文;
/// 内存 tab 互换(内存大数字 + CPU% 副文)。meter 与微图随口径同换。
enum GroupCardMetric: Equatable, Sendable {
    case cpu
    case memory
}

// MARK: - 内存环形分段(Memory by App 卡)

/// Memory by App 环形卡(工单 03)的一段:top-5 组各一段,尾部聚合成"其他"段
/// (`isOther = true`,图例用通用符号)。fraction = 该段字节 / 全部组内存合计。
/// `id` = 该段的组身份(工单 00 类型化);"其他"段不是组,身份为 nil。
struct MemoryRingSegment: Identifiable, Equatable, Sendable {
    /// 组身份;"其他"聚合段为 nil(不是组,不冒充组身份)。
    let id: GroupIdentity?
    let name: String
    /// App 组的 .app bundle 目录(图例取应用图标);"其他"段与其余类别为 nil。
    var bundlePath: String? {
        id?.bundlePath
    }
    /// 组类别(图例兜底符号);"其他"段为 nil。
    var category: GroupCategory? {
        id?.category
    }
    let bytes: UInt64
    /// 0–1,占全部组内存合计的比例。
    let fraction: Double
    let isOther: Bool
}

// MARK: - 单 tab 展示内容(纯逻辑)

/// 单个 tab 的展示内容(工单 03):由全部组 + tab 一次性折叠出该 tab UI 所需的
/// 全部口径——组卡榜单、微图资格、组卡读数口径、内存环形分段与两个 meter 榜首。
/// "哪个 tab 展示什么"只有这一个出处,弹窗与主窗口共用;单测即本接缝。
struct MetricTabContent: Equatable, Sendable {
    /// 26×14 微图资格:当前榜单前 3 名(参考文档 §2 紧凑行"部分带微图")。
    static let microGraphLimit = 3
    /// Memory by App 环形分段:top-5 + 其他(工单 03 拍板口径)。
    static let memorySegmentLimit = 5

    let tab: MetricTab
    /// 本 tab 的组卡榜单(降序口径随 tab;同值次键 id 升序,跨采样轮稳定)。
    let ranking: [ProcessGroup]
    /// 有 26×14 微图资格的组身份集合(榜单前缀)。
    let microGraphGroupIDs: Set<GroupIdentity>
    /// 组卡读数口径(大数字/meter/微图随它切换)。
    let metric: GroupCardMetric
    /// Memory by App 环形分段;空组或全零内存 → 空(由空态兜底,不出坏图)。
    let memorySegments: [MemoryRingSegment]
    /// 全部组内存合计(环心大数字)。
    let memoryTotalBytes: UInt64
    /// 内存 meter 归一榜首(工单 02 口径:当前全部组的最大值)。
    let memoryLeaderBytes: UInt64
    /// CPU meter 归一榜首。
    let cpuLeader: Double

    /// 折叠入口:总览/CPU/磁盘/电池 tab 按组 CPU% 降序(与引擎既定序一致;电池/
    /// 磁盘页不排组,榜单沿用 CPU 序供弹窗"当前最忙"卡),内存 tab 按内存降序;
    /// 分段基于全部组(与榜单口径无关,内存 tab 之外的 tab 也可渲染)。
    /// 历史 tab(工单 04)不渲染排行,走 CPU 序穷举兜底(轴外的弹窗根本切不到)。
    static func build(groups: [ProcessGroup], tab: MetricTab) -> MetricTabContent {
        let ranked: [ProcessGroup]
        let metric: GroupCardMetric
        switch tab {
        case .overview, .cpu, .disk, .battery, .history:
            ranked = groups.sorted { lhs, rhs in
                if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
                return lhs.id < rhs.id
            }
            metric = .cpu
        case .memory:
            ranked = groups.sorted { lhs, rhs in
                if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                return lhs.id < rhs.id
            }
            metric = .memory
        }

        let totalBytes = groups.reduce(UInt64(0)) { $0 + $1.memoryBytes }

        return MetricTabContent(
            tab: tab,
            ranking: ranked,
            microGraphGroupIDs: Set(ranked.prefix(microGraphLimit).map(\.id)),
            metric: metric,
            memorySegments: segments(for: groups, totalBytes: totalBytes),
            memoryTotalBytes: totalBytes,
            memoryLeaderBytes: groups.map(\.memoryBytes).max() ?? 0,
            cpuLeader: groups.map(\.cpuPercent).max() ?? 0
        )
    }

    /// 环形分段:零内存组先剔除(0 字节的段不可见、图例只添噪声),top-5 各一段,
    /// 尾部聚合"其他"(余量 > 0 才造);全零/空 → 空。
    private static func segments(for groups: [ProcessGroup], totalBytes: UInt64) -> [MemoryRingSegment] {
        guard totalBytes > 0 else { return [] }

        let rankedByMemory = groups
            .filter { $0.memoryBytes > 0 }
            .sorted { lhs, rhs in
                if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                return lhs.id < rhs.id
            }
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
}
