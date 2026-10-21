import Darwin
import Foundation

// 模块排行·进程级 rusage 数据层(工单 01;架构审查票 A 高2 采集通道合一):
// 能耗影响与每进程磁盘两本差分账本直接吃心跳快照——LiveProcessSource 每轮本就
// 对每个 pid 读一次 rusage V3(CPU / 唤醒 / 磁盘字节),全进程 rusage 循环全仓库
// 只此一处,不再另起第二趟扫描。账本住 Sampler 心跳循环,满窗才出数(能耗 5s /
// 磁盘 30s,与卡底注脚同口径);可见性门控降级为推进/暂停差分
// (Sampler.setRankingsActive)。系统级磁盘求和回退源经 HeartbeatRusageRelay
// 取同一张心跳快照。差分全部 transition-not-tick:对满窗两端的累计值差分、速率
// 对实际墙钟间隔折算,负差分钳 0。

// MARK: - per-pid rusage 表(差分的输入形状)

/// 单 pid 的 rusage 累计取值(差分的输入)。
public struct ProcessRusageSample: Equatable, Sendable {
    /// CPU 累计(用户 + 系统,纳秒;心跳快照已从 mach tick 换算)。
    public let cpuNanoseconds: UInt64
    /// 唤醒累计(空闲唤醒 + 中断唤醒;Activity Monitor 能耗同款原料)。
    public let wakeups: UInt64
    /// 磁盘读字节累计。
    public let diskBytesRead: UInt64
    /// 磁盘写字节累计。
    public let diskBytesWritten: UInt64

    public init(cpuNanoseconds: UInt64, wakeups: UInt64, diskBytesRead: UInt64, diskBytesWritten: UInt64) {
        self.cpuNanoseconds = cpuNanoseconds
        self.wakeups = wakeups
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
    }
}

/// 一张 per-pid rusage 表 + 采样时刻(墙钟;差分对墙钟)。
public struct ProcessRusageTable: Sendable {
    public let takenAt: Date
    public let samples: [pid_t: ProcessRusageSample]

    public init(takenAt: Date, samples: [pid_t: ProcessRusageSample]) {
        self.takenAt = takenAt
        self.samples = samples
    }
}

public extension ProcessRusageTable {
    /// 心跳快照 → rusage 表:字段与 RawProcess 一一对应;重复 pid 保留首个
    /// (与 ProcessSnapshot.processesByPID 同口径)。计数没读到的 pid 跳过
    /// (不以 0 入表):基线轮缺席 = 下一窗按新面孔记基线,瞬时读失败恢复时
    /// 不会把终身累计当一窗增量。
    init(snapshot: ProcessSnapshot) {
        var samples: [pid_t: ProcessRusageSample] = [:]
        samples.reserveCapacity(snapshot.processes.count)
        for process in snapshot.processes
            where process.countersAvailable && samples[process.pid] == nil {
            samples[process.pid] = ProcessRusageSample(
                cpuNanoseconds: process.cpuTimeNanoseconds,
                wakeups: process.wakeups,
                diskBytesRead: process.diskBytesRead,
                diskBytesWritten: process.diskBytesWritten
            )
        }
        self.init(takenAt: snapshot.takenAt, samples: samples)
    }
}

/// 心跳中继:Sampler 每轮发布最新快照,低频消费方(磁盘求和回退源,30s)
/// 按需取用——共享心跳那一趟 rusage,不另起扫描。发布时刻按单调时钟一并
/// 记下:消费方的计数时刻必须是**采到**的时刻而非读中继的时刻(两者最多差
/// 一个心跳,拿读的时刻折算速率会随相位漂移出锯齿)。锁保护的微小盒子
/// (与 SensorLastGoodBox 同款纪律:跨 Sampler / SensorScheduler 两个并发域)。
public final class HeartbeatRusageRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var published: (snapshot: ProcessSnapshot, uptimeNanos: UInt64)?

    public func publish(
        _ snapshot: ProcessSnapshot,
        atUptimeNanos uptimeNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        defer { lock.unlock() }
        published = (snapshot, uptimeNanos)
    }

    /// 最新一轮快照 + 发布时刻(单调时钟纳秒);心跳首轮前 nil。
    public func latest() -> (snapshot: ProcessSnapshot, uptimeNanos: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    public init() {}
}

// MARK: - 能耗影响排行(工单 01)

/// 单进程能耗影响读数(一窗差分):原始增量 + 复合分,UI 按 impact 排序。
public struct ProcessEnergyImpact: Equatable, Sendable {
    /// 每唤醒折算 CPU 纳秒(50ms)。**约定权重,非实测**:与 Activity Monitor
    /// 同款原料(rusage CPU 时间 + 唤醒),但 AM 未公开公式、各实现自定折算,
    /// 50ms/次取"唤醒打断深度睡眠 ≈ 中等代价"的常见量级——注释在此言明。
    public static let nanosecondsPerWakeup: UInt64 = 50_000_000

    /// 本窗口 CPU 时间增量(纳秒,用户 + 系统)。
    public let cpuNanosDelta: UInt64
    /// 本窗口唤醒增量(次)。
    public let wakeupsDelta: UInt64
    /// 复合分 = CPU 增量 + 唤醒增量 × 每唤醒 50ms。
    public let impact: UInt64

    /// 满窗两端差分:只出两端都在场的 pid(首见 pid 记基线不出数、消失 pid
    /// 丢弃、复现 pid 按新面孔);负差分钳 0(计数回绕 / 重置不吃巨大值)。
    public static func diff(
        from baseline: ProcessRusageTable,
        to current: ProcessRusageTable
    ) -> [pid_t: ProcessEnergyImpact] {
        var impacts: [pid_t: ProcessEnergyImpact] = [:]
        impacts.reserveCapacity(current.samples.count)
        for (pid, sample) in current.samples {
            guard let base = baseline.samples[pid] else { continue }
            let cpuNanosDelta = sample.cpuNanoseconds >= base.cpuNanoseconds
                ? sample.cpuNanoseconds - base.cpuNanoseconds : 0
            let wakeupsDelta = sample.wakeups >= base.wakeups
                ? sample.wakeups - base.wakeups : 0
            impacts[pid] = ProcessEnergyImpact(
                cpuNanosDelta: cpuNanosDelta,
                wakeupsDelta: wakeupsDelta,
                impact: cpuNanosDelta &+ wakeupsDelta &* nanosecondsPerWakeup
            )
        }
        return impacts
    }

    public init(cpuNanosDelta: UInt64, wakeupsDelta: UInt64, impact: UInt64) {
        self.cpuNanosDelta = cpuNanosDelta
        self.wakeupsDelta = wakeupsDelta
        self.impact = impact
    }
}

// MARK: - 磁盘每进程排行(工单 01)

/// 单进程磁盘读写速率(字节/秒;一窗差分对实际墙钟间隔折算)。
public struct ProcessDiskRates: Equatable, Sendable {
    public let readBytesPerSec: Double
    public let writeBytesPerSec: Double

    /// 满窗两端差分(在场 pid 口径同能耗);速率分母是实际间隔而非标称窗长
    /// ——节拍漂移 / 调度抖动不会歪折算;回退钳零。
    public static func diff(
        from baseline: ProcessRusageTable,
        to current: ProcessRusageTable,
        elapsed: TimeInterval
    ) -> [pid_t: ProcessDiskRates] {
        var rates: [pid_t: ProcessDiskRates] = [:]
        rates.reserveCapacity(current.samples.count)
        for (pid, sample) in current.samples {
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
        return rates
    }

    public init(readBytesPerSec: Double, writeBytesPerSec: Double) {
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
    }
}

// MARK: - 满窗账本(住 Sampler 心跳循环)

/// 一轮心跳的排行产出:各窗满窗才出数;nil = 本轮该窗未满(或基线轮)。
public struct ProcessRankingRound: Equatable, Sendable {
    public var energyImpacts: [pid_t: ProcessEnergyImpact]?
    /// 能耗这一窗的实际跨度(秒;与 energyImpacts 同生同灭):心跳在窗中途 1s ↔ 5s
    /// 切换时实际窗 5–9s,唤醒/秒按它折算而非标称窗长。
    public var energyWindowSeconds: TimeInterval?
    public var diskRates: [pid_t: ProcessDiskRates]?

    public static let empty = ProcessRankingRound()

    public init(
        energyImpacts: [pid_t: ProcessEnergyImpact]? = nil,
        energyWindowSeconds: TimeInterval? = nil,
        diskRates: [pid_t: ProcessDiskRates]? = nil
    ) {
        self.energyImpacts = energyImpacts
        self.energyWindowSeconds = energyWindowSeconds
        self.diskRates = diskRates
    }
}

/// 满窗基线(两本账本共用一份推进规则):首趟立基线不出数;未满窗不推进
/// (基线保持,满窗差分跨整窗——1s 心跳下也是 5s 窗,不是最后 1s);满窗交出
/// 基线并以本趟重立。间隔越界则以本趟重立不出数:为负 = 墙钟回拨;超过
/// 上限 = 心跳断档(睡眠后首轮先于唤醒清账通知到达、进程被挂起)——能耗是
/// 窗口绝对增量不按时长归一,跨断档的一窗会把整段累计当 5s 显示。
private struct RusageWindow: Sendable {
    /// 满窗容差:吸收轮距略短于窗长的抖动。远小于最短心跳 1s——1s 心跳下
    /// 仍在第 5 轮满窗;5s 心跳下轮距若因调度改动短了几毫秒也不至于整窗翻倍。
    static let tolerance: TimeInterval = 0.25
    /// 窗长上限倍数:弹窗开合让心跳在窗中途 1s → 5s 切换,单窗最长约 9s,
    /// 3 倍窗长留足余量;超出即视为断档。
    static let maximumSpan: Double = 3

    let seconds: TimeInterval
    private var baseline: ProcessRusageTable?

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    /// 推进一趟;满窗返回 (基线, 实际间隔),否则 nil。表惰性取用:未满窗
    /// 的轮不建表(1s 心跳下五轮只建一次)。
    mutating func advance(
        at time: Date,
        table: () -> ProcessRusageTable
    ) -> (baseline: ProcessRusageTable, elapsed: TimeInterval)? {
        guard let baseline else {
            baseline = table()
            return nil
        }
        let elapsed = time.timeIntervalSince(baseline.takenAt)
        guard elapsed >= 0, elapsed <= seconds * Self.maximumSpan else {
            self.baseline = table()
            return nil
        }
        guard elapsed >= seconds - Self.tolerance else { return nil }
        self.baseline = table()
        return (baseline, elapsed)
    }

    mutating func reset() {
        baseline = nil
    }
}

/// 模块排行两本差分账本(值类型状态机,Sampler 持有并逐轮喂心跳快照):
/// 能耗影响 5s 窗、磁盘每进程 30s 窗,两窗各自独立推进。
public struct ProcessRankingLedgers: Sendable {
    /// 能耗影响窗(工单 module-rankings/01 节奏契约;卡底"5 秒一档"同源)。唤醒/秒
    /// 的折算分母是每窗实际跨度(ProcessRankingRound.energyWindowSeconds)。
    public static let energyWindow: TimeInterval = 5
    /// 磁盘每进程窗(卡底"30 秒一档")。
    public static let diskWindow: TimeInterval = 30

    private var energy = RusageWindow(seconds: Self.energyWindow)
    private var disk = RusageWindow(seconds: Self.diskWindow)

    /// 喂一轮心跳快照,返回本轮满窗的读数。
    public mutating func record(_ snapshot: ProcessSnapshot) -> ProcessRankingRound {
        var built: ProcessRusageTable?
        let table = {
            if let built {
                return built
            }
            let fresh = ProcessRusageTable(snapshot: snapshot)
            built = fresh
            return fresh
        }
        var round = ProcessRankingRound.empty
        if let closed = energy.advance(at: snapshot.takenAt, table: table) {
            round.energyImpacts = ProcessEnergyImpact.diff(from: closed.baseline, to: table())
            round.energyWindowSeconds = closed.elapsed
        }
        if let closed = disk.advance(at: snapshot.takenAt, table: table) {
            round.diskRates = ProcessDiskRates.diff(
                from: closed.baseline, to: table(), elapsed: closed.elapsed
            )
        }
        return round
    }

    /// 清账(门关 / 唤醒):下一轮重新记基线,不出横跨隐藏期或睡眠的巨差。
    public mutating func reset() {
        energy.reset()
        disk.reset()
    }

    public init() {}
}
