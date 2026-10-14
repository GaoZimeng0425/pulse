import Foundation

/// 进程 CPU 差分结果(GLOSSARY:差分口径):存活进程的 CPU%。
/// 采样节奏上每相邻两张快照产出一个;是组 CPU% 与进程行 CPU% 的来源。
/// 系统 CPU 负载不在此(评审 S6):进程累加口径结构性少计 kernel_task 与
/// root 属主时间,系统总数改由每核 tick 差分(CoreTickDiffer)承担。
struct CPUDiffResult: Equatable, Sendable {
    /// 与 current 快照同 takenAt,即差分结果的时间戳。
    let takenAt: Date
    /// current 快照中每个进程的 CPU%;顺序与 current.processes 一致。
    let processCPU: [ProcessCPU]
}

/// 单进程 CPU%(单核 100% 口径,可超 100)。
struct ProcessCPU: Equatable, Sendable {
    let pid: pid_t
    /// nil = 该进程在上一张快照里不存在(新出生),尚无 CPU%——显式区分,不伪造 0。
    let cpuPercent: Double?
}

extension Sequence where Element == ProcessCPU {
    /// 差分条目 → pid → CPU% 映射(评审 T4,共享构建):新出生(nil)与缺条目
    /// 一律按 0 计——组聚合与下钻行同口径,此前两处各写一份。
    var cpuPercentByPID: [pid_t: Double] {
        var map: [pid_t: Double] = [:]
        map.reserveCapacity(underestimatedCount)
        for entry in self {
            map[entry.pid] = entry.cpuPercent ?? 0
        }
        return map
    }
}

/// CPU 差分器(纯逻辑):相邻两次快照的累计 CPU 时间差 ÷ 墙钟 = 进程 CPU%,
/// 与活动监视器同算法(spec 实现决策)。只负责逐进程归因口径;
/// 系统总数的每核 tick 口径见 CoreTickDiffer(评审 S6)。
///
/// 口径与退化规则:
/// - 100% = 一个核跑满;多核并行可超 100(如 445%)。
/// - 两次采样间消失的进程按存活交集自然排除;
///   新出现的进程无前值,`cpuPercent` 记 nil。
/// - 累计计数器回退(任务重建)按 0 差值处理,避免 UInt 下溢崩溃。
/// - 墙钟 ≤ 0(同一时刻的两张快照)无法差分,全部记 nil。
enum CPUDiffer {
    /// 差分相邻快照。`previous` 为 nil 表示首采:全部进程无 CPU%。
    static func diff(
        previous: ProcessSnapshot?,
        current: ProcessSnapshot
    ) -> CPUDiffResult {
        guard let previous else {
            return CPUDiffResult(
                takenAt: current.takenAt,
                processCPU: current.processes.map { ProcessCPU(pid: $0.pid, cpuPercent: nil) }
            )
        }

        let wallNanoseconds = Self.wallNanoseconds(from: previous.takenAt, to: current.takenAt)
        guard wallNanoseconds > 0 else {
            return CPUDiffResult(
                takenAt: current.takenAt,
                processCPU: current.processes.map { ProcessCPU(pid: $0.pid, cpuPercent: nil) }
            )
        }

        var previousCPUByID: [pid_t: UInt64] = [:]
        previousCPUByID.reserveCapacity(previous.processes.count)
        for process in previous.processes {
            previousCPUByID[process.pid] = process.cpuTimeNanoseconds
        }

        var processCPU: [ProcessCPU] = []
        processCPU.reserveCapacity(current.processes.count)
        for process in current.processes {
            guard let before = previousCPUByID[process.pid] else {
                // 新进程:无前值,显式 nil。
                processCPU.append(ProcessCPU(pid: process.pid, cpuPercent: nil))
                continue
            }
            // 计数器回退按 0 差值处理(UInt 下溢会崩溃)。
            let delta = process.cpuTimeNanoseconds >= before
                ? process.cpuTimeNanoseconds - before
                : 0
            let percent = Double(delta) / Double(wallNanoseconds) * 100
            processCPU.append(ProcessCPU(pid: process.pid, cpuPercent: percent))
        }

        return CPUDiffResult(takenAt: current.takenAt, processCPU: processCPU)
    }

    /// 两时刻间隔换算为纳秒;负间隔按 0 处理(调用方按"无法差分"退化)。
    private static func wallNanoseconds(from start: Date, to end: Date) -> UInt64 {
        let interval = end.timeIntervalSince(start)
        guard interval > 0 else { return 0 }
        return UInt64(interval * 1_000_000_000)
    }
}
