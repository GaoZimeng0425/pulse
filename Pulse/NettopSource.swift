import Foundation

// 模块排行·每进程网络数据层(工单 01):每进程网络计数无公有 API,业界做法
// (Stats,MIT)是子进程跑一次 nettop 取每进程累计字节再差分。真机探针钉死
// 输出格式(2026-10-17,-L 1):首行表头 `,bytes_in,bytes_out,`,数据行形如
// `名称.pid,入字节,出字节[,尾随空列]`——名称可含点(有 bundle 前缀的辅助进程),
// pid 取最后一个点之后的段。解析全程容错:空输出 / 缺列 / 非数字 pid /
// 负数字节 / 空段一律跳过该行,不中断不崩。

// MARK: - 表形状(纯值)

/// 单进程网络累计字节(一次 nettop 回包的取值;差分输入)。
/// down = 入(bytes_in,接收),up = 出(bytes_out,发送),与 NetworkRates 同方向口径。
struct NettopProcessBytes: Equatable, Sendable {
    let downBytes: UInt64
    let upBytes: UInt64
}

/// 一趟 nettop 采样表 + 采样时刻(墙钟;差分对墙钟)。
struct NettopProcessTable: Sendable {
    let takenAt: Date
    let bytes: [pid_t: NettopProcessBytes]
}

// MARK: - CSV 解析(纯逻辑,合成夹具单测的接缝)

enum NettopCSVParser {
    /// 解析 nettop -L 1 的 CSV 文本;首行恒为表头,无条件跳过。
    /// 返回表(可能为空 = 无数据行);takenAt 由调用方注入(时钟可测)。
    static func parse(_ csv: String, takenAt: Date) -> NettopProcessTable {
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

// MARK: - 薄源协议(子进程边界)

/// 薄源协议(ADR-0004):跑一次 nettop 拿原始 CSV 文本。nil = 子进程起不来 /
/// 运行失败;空文本 = 无输出(解析为空表)。测试接合成 CSV 注入,不真实起子进程。
protocol NettopCSVSource: Sendable {
    func read() async -> String?
}

/// Live 源:每趟在专用串行队列上同步跑一次 nettop(调度 tick 是 async,
/// 但子进程等待是阻塞的——排到队列上,不占协作线程池)。超时 5s:看门狗
/// SIGTERM 逼出 EOF;失败 / 无输出如实返回 nil / 空文本,绝不抛出、绝不崩。
final class LiveNettopCSVSource: NettopCSVSource, @unchecked Sendable {
    static let executablePath = "/usr/bin/nettop"
    /// -P 按进程聚合(行首列 = 名称.pid);-L 1 只取一次采样;-n 不做地址名称
    /// 解析;-k 砍掉用不上的列(stats 同款参数表)。
    static let arguments = [
        "-P", "-L", "1", "-n",
        "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,"
            + "tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch",
    ]
    /// NSUnbufferedIO 让 nettop 立即刷缓冲(不等块缓冲);LC_ALL 锁定英文数字
    /// 格式,解析口径不随用户区域漂移。
    static let extraEnvironment = ["NSUnbufferedIO": "YES", "LC_ALL": "en_US.UTF-8"]
    /// 超时:nettop -L 1 正常亚秒返回;5s 容忍系统高载,超过即 SIGTERM 收尾。
    static let timeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.gaozimeng.pulse.nettop", qos: .utility)

    func read() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.runOnce())
            }
        }
    }

    /// 单趟子进程执行(静态:无 self 捕获,闭包 Sendable 干净)。
    private static func runOnce() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // 继承环境再覆盖两项:nettop 依赖的框架路径等保持原样。
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil // 起不来(路径缺失等):nil = 读失败,消费方保 lastGood
        }
        // Process 非 Sendable,但看门狗与读端对它的访问无竞争:读端只碰管道
        // (专用串行队列),看门狗只看 isRunning / 发 terminate,对象生命周期
        // 由本函数持有到底——@unchecked 声明安全。
        let handle = UnsafeSendableProcess(process)
        // 读端在本(专用串行)队列阻塞到 EOF:管道缓冲有限,必须与子进程
        // 写端并行排空;EOF 由进程退出或看门狗 SIGTERM 逼出。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if handle.process.isRunning { handle.process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if process.isRunning { process.waitUntilExit() }
        // 不看退出码:SIGTERM 收尾的半截输出里,完整行仍是合法累计值,
        // 解析器逐行容错(坏行跳过)。
        return String(decoding: data, as: UTF8.self)
    }
}

/// Process 的 @unchecked Sendable 盒(见 LiveNettopCSVSource.runOnce 注释)。
private final class UnsafeSendableProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

// MARK: - 网络每进程排行

/// 单进程网络速率(字节/秒;一轮差分对两趟墙钟间隔折算)。
struct ProcessNetworkRates: Equatable, Sendable {
    let downBytesPerSec: Double
    let upBytesPerSec: Double
}

/// 网络每进程差分账本(锁保护的微小盒子):首见 pid 记基线不出数、消失 pid
/// 丢弃、负差分钳 0、速率对墙钟折算——与磁盘每进程同三件半防护。
/// 空表(一次空回包)按普通轮处理:基线整表以本轮为准,不保留旧基线等
/// "恢复"——恢复轮从新基线重立,不出跨失败期的均摊速率。
final class ProcessNetworkRateAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: NettopProcessTable?

    /// 折叠一轮差分;nil = 基线轮或病态轮(墙钟未前进)。
    func record(_ table: NettopProcessTable) -> [pid_t: ProcessNetworkRates]? {
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
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        previous = nil
    }
}

/// 网络每进程 provider(工单 01,ADR-0004):低频档 5s,仅窗口可见时跑;
/// 子进程成本由门控挡住,读失败交付 lastGood 不白屏。时钟注入:CSV 不带
/// 采样时刻,差分对墙钟的"墙钟"由此来(测试用假时间轴,零真实等待)。
final class ProcessNetworkRateProvider: SensorProvider {
    typealias Reading = [pid_t: ProcessNetworkRates]
    typealias Clock = @Sendable () -> Date

    let cadence: SensorCadence = .every(seconds: 5)

    private let source: any NettopCSVSource
    private let clock: Clock
    private let gate = SensorVisibilityGate()
    private let accumulator = ProcessNetworkRateAccumulator()
    private let slot = SensorLastGoodBox<Reading>()

    var lastGood: Reading? { slot.current }

    init(
        source: any NettopCSVSource = LiveNettopCSVSource(),
        clock: @escaping Clock = { Date() }
    ) {
        self.source = source
        self.clock = clock
    }

    /// 可见性切换(同能耗影响)。
    func setVisible(_ visible: Bool) {
        if gate.setVisible(visible), !visible { accumulator.reset() }
    }

    func snapshot() async -> Reading? {
        guard gate.isVisible else { return nil }
        guard let csv = await source.read() else { return nil }
        let table = NettopCSVParser.parse(csv, takenAt: clock())
        guard let reading = accumulator.record(table) else { return nil }
        slot.store(reading)
        return reading
    }
}
