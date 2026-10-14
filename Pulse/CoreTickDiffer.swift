import Foundation
import Darwin

// MARK: - 每核 tick 统计(评审 S6:系统 CPU 负载的口径修正)

/// 一次每核 tick 计数样本:`host_processor_info(HOST_CPU_LOAD_INFO)` 的读数。
/// 系统 CPU 负载 = 相邻两样本的忙 tick 差 ÷ 总 tick 差(总含 idle)——
/// 与活动监视器 / Stats 同源:kernel_task 与 root 属主进程的 CPU 时间
/// (非 root 的 PROC_PIDTASKINFO 看不见的部分)也计入,
/// 修复"Stats 显示 100%、Pulse 只显示 80%"的结构性少计。
struct CoreTickSample: Equatable, Sendable {
    /// 每核的忙 tick(user + system + nice;即总 tick 去掉 idle)。
    let busyTicks: [UInt64]
    /// 每核的全部 tick(user + system + idle + nice)。
    let totalTicks: [UInt64]
    /// 采样时刻(诊断用;差分本身自归一——总 tick 已含 idle,无需墙钟)。
    let takenAt: Date
}

/// 每核 tick 差分器(纯逻辑,评审 S6):相邻两样本 → 系统 CPU 负载 0–100%。
///
/// 口径与退化规则:
/// - 负载 = Σ忙 tick 差 ÷ Σ总 tick 差 × 100,tick 自带时间基准,不依赖墙钟;
/// - 首样本(无前值)/ 总 tick 差为 0(两次读数相同,如同一时刻)→ 0;
/// - 单核计数器回退(异常)按 0 差值处理,避免 UInt 下溢崩溃;
/// - 核数变化(极罕见)按两侧较短的核前缀对齐,多余核忽略——保守可用。
/// 只负责系统总数;进程 / 组 CPU% 仍走 PROC_PIDTASKINFO 差分(CPUDiffer)。
enum CoreTickDiffer {
    static func systemCPULoad(previous: CoreTickSample?, current: CoreTickSample) -> Double {
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

    /// 计数器回退(如 host 重启计数)按 0 差值处理(UInt 下溢会崩溃)。
    private static func clampedDelta(previous: UInt64, current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

// MARK: - 采集源

/// 每核 tick 采集接缝:OS 边界,协议之上纯逻辑(评审 S6)。
/// 单测注入合成源(SyntheticCoreTickSource);真实现 `LiveCoreTickSource`。
protocol CoreTickSource: Sendable {
    /// 读一次每核 tick 计数。永不抛错:读失败降级为空样本(负载按 0 计)。
    func sample() -> CoreTickSample
}

/// Darwin 薄适配器:host_processor_info(PROCESSOR_CPU_LOAD_INFO)——每核
/// [user, system, idle, nice] 计数,与活动监视器 / top 的系统占用同源。
/// (注意 flavor 是 processor 侧的 PROCESSOR_CPU_LOAD_INFO;
/// HOST_CPU_LOAD_INFO 是 host_statistics 的 flavor,用在这里会得到参数错。)
/// 返回缓冲由 vm_allocate 分配,读完必须 vm_deallocate 归还。
struct LiveCoreTickSource: CoreTickSource {
    func sample() -> CoreTickSample {
        var coreCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &infoPointer,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let info = infoPointer, coreCount > 0 else {
            return CoreTickSample(busyTicks: [], totalTicks: [], takenAt: Date())
        }
        defer {
            // host_processor_info 分配的内存不归 ARC 管,手工归还。
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        var busy: [UInt64] = []
        var total: [UInt64] = []
        busy.reserveCapacity(Int(coreCount))
        total.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * statesPerCore
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            busy.append(user + system + nice)
            total.append(user + system + idle + nice)
        }
        return CoreTickSample(busyTicks: busy, totalTicks: total, takenAt: Date())
    }
}

/// 合成每核 tick 源:按调用顺序吐出注入样本,耗尽后停在末样本(稳定世界)。
/// 线程安全,可跨并发域持有;与 SyntheticProcessSource 同一测试口径。
final class SyntheticCoreTickSource: CoreTickSource, @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [CoreTickSample]
    private var nextIndex = 0

    init(samples: [CoreTickSample]) {
        precondition(!samples.isEmpty, "SyntheticCoreTickSource 需要至少一个样本")
        self.samples = samples
    }

    func sample() -> CoreTickSample {
        lock.lock()
        defer { lock.unlock() }
        let current = samples[min(nextIndex, samples.count - 1)]
        nextIndex += 1
        return current
    }
}
