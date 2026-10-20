import Foundation

// 菜单栏徽标可配置(p1-history/09)的纯值层:槽位配置及其编辑动作、数据快照。
// 配置 → 渲染输入的组合规则要按菜单栏字体量字宽(NSFont),在 app 的
// MenuBarBadgeComposer.swift;位图渲染在 MenuBarBadge.swift。

// MARK: - 槽位配置

/// 徽标槽位指标(工单 p1-history/09;四项可同时上屏)。
public enum MenuBarBadgeMetric: String, CaseIterable, Sendable {
    case cpu
    case ram
    case diskRemaining
    case networkRate

    /// 设置页与无障碍文案。
    public var label: String {
        switch self {
        case .cpu: "CPU 负载"
        case .ram: "内存占用"
        case .diskRemaining: "磁盘剩余 %"
        case .networkRate: "网络速率"
        }
    }
}

/// 槽位配置:1 到「指标总数」个槽位(四项可同时上屏,2026-10-20 用户要求),每槽一
/// 指标,顺序即菜单栏从左到右。
/// 以逗号连接的 rawValue 进 @AppStorage(RawRepresentable 直存),
/// 持久与"配置即时生效、重启保留"都由 UserDefaults 承担。
public struct MenuBarBadgeConfiguration: Equatable, RawRepresentable, Sendable {
    /// 合法槽位数:1 到指标总数(原 spec 1–3,2026-10-20 放开)。
    public static let slotRange = 1...MenuBarBadgeMetric.allCases.count
    /// 默认配置(Round-2 共识):CPU + RAM,与可配置前的现状一致。
    public static let `default` = MenuBarBadgeConfiguration(slots: [.cpu, .ram])

    /// 降级(spec 验收):非法配置(空 / 超上限)回落默认,不崩不猜。
    public init(slots: [MenuBarBadgeMetric]) {
        self.slots = Self.slotRange.contains(slots.count) ? slots : Self.default.slots
    }

    /// 非法 rawValue(未知指标、空、数量越界)返回 nil,由调用方 `?? .default`
    /// 回默认——降级判定集中在一处,单测钉死。未知 token 不静默丢弃:
    /// 丢弃会把坏配置改写成另一个合法子集,宁可回默认让用户重选。
    public init?(rawValue: String) {
        let tokens = rawValue.split(separator: ",")
        let metrics = tokens.compactMap { MenuBarBadgeMetric(rawValue: String($0)) }
        guard Self.slotRange.contains(metrics.count), metrics.count == tokens.count else { return nil }
        self.slots = metrics
    }

    public var slots: [MenuBarBadgeMetric]

    public var rawValue: String {
        slots.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - 数据快照

/// 徽标数据快照:视图层从 SystemMonitor 折叠而来,映射纯函数的唯一输入
/// (全部合成值可注入,单测不触碰真实采样)。
public struct MenuBarBadgeData: Equatable, Sendable {
    /// 系统 CPU 负载 0–100(GLOSSARY 口径);nil 视同 0(与旧标签一致)。
    public var cpuLoadPercent: Double?
    /// 内存构成:RAM 占比与压力变色的来源;nil = 首轮前,占位。
    public var memory: MemoryBreakdown?
    /// 磁盘实际可用字节(important 口径,工单 p1-history/05 的 lastGood);nil = 未到读数。
    public var diskAvailableBytes: Int64?
    /// 磁盘容器总容量(剩余百分比的分母);nil = 未到读数。
    public var diskTotalBytes: UInt64?
    /// 网络速率(p1-history/06 填充):直用核心层 NetworkModel 的 NetworkRates——p1-history/09 的
    /// 壳契约副本已并入该类型(字段不再两次转译);nil = 未上线/未到读数,占位。
    public var networkRate: NetworkRates?

    public init(
        cpuLoadPercent: Double? = nil,
        memory: MemoryBreakdown? = nil,
        diskAvailableBytes: Int64? = nil,
        diskTotalBytes: UInt64? = nil,
        networkRate: NetworkRates? = nil
    ) {
        self.cpuLoadPercent = cpuLoadPercent
        self.memory = memory
        self.diskAvailableBytes = diskAvailableBytes
        self.diskTotalBytes = diskTotalBytes
        self.networkRate = networkRate
    }
}

// MARK: - 设置页用配置编辑动作

/// 编辑动作是纯函数式"改槽位数组 → 重新合法性收口 → 返回新配置":合法化
/// 全在 MenuBarBadgeConfiguration 构造器,这里不出现第二个降级判定;
/// 调用方把返回值的 rawValue 写回 @AppStorage。
extension MenuBarBadgeConfiguration {
    public func replacingSlot(at index: Int, with metric: MenuBarBadgeMetric) -> MenuBarBadgeConfiguration {
        var slots = self.slots
        guard slots.indices.contains(index) else { return self }
        slots[index] = metric
        return MenuBarBadgeConfiguration(slots: slots)
    }

    public func movingSlot(at index: Int, direction: MoveDirection) -> MenuBarBadgeConfiguration {
        var slots = self.slots
        guard slots.indices.contains(index) else { return self }
        let target = direction == .up ? index - 1 : index + 1
        guard slots.indices.contains(target) else { return self }
        slots.swapAt(index, target)
        return MenuBarBadgeConfiguration(slots: slots)
    }

    public func removingSlot(at index: Int) -> MenuBarBadgeConfiguration {
        var slots = self.slots
        guard slots.indices.contains(index), slots.count > Self.slotRange.lowerBound else { return self }
        slots.remove(at: index)
        return MenuBarBadgeConfiguration(slots: slots)
    }

    public func appendingSlot() -> MenuBarBadgeConfiguration {
        guard slots.count < Self.slotRange.upperBound else { return self }
        // 追加首个未上屏的指标,四项都上了则循环回 CPU(槽位允许重复指标)。
        let next = MenuBarBadgeMetric.allCases.first { !slots.contains($0) } ?? .cpu
        return MenuBarBadgeConfiguration(slots: slots + [next])
    }

    public enum MoveDirection: Sendable {
        case up
        case down
    }
}
