import Foundation

// MARK: - 采样历史(工单 P0.6-01)

/// 内存版近期采样窗口(spec 实现决策):不落盘、重启即失,只回答
/// "最近 ~60 个采样轮"的走势与统计。系统负载 + 每组 CPU%/内存三条口径
/// 各一条环形序列,avg/peak/min 按需折叠——纯值类型 + Sendable,
/// 由 SystemMonitor 每轮 apply() 推进,单测见 SampleHistoryTests。

/// 环形序列可承载的数值:可比较(峰值/谷值)、可折算 Double(均值)。
/// 组 CPU% 用 Double,组内存用 UInt64(字节,GB 级在 Double 整数精度内无损)。
protocol HistoryValue: Comparable, Sendable {
    var asDouble: Double { get }
    static var zeroValue: Self { get }
}

extension Double: HistoryValue {
    var asDouble: Double { self }
    static var zeroValue: Double { 0 }
}

extension UInt64: HistoryValue {
    var asDouble: Double { Double(self) }
    static var zeroValue: UInt64 { 0 }
}

/// 单条序列的窗口统计(avg/peak/min 按需折叠的结果)。
/// 数值统一折算 Double:显示层用 PulseFormat 格式化,口径与原始序列一致。
struct SeriesStatistics: Equatable, Sendable {
    /// 窗口内样本数(折叠口径 = 当前窗口,滚出的旧值不计)。
    let count: Int
    let average: Double
    let peak: Double
    let minimum: Double
}

/// 固定容量环形序列:append 覆盖最旧值,`values` 按时间序(旧 → 新)读回。
/// 统计(均值/峰值/谷值)只在窗口上折叠,空序列返回 nil(不伪造 0)。
struct RingSeries<Value: HistoryValue>: Equatable, Sendable {
    /// 预分配存储,长度恒等于容量(append 只写不增)。
    private var storage: [Value]
    /// 下一个写入位;满环时它同时也是最旧值所在。
    private var head = 0
    /// 历史累计写入数(count = min(written, capacity))。
    private var written = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "环形序列容量必须为正")
        self.capacity = capacity
        self.storage = Array(repeating: Value.zeroValue, count: capacity)
    }

    /// 窗口内样本数。
    var count: Int { min(written, capacity) }

    /// 时间序快照(旧 → 新)。容量级(≤60)拷贝,弹窗每轮一次,开销可忽略。
    var values: [Value] {
        let n = count
        guard n > 0 else { return [] }
        if n < capacity {
            // 未满环:写入位即样本数,最旧在 0。
            return Array(storage[0..<n])
        }
        // 满环:最旧在 head,跨尾回绕拼两段。
        return Array(storage[head...]) + Array(storage[..<head])
    }

    /// 追加一个采样值;满环时覆盖最旧。
    mutating func append(_ value: Value) {
        storage[head] = value
        head = (head + 1) % capacity
        written += 1
    }

    /// 窗口统计(均值/峰值/谷值/样本数);空序列返回 nil。
    var statistics: SeriesStatistics? {
        let window = values
        guard let first = window.first else { return nil }
        var sum = 0.0
        var peak = first.asDouble
        var minimum = first.asDouble
        for value in window {
            let v = value.asDouble
            sum += v
            peak = max(peak, v)
            minimum = min(minimum, v)
        }
        return SeriesStatistics(
            count: window.count,
            average: sum / Double(window.count),
            peak: peak,
            minimum: minimum
        )
    }
}

/// 一轮采样中单个组的采样值(组 id + 组 CPU% + 组内存)。
/// 输入即 ProcessGroup 的聚合口径,历史层不做二次归组。
struct GroupSample: Equatable, Sendable {
    let id: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

/// 单个组的两条历史序列(CPU% 与内存)。
struct GroupSeries: Equatable, Sendable {
    var cpuPercent: RingSeries<Double>
    var memoryBytes: RingSeries<UInt64>

    init(capacity: Int) {
        self.cpuPercent = RingSeries<Double>(capacity: capacity)
        self.memoryBytes = RingSeries<UInt64>(capacity: capacity)
    }
}

/// 采样历史仓库:系统 CPU 负载一条序列 + 每组一条 `GroupSeries`。
/// 每轮采样 `advance` 一次;**本轮缺席的组停止追加并逐出**
/// (组消失 = 组内进程全部退场,同 id 回归视为新 incarnation 从头累计)——
/// 字典不随历史组无限增长。
struct SampleHistoryStore: Equatable, Sendable {
    /// 默认窗口:~60 点(5s 节奏 = 5 分钟 / 弹窗打开 1s = 1 分钟)。
    static let defaultCapacity = 60

    let capacity: Int
    private(set) var systemCPULoad: RingSeries<Double>
    /// 系统内存已用(工单 P0.6-05 总览内存卡 strip / 内存 tab 面积图)。
    private(set) var memoryUsed: RingSeries<UInt64>
    private(set) var groups: [String: GroupSeries] = [:]

    init(capacity: Int = SampleHistoryStore.defaultCapacity) {
        precondition(capacity > 0, "历史窗口容量必须为正")
        self.capacity = capacity
        self.systemCPULoad = RingSeries<Double>(capacity: capacity)
        self.memoryUsed = RingSeries<UInt64>(capacity: capacity)
    }

    /// 读取某组的历史序列;组已被逐出(或从未出现)返回 nil。
    func series(forGroup id: String) -> GroupSeries? {
        groups[id]
    }

    /// 一轮采样的推进:系统负载追加一点,在场的组各追加 CPU%/内存一点,
    /// 缺席的组逐出。同轮重复 id 以最后一条为准(归组引擎保证组 id 唯一,
    /// 此处只是防御性口径)。内存已用缺读数(nil)的轮次不追加,不伪造 0。
    mutating func advance(
        systemCPULoad load: Double,
        memoryUsedBytes: UInt64? = nil,
        groups present: [GroupSample]
    ) {
        self.systemCPULoad.append(load)
        if let memoryUsedBytes {
            memoryUsed.append(memoryUsedBytes)
        }

        var presentByID = [String: GroupSample]()
        for sample in present {
            presentByID[sample.id] = sample
        }
        for (id, sample) in presentByID {
            var series = groups[id] ?? GroupSeries(capacity: capacity)
            series.cpuPercent.append(sample.cpuPercent)
            series.memoryBytes.append(sample.memoryBytes)
            groups[id] = series
        }
        for id in groups.keys where presentByID[id] == nil {
            groups.removeValue(forKey: id)
        }
    }
}
