import Foundation
import Darwin

// 每进程网络(nettop)的纯值层:表形状、CSV 解析、差分账本、源接缝与健康状态沿。子进程适配器 LiveNettopCSVSource 在 app target。

/// 单进程网络累计字节(一次 nettop 回包的取值;差分输入)。
/// down = 入(bytes_in,接收),up = 出(bytes_out,发送),与 NetworkRates 同方向口径。
public struct NettopProcessBytes: Equatable, Sendable {
    public let downBytes: UInt64
    public let upBytes: UInt64

    public init(downBytes: UInt64, upBytes: UInt64) {
        self.downBytes = downBytes
        self.upBytes = upBytes
    }
}

/// 一趟 nettop 采样表 + 采样时刻(墙钟;差分对墙钟)。
public struct NettopProcessTable: Sendable {
    public let takenAt: Date
    public let bytes: [pid_t: NettopProcessBytes]

    public init(takenAt: Date, bytes: [pid_t: NettopProcessBytes]) {
        self.takenAt = takenAt
        self.bytes = bytes
    }
}

public enum NettopCSVParser {
    /// 解析 nettop -L 1 的 CSV 文本;首行恒为表头,无条件跳过。
    /// 返回表(可能为空 = 无数据行);takenAt 由调用方注入(时钟可测)。
    public static func parse(_ csv: String, takenAt: Date) -> NettopProcessTable {
        var bytes: [pid_t: NettopProcessBytes] = [:]
        var lines = csv.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return NettopProcessTable(takenAt: takenAt, bytes: bytes) }
        lines.removeFirst() // 表头
        for line in lines {
            // 空字段保留:尾随空列是 -k 砍列后的常态,缺列要靠位置数出来。
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue } // 缺列:跳行
            let identity = columns[0].trimmingCharacters(in: .whitespaces)
            // 名称可含点 → pid 取最后一个点之后的段;空段 / 非数字 → 跳行。
            guard let lastDot = identity.lastIndex(of: "."),
                  let pid = pid_t(identity[identity.index(after: lastDot)...])
            else { continue }
            // 字节列:非数字 / 负数(UInt64 拒收负数)→ 跳行,不钳不猜。
            guard let down = UInt64(columns[1].trimmingCharacters(in: .whitespaces)),
                  let up = UInt64(columns[2].trimmingCharacters(in: .whitespaces))
            else { continue }
            // 同 pid 多行(口径外重复):字节累加视作合计,行序无关。
            let existing = bytes[pid]
            bytes[pid] = NettopProcessBytes(
                downBytes: (existing?.downBytes ?? 0) &+ down,
                upBytes: (existing?.upBytes ?? 0) &+ up
            )
        }
        return NettopProcessTable(takenAt: takenAt, bytes: bytes)
    }
}

/// 薄源协议(ADR-0004):跑一次 nettop 拿原始 CSV 文本。nil = 子进程起不来 /
/// 运行失败;空文本 = 无输出(解析为空表)。测试接合成 CSV 注入,不真实起子进程。
public protocol NettopCSVSource: Sendable {
    func read() async -> String?
}

/// 单趟 nettop 的收尾方式(状态沿日志的取值,票 A 中6)。
public enum NettopRunOutcome: Equatable, Sendable {
    /// 超时前自行退出(正常)。
    case completed
    /// 子进程起不来(路径缺失等),附原因。
    case launchFailed(String)
    /// 超时,SIGTERM 收尾。
    case terminated
    /// 超时且宽限期内不响应 SIGTERM,SIGKILL 收尾。
    case killed
    /// 超时前自行退出,但退出码非零或被信号终止(典型:系统更新改掉 -k 列名,
    /// nettop 立即以 64 退出、stdout 为空——不能当正常收尾静默吞掉)。
    case exitedAbnormally(status: Int32)
}

/// 单趟结果:输出文本(nil = 起不来)+ 收尾方式。
public struct NettopRun: Sendable {
    public let text: String?
    public let outcome: NettopRunOutcome

    public init(text: String? = nil, outcome: NettopRunOutcome) {
        self.text = text
        self.outcome = outcome
    }
}

/// nettop 状态沿日志(票 A 中6;transition-not-tick,沿 HistoryHealthEdge
/// 惯例):收尾方式变化才记一条——进入失败记错误、换一种失败再记、恢复记一条,
/// 持续同态静默。5s 一档的子进程若逐趟记失败,会把有用日志挤出留存窗口
/// (LogService 教训③)。纯值状态机,单测钉死。
public struct NettopHealthLog {
    public struct Entry: Equatable {
        public enum Level: Equatable {
            case info
            case error
        }

        public let level: Level
        public let message: String

        public init(level: Level, message: String) {
            self.level = level
            self.message = message
        }
    }

    private var last: NettopRunOutcome = .completed

    /// 登记一趟收尾方式;返回应记的日志(nil = 同态静默)。
    public mutating func transition(to outcome: NettopRunOutcome) -> Entry? {
        guard outcome != last else { return nil }
        let previous = last
        last = outcome
        if outcome == .completed {
            return Entry(level: .info, message: "nettop 恢复正常(上一态:\(Self.describe(previous)))")
        }
        return Entry(level: .error, message: "\(Self.describe(outcome))(此后同态静默,恢复再记)")
    }

    private static func describe(_ outcome: NettopRunOutcome) -> String {
        switch outcome {
        case .completed: "正常"
        case .launchFailed(let reason): "nettop 起不来:\(reason)"
        case .terminated: "nettop 超时,SIGTERM 收尾"
        case .killed: "nettop 超时且不响应 SIGTERM,SIGKILL 收尾"
        case .exitedAbnormally(let status): "nettop 异常退出(状态 \(status))"
        }
    }

    public init() {
    }
}

/// 单进程网络速率(字节/秒;一轮差分对两趟墙钟间隔折算)。
public struct ProcessNetworkRates: Equatable, Sendable {
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double

    public init(downBytesPerSec: Double, upBytesPerSec: Double) {
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
    }
}

/// 网络每进程差分账本(锁保护的微小盒子):首见 pid 记基线不出数、消失 pid
/// 丢弃、负差分钳 0、速率对墙钟折算——与磁盘每进程同三件半防护。
/// 空表(一次空回包)按普通轮处理:基线整表以本轮为准,不保留旧基线等
/// "恢复"——恢复轮从新基线重立,不出跨失败期的均摊速率。
public final class ProcessNetworkRateAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: NettopProcessTable?

    /// 折叠一轮差分;nil = 基线轮或病态轮(墙钟未前进)。
    public func record(_ table: NettopProcessTable) -> [pid_t: ProcessNetworkRates]? {
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = previous else {
            previous = table
            return nil
        }
        // transition-not-tick:同磁盘每进程,分母取实际墙钟间隔。
        let elapsed = table.takenAt.timeIntervalSince(baseline.takenAt)
        guard elapsed > 0 else {
            previous = table
            return nil
        }
        var rates: [pid_t: ProcessNetworkRates] = [:]
        rates.reserveCapacity(table.bytes.count)
        for (pid, bytes) in table.bytes {
            guard let base = baseline.bytes[pid] else { continue }
            let down = bytes.downBytes >= base.downBytes
                ? bytes.downBytes - base.downBytes : 0
            let up = bytes.upBytes >= base.upBytes
                ? bytes.upBytes - base.upBytes : 0
            rates[pid] = ProcessNetworkRates(
                downBytesPerSec: Double(down) / elapsed,
                upBytesPerSec: Double(up) / elapsed
            )
        }
        previous = table
        return rates
    }

    /// 隐藏即清账(同能耗影响)。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        previous = nil
    }

    public init() {}
}
