import Darwin
import Foundation

// 模块排行·进程级 rusage 数据层(工单 01):能耗影响与每进程磁盘两个排行
// 共用一趟全进程 proc_pid_rusage——一次调用同时给出 CPU tick、唤醒计数、
// 磁盘字节,没必要让两个源各养一趟全进程循环(系统级磁盘求和回退源
// RusageSumDiskThroughputSource 也消费这里的表)。OS 边界薄协议缝(ADR-0004
// 同款),测试接合成表注入;差分全部 transition-not-tick:对相邻两趟的累计值
// 差分、速率对两趟墙钟间隔折算,负差分钳 0。

// MARK: - 一趟全进程 rusage 采样表

/// 单 pid 的 rusage 累计取值(差分的输入)。
struct ProcessRusageSample: Equatable, Sendable {
    /// CPU 累计(用户 + 系统,纳秒)。rusage 的 ri_user_time/ri_system_time
    /// 是 mach tick 不是纳秒,换算复用 LiveProcessSource.nanoseconds(fromTicks:),
    /// 表里只放换算后的纳秒——差分层不碰 tick 口径。
    let cpuNanoseconds: UInt64
    /// 唤醒累计(空闲唤醒 + 中断唤醒;Activity Monitor 能耗同款原料)。
    let wakeups: UInt64
    /// 磁盘读字节累计。
    let diskBytesRead: UInt64
    /// 磁盘写字节累计。
    let diskBytesWritten: UInt64
}

/// 一趟全进程 rusage 的采样表 + 采样时刻(墙钟;差分对墙钟)。
struct ProcessRusageTable: Sendable {
    let takenAt: Date
    let samples: [pid_t: ProcessRusageSample]
}

/// 薄源协议(ADR-0004):读一趟全进程 rusage 表。nil = 进程列表本身读不到
/// (灾难级失败);单 pid 读失败(受限 / 采样间隙退出,proc_pid_rusage 返回
/// -1 + EINVAL)在实现内跳过该 pid,不中断整趟。
protocol ProcessRusageTableSource: Sendable {
    func readTable() -> ProcessRusageTable?
}

/// Live 源:proc_listallpids 全列一遍 + 每 pid 一次 proc_pid_rusage。
/// 全仓库唯一的全进程 rusage 循环;指针重绑写法沿用探针验证的旧
/// RusageSumDiskThroughputSource 实现(DiskSensor.swift 同款)。
final class LiveProcessRusageTableSource: ProcessRusageTableSource, @unchecked Sendable {
    func readTable() -> ProcessRusageTable? {
        let pids = LiveProcessSource.listPIDs()
        guard !pids.isEmpty else { return nil }
        var samples: [pid_t: ProcessRusageSample] = [:]
        samples.reserveCapacity(pids.count)
        for pid in pids {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            // 受限 pid / 刚退出:-1 + EINVAL,跳过不中断(工单口径)。
            guard result != -1 else { continue }
            samples[pid] = ProcessRusageSample(
                cpuNanoseconds: LiveProcessSource.nanoseconds(
                    fromTicks: usage.ri_user_time &+ usage.ri_system_time
                ),
                wakeups: usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups,
                diskBytesRead: usage.ri_diskio_bytesread,
                diskBytesWritten: usage.ri_diskio_byteswritten
            )
        }
        return ProcessRusageTable(takenAt: Date(), samples: samples)
    }
}

// MARK: - 能耗影响排行(工单 01)

/// 单进程能耗影响读数(一轮差分):原始增量 + 复合分,UI 按 impact 排序。
struct ProcessEnergyImpact: Equatable, Sendable {
    /// 本窗口 CPU 时间增量(纳秒,用户 + 系统)。
    let cpuNanosDelta: UInt64
    /// 本窗口唤醒增量(次)。
    let wakeupsDelta: UInt64
    /// 复合分 = CPU 增量 + 唤醒增量 × 每唤醒 50ms(权重见 Accumulator 注释)。
    let impact: UInt64
}

/// 能耗影响差分账本(锁保护的微小盒子,与 DiskThroughputAccumulator 同款纪律):
/// 首见 pid(整表首趟 / 新 pid / 消失后复现的 pid)记基线不出数;消失 pid 丢弃
/// (基线整表以本轮为准);负差分钳 0(计数回绕 / 重置不吃巨大值)。
final class ProcessEnergyImpactAccumulator: @unchecked Sendable {
    /// 每唤醒折算 CPU 纳秒(50ms)。**约定权重,非实测**:与 Activity Monitor
    /// 同款原料(rusage CPU 时间 + 唤醒),但 AM 未公开公式、各实现自定折算,
    /// 50ms/次取"唤醒打断深度睡眠 ≈ 中等代价"的常见量级——注释在此言明。
    static let nanosecondsPerWakeup: UInt64 = 50_000_000

    private let lock = NSLock()
    private var previous: ProcessRusageTable?

    /// 折叠一轮差分;nil = 基线轮(整表首趟,本轮不出数)。
    func record(_ table: ProcessRusageTable) -> [pid_t: ProcessEnergyImpact]? {
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = previous else {
            previous = table
            return nil
        }
        var impacts: [pid_t: ProcessEnergyImpact] = [:]
        impacts.reserveCapacity(table.samples.count)
        for (pid, sample) in table.samples {
            guard let base = baseline.samples[pid] else { continue }
            let cpuNanosDelta = sample.cpuNanoseconds >= base.cpuNanoseconds
                ? sample.cpuNanoseconds - base.cpuNanoseconds : 0
            let wakeupsDelta = sample.wakeups >= base.wakeups
                ? sample.wakeups - base.wakeups : 0
            impacts[pid] = ProcessEnergyImpact(
                cpuNanosDelta: cpuNanosDelta,
                wakeupsDelta: wakeupsDelta,
                impact: cpuNanosDelta &+ wakeupsDelta &* Self.nanosecondsPerWakeup
            )
        }
        previous = table
        return impacts
    }

    /// 隐藏即清账:重开首轮重新记基线,不出横跨隐藏期的巨差。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        previous = nil
    }
}

/// 能耗影响 provider(工单 01,ADR-0004):低频档 5s,**仅窗口可见时跑**
/// (全进程 rusage 一趟,门控关掉即零成本);差分状态由 accumulator 持有,
/// 读失败交付 lastGood 不白屏。
final class ProcessEnergyImpactProvider: SensorProvider {
    typealias Reading = [pid_t: ProcessEnergyImpact]

    let cadence: SensorCadence = .every(seconds: 5)

    private let source: any ProcessRusageTableSource
    private let gate = SensorVisibilityGate()
    private let accumulator = ProcessEnergyImpactAccumulator()
    private let slot = SensorLastGoodBox<Reading>()

    var lastGood: Reading? { slot.current }

    init(source: any ProcessRusageTableSource = LiveProcessRusageTableSource()) {
        self.source = source
    }

    /// 可见性切换(合并门控由 SystemMonitor 折算后下发):翻转为关时清差分
    /// 账本——隐藏期计数照旧累计,不清账会在重开首轮出横跨隐藏期的巨差。
    func setVisible(_ visible: Bool) {
        if gate.setVisible(visible), !visible { accumulator.reset() }
    }

    func snapshot() async -> Reading? {
        guard gate.isVisible else { return nil } // 没窗口在看:门口空转,零成本
        guard let table = source.readTable() else { return nil }
        guard let reading = accumulator.record(table) else { return nil } // 基线轮
        slot.store(reading)
        return reading
    }
}

// MARK: - 磁盘每进程排行(工单 01)

/// 单进程磁盘读写速率(字节/秒;一轮差分对两趟墙钟间隔折算)。
struct ProcessDiskRates: Equatable, Sendable {
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
}

/// 磁盘每进程差分账本(锁保护的微小盒子):首见 pid 记基线不出数、消失 pid
/// 丢弃、负差分钳 0——与能耗影响同三件防护;速率防服装置沿用
/// DiskThroughputDiffer(首读置零 / elapsed 非正钳零 / 回退钳零)。
final class ProcessDiskRateAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: ProcessRusageTable?

    /// 折叠一轮差分;nil = 基线轮或病态轮(墙钟未前进)。
    func record(_ table: ProcessRusageTable) -> [pid_t: ProcessDiskRates]? {
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = previous else {
            previous = table
            return nil
        }
        // transition-not-tick:速率分母是两趟的实际墙钟间隔,不是标称节拍——
        // 节拍漂移 / 调度抖动不会歪折算;间隔未前进(病态时钟)整轮钳零。
        let elapsed = table.takenAt.timeIntervalSince(baseline.takenAt)
        guard elapsed > 0 else {
            previous = table
            return nil
        }
        var rates: [pid_t: ProcessDiskRates] = [:]
        rates.reserveCapacity(table.samples.count)
        for (pid, sample) in table.samples {
            guard let base = baseline.samples[pid] else { continue }
            let read = sample.diskBytesRead >= base.diskBytesRead
                ? sample.diskBytesRead - base.diskBytesRead : 0
            let write = sample.diskBytesWritten >= base.diskBytesWritten
                ? sample.diskBytesWritten - base.diskBytesWritten : 0
            rates[pid] = ProcessDiskRates(
                readBytesPerSec: Double(read) / elapsed,
                writeBytesPerSec: Double(write) / elapsed
            )
        }
        previous = table
        return rates
    }

    /// 隐藏即清账(同能耗影响)。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        previous = nil
    }
}

/// 磁盘每进程 provider(工单 01,ADR-0004):低频档 30s,仅窗口可见时跑;
/// 消费与能耗影响同一个 ProcessRusageTableSource 缝(各持差分账本,互不干扰)。
final class ProcessDiskRateProvider: SensorProvider {
    typealias Reading = [pid_t: ProcessDiskRates]

    let cadence: SensorCadence = .every(seconds: 30)

    private let source: any ProcessRusageTableSource
    private let gate = SensorVisibilityGate()
    private let accumulator = ProcessDiskRateAccumulator()
    private let slot = SensorLastGoodBox<Reading>()

    var lastGood: Reading? { slot.current }

    init(source: any ProcessRusageTableSource = LiveProcessRusageTableSource()) {
        self.source = source
    }

    /// 可见性切换(同能耗影响)。
    func setVisible(_ visible: Bool) {
        if gate.setVisible(visible), !visible { accumulator.reset() }
    }

    func snapshot() async -> Reading? {
        guard gate.isVisible else { return nil }
        guard let table = source.readTable() else { return nil }
        guard let reading = accumulator.record(table) else { return nil }
        slot.store(reading)
        return reading
    }
}
