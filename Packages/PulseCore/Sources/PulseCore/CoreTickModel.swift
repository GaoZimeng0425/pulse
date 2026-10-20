import Foundation

// 每核 tick 的纯值层:样本 / 负载拆分 / 差分器与源接缝。host_processor_info 适配器在 app target(CoreTickDiffer.swift)。

/// 一次每核 tick 计数样本:`host_processor_info(HOST_CPU_LOAD_INFO)` 的读数。
/// 系统 CPU 负载 = 相邻两样本的忙 tick 差 ÷ 总 tick 差(总含 idle)——
/// 与活动监视器 / Stats 同源:kernel_task 与 root 属主进程的 CPU 时间
/// (非 root 的 PROC_PIDTASKINFO 看不见的部分)也计入,
/// 修复"Stats 显示 100%、Pulse 只显示 80%"的结构性少计。
public struct CoreTickSample: Equatable, Sendable {
    /// 每核的忙 tick(user + system + nice;即总 tick 去掉 idle)。
    public let busyTicks: [UInt64]
    /// 每核的全部 tick(user + system + idle + nice)。
    public let totalTicks: [UInt64]
    /// 采样时刻(诊断用;差分本身自归一——总 tick 已含 idle,无需墙钟)。
    public let takenAt: Date
    /// 每核的用户态 tick(user + nice,工单 P0.6-05 总览 CPU 卡"用户"列);
    /// 空 = 该样本不带拆分(旧口径 / 合成源),拆分退化为 0。
    public var userTicks: [UInt64] = []
    /// 每核的内核态 tick(system,总览 CPU 卡"系统"列)。
    public var systemTicks: [UInt64] = []

    public init(
        busyTicks: [UInt64],
        totalTicks: [UInt64],
        takenAt: Date,
        userTicks: [UInt64] = [],
        systemTicks: [UInt64] = []
    ) {
        self.busyTicks = busyTicks
        self.totalTicks = totalTicks
        self.takenAt = takenAt
        self.userTicks = userTicks
        self.systemTicks = systemTicks
    }
}

/// 系统 CPU 负载及其用户/系统拆分(工单 P0.6-05),均为 0–100%、
/// 占全部 tick 的比例——user + system ≈ total(nice 计入用户)。
public struct CPULoadBreakdown: Equatable, Sendable {
    public let total: Double
    public let user: Double
    public let system: Double

    public static let zero = CPULoadBreakdown(total: 0, user: 0, system: 0)

    public init(total: Double, user: Double, system: Double) {
        self.total = total
        self.user = user
        self.system = system
    }
}

/// 每核 tick 差分器(纯逻辑,评审 S6):相邻两样本 → 系统 CPU 负载 0–100%。
///
/// 口径与退化规则:
/// - 负载 = Σ忙 tick 差 ÷ Σ总 tick 差 × 100,tick 自带时间基准,不依赖墙钟;
/// - 首样本(无前值)/ 总 tick 差为 0(两次读数相同,如同一时刻)→ 0;
/// - 单核计数器回退(异常)按 0 差值处理,避免 UInt 下溢崩溃;
/// - 核数变化(极罕见)按两侧较短的核前缀对齐,多余核忽略——保守可用。
/// 只负责系统总数;进程 / 组 CPU% 仍走 PROC_PIDTASKINFO 差分(CPUDiffer)。
public enum CoreTickDiffer {
    public static func systemCPULoad(previous: CoreTickSample?, current: CoreTickSample) -> Double {
        guard let previous else { return 0 }
        let coreCount = min(
            previous.busyTicks.count, previous.totalTicks.count,
            current.busyTicks.count, current.totalTicks.count
        )
        var busyDelta: UInt64 = 0
        var totalDelta: UInt64 = 0
        for core in 0..<coreCount {
            let busy = Self.clampedDelta(
                previous: previous.busyTicks[core], current: current.busyTicks[core]
            )
            let total = Self.clampedDelta(
                previous: previous.totalTicks[core], current: current.totalTicks[core]
            )
            busyDelta += busy
            totalDelta += total
        }
        guard totalDelta > 0 else { return 0 }
        return min(100, Double(busyDelta) / Double(totalDelta) * 100)
    }

    /// 负载 + 用户/系统拆分(工单 P0.6-05):合计与 `systemCPULoad` 同一口径;
    /// 拆分 = 用户/系统 tick 差 ÷ 同一总 tick 差。任一侧样本不带拆分 → 拆分为 0。
    public static func breakdown(previous: CoreTickSample?, current: CoreTickSample) -> CPULoadBreakdown {
        guard let previous else { return .zero }
        let total = systemCPULoad(previous: previous, current: current)
        let coreCount = min(previous.totalTicks.count, current.totalTicks.count)
        let hasSplit = [previous.userTicks, previous.systemTicks, current.userTicks, current.systemTicks]
            .allSatisfy { $0.count >= coreCount }
        guard hasSplit, coreCount > 0 else {
            return CPULoadBreakdown(total: total, user: 0, system: 0)
        }
        var totalDelta: UInt64 = 0
        var userDelta: UInt64 = 0
        var systemDelta: UInt64 = 0
        for core in 0..<coreCount {
            totalDelta += clampedDelta(previous: previous.totalTicks[core], current: current.totalTicks[core])
            userDelta += clampedDelta(previous: previous.userTicks[core], current: current.userTicks[core])
            systemDelta += clampedDelta(previous: previous.systemTicks[core], current: current.systemTicks[core])
        }
        guard totalDelta > 0 else { return CPULoadBreakdown(total: total, user: 0, system: 0) }
        return CPULoadBreakdown(
            total: total,
            user: min(100, Double(userDelta) / Double(totalDelta) * 100),
            system: min(100, Double(systemDelta) / Double(totalDelta) * 100)
        )
    }

    /// 计数器回退(如 host 重启计数)按 0 差值处理(UInt 下溢会崩溃)。
    private static func clampedDelta(previous: UInt64, current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

/// 每核 tick 采集接缝:OS 边界,协议之上纯逻辑(评审 S6)。
/// 单测注入合成源(SyntheticCoreTickSource);真实现 `LiveCoreTickSource`。
public protocol CoreTickSource: Sendable {
    /// 读一次每核 tick 计数。永不抛错:读失败降级为空样本(负载按 0 计)。
    func sample() -> CoreTickSample
}

/// 合成每核 tick 源:按调用顺序吐出注入样本,耗尽后停在末样本(稳定世界)。
/// 线程安全,可跨并发域持有;与 SyntheticProcessSource 同一测试口径。
public final class SyntheticCoreTickSource: CoreTickSource, @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [CoreTickSample]
    private var nextIndex = 0

    public init(samples: [CoreTickSample]) {
        precondition(!samples.isEmpty, "SyntheticCoreTickSource 需要至少一个样本")
        self.samples = samples
    }

    public func sample() -> CoreTickSample {
        lock.lock()
        defer { lock.unlock() }
        let current = samples[min(nextIndex, samples.count - 1)]
        nextIndex += 1
        return current
    }
}
