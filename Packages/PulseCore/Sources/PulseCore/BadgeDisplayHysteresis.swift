import Foundation

// 菜单栏徽标显示迟滞(badge-hysteresis/01):读数快照 → 显示快照的幅值死区状态机。
// 纯值、无 OS 依赖;app 侧的显示快照模型每轮喂入,输出与当前显示相等就不发布——
// 显示值不翻,SwiftUI 属性图不重评估、位图缓存键不换,这就是 resident-cost/01
// 结项具名的"runloop 提交期翻搅"残差的治理杠杆。
// 口径见 GLOSSARY「显示迟滞」;三项参数为维护者 2026-10-21 triage 当场拍板:
// ±2pp 对称死区、CPU / RAM / 磁盘三槽同阈值、网络速率槽直通。改参数须再过拍板门。

/// 逐槽判定,变化槽采纳本轮**原始读数**,不变槽保留**已显示的原始读数**——显示快照
/// 里存的始终是某一轮的真实读数,composer 照旧折算,渲染层对迟滞无感。
public enum BadgeDisplayHysteresis {
    /// CPU 变红阈值:徽标域的唯一出处(MenuBarBadgeComposer 引用同一常量;
    /// 与 SystemMonitor.redThreshold 的漂移由 MenuBarBadgeTests 的 @MainActor 断言拦截)。
    /// 强调级越权需要它:显示值仍在死区内、但原始值已跨红线,必须立即换。
    public static let cpuRedThreshold: Double = 70

    /// 死区阈值(百分点):新读数取整与已显示整数之差 ≥ 该值才换数字。锚在显示值而
    /// 非上一轮原始值,显示误差上限恒为该值,不会随轮数累积。
    public static let deadbandPoints = 2

    public static func update(displayed: MenuBarBadgeData, incoming: MenuBarBadgeData) -> MenuBarBadgeData {
        let disk = diskSlot(
            displayed: (displayed.diskAvailableBytes, displayed.diskTotalBytes),
            incoming: (incoming.diskAvailableBytes, incoming.diskTotalBytes)
        )
        return MenuBarBadgeData(
            cpuLoadPercent: cpuSlot(displayed: displayed.cpuLoadPercent, incoming: incoming.cpuLoadPercent),
            memory: memorySlot(displayed: displayed.memory, incoming: incoming.memory),
            diskAvailableBytes: disk.available,
            diskTotalBytes: disk.total,
            // 网络速率槽直通:数字逐轮刷新是功能(拍板排除)。
            networkRate: incoming.networkRate
        )
    }

    // MARK: - 逐槽规则

    /// CPU:占位切换立即;红线两侧切换立即(强调级跟原始值);否则百分比死区。
    static func cpuSlot(displayed: Double?, incoming: Double?) -> Double? {
        guard let displayed, let incoming else { return incoming }
        if (displayed > cpuRedThreshold) != (incoming > cpuRedThreshold) {
            return incoming
        }
        return withinDeadband(displayed, incoming) ? displayed : incoming
    }

    /// RAM:占位切换立即;压力等级(橙 / 红)变化立即;否则已用占比死区。
    static func memorySlot(displayed: MemoryBreakdown?, incoming: MemoryBreakdown?) -> MemoryBreakdown? {
        guard let displayed, let incoming else { return incoming }
        if displayed.pressure != incoming.pressure {
            return incoming
        }
        return withinDeadband(usedPercent(displayed), usedPercent(incoming)) ? displayed : incoming
    }

    /// 磁盘剩余:两字节数作一个槽原子采纳。可显示性(两读数齐且总量 > 0)切换立即;
    /// 两边都可显示则剩余占比死区;两边都不可显示直接跟原始值(显示同为占位)。
    static func diskSlot(
        displayed: (available: Int64?, total: UInt64?),
        incoming: (available: Int64?, total: UInt64?)
    ) -> (available: Int64?, total: UInt64?) {
        guard let displayedPercent = remainingPercent(displayed),
              let incomingPercent = remainingPercent(incoming)
        else { return incoming }
        return withinDeadband(displayedPercent, incomingPercent) ? displayed : incoming
    }

    // MARK: - 折算(与 MenuBarBadgeComposer / PulseFormat 同一口径)

    /// 显示整数:四舍五入,与 `PulseFormat.cpuPercentNumber` 同源——死区比的是用户
    /// 看到的数字,不是原始小数。
    static func displayInteger(_ percent: Double) -> Int {
        Int(percent.rounded())
    }

    static func withinDeadband(_ displayed: Double, _ incoming: Double) -> Bool {
        abs(displayInteger(incoming) - displayInteger(displayed)) < deadbandPoints
    }

    static func usedPercent(_ memory: MemoryBreakdown) -> Double {
        guard memory.totalBytes > 0 else { return 0 }
        return Double(memory.usedBytes) / Double(memory.totalBytes) * 100
    }

    static func remainingPercent(_ slot: (available: Int64?, total: UInt64?)) -> Double? {
        guard let available = slot.available, let total = slot.total, total > 0 else { return nil }
        return Double(max(0, available)) / Double(total) * 100
    }
}
