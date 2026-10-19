import Foundation

// MARK: - 传感器节奏(ADR-0004)

/// 传感器节奏(ADR-0004):CPU/内存/网络吞吐这类**心跳型**每 1–5 秒都要新值,
/// 否则图是断的;磁盘容量对账、电池这类**低频/事件型** 30–60 秒甚至状态变化时
/// 才需要读——把低频活塞进 1s 心跳是用 60 倍频率干 1/60 的活。
/// 心跳型指标继续住在 Sampler 单一循环节拍里不拆(ADR-0004),本枚举只描述节奏;
/// `.heartbeat` 登记进调度器属编程错误,调度器安静忽略(见 SensorScheduler)。
enum SensorCadence: Equatable, Sendable {
    case heartbeat
    case every(seconds: TimeInterval)
    case onEvent
}

// MARK: - 薄 SensorProvider 协议(ADR-0004)

/// 薄传感器 provider(ADR-0004):编译期测试接缝——运行期各只有一个真实现,
/// 不做运行时替换(ADR-0003 澄清条款同款),缝上全部纯逻辑。
/// 与 stats(MIT)的 Reader 同构思想,但不搬它的 `Reader<T>` 基类:DB 写入
/// 焊基类、callback 链拖远程/Widget、config.plist 运行时声明、每 Reader 一个
/// 定时器,四点都不要(ADR-0004);本地 UI 由 SystemMonitor 的 @Observable
/// 字段刷新即渲染。
protocol SensorProvider: Sendable {
    associatedtype Reading: Sendable
    /// 本传感器的节奏。
    var cadence: SensorCadence { get }
    /// 读一次;nil = 读失败(调度器跳过本轮交付,消费方保留既有显示)。
    func snapshot() async -> Reading?
    /// 上次好值(ADR-0004):读失败时保留,UI 据此显示上次好值而不是白屏。
    var lastGood: Reading? { get }
    /// `.onEvent` 档的唤醒流:每次事件发一个 void,流结束 = 驱动循环结束。
    /// 非事件档无需实现(默认 nil)。
    func wakeups() -> AsyncStream<Void>?
}

extension SensorProvider {
    func wakeups() -> AsyncStream<Void>? { nil }
}

// MARK: - lastGood 保留槽

/// lastGood 保留槽(ADR-0004):读成功存入、读失败保留。锁保护的微小盒子——
/// 协议要求非隔离读取(`lastGood` 无隔离标注),不能挂在 actor 上。
final class SensorLastGoodBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    var current: Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 可见性闸门

/// 可见性闸门(工单 01):模块排行类低频源的采样成本闸门——任何窗口可见
/// 才真正读数,否则 tick 在门口空转(不起 nettop 子进程;能耗/磁盘排行已随
/// 票 A 高2 并入心跳,门控在 Sampler.setRankingsActive)。
/// 锁保护的微小盒子,与 SensorLastGoodBox 同款纪律(协议要求非隔离读取,
/// 不能挂 actor)。
final class SensorVisibilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var visible = false

    /// 设置可见性;返回是否发生翻转(调用方据此决定清不清差分账本)。
    @discardableResult
    func setVisible(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = visible != newValue
        visible = newValue
        return changed
    }

    var isVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible
    }
}

// MARK: - 调度登记(类型擦除核心)

/// 调度器眼里的一项登记:节奏 + "读一次并交付"。provider 经 `driver(deliver:)`
/// 折叠成此形,调度器只见此形不见泛型。tick 内部固定为
/// `snapshot() ?? lastGood`:成功交付新读数;读失败交付上次好值(不白屏);
/// 两者皆无(从未有过读数,典型 = 无内建电池)才交付 nil。
struct SensorDriver: Sendable {
    let cadence: SensorCadence
    let tick: @Sendable () async -> Void
    /// `.onEvent` 档的唤醒流构造;非事件档为 nil。
    let wakeups: (@Sendable () -> AsyncStream<Void>?)?
}

extension SensorProvider {
    /// 把 provider 折叠成调度登记项;deliver 在调度上下文被调用,
    /// 消费方自行跳回 MainActor(SystemMonitor 同款粘合)。
    func driver(deliver: @escaping @Sendable (Reading?) -> Void) -> SensorDriver {
        let provider = self
        let tick: @Sendable () async -> Void = {
            let reading = await provider.snapshot() ?? provider.lastGood
            await deliver(reading)
        }
        var wakeups: (@Sendable () -> AsyncStream<Void>?)? = nil
        if cadence == .onEvent {
            wakeups = { provider.wakeups() }
        }
        return SensorDriver(cadence: cadence, tick: tick, wakeups: wakeups)
    }
}

// MARK: - 单一调度器 actor(ADR-0004)

/// 单一调度器 actor:按各 provider 的节奏统一驱动"读一次并交付"——对应
/// stats"每 Reader 自养一个 DispatchSourceTimer",但只有一个调度大脑(ADR-0004)。
/// 低频档定时读、事件档订阅唤醒流、心跳档安静忽略(住 Sampler)。
/// 睡眠可注入,单测零真实等待(与 Sampler/BirthScanner 同款纪律)。
actor SensorScheduler {
    typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    private let sleep: Sleeping

    init(
        sleep: @escaping Sleeping = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.sleep = sleep
    }

    /// 驱动全部登记项直至任务取消;每登记项一条子任务,同一 actor 内汇合。
    func run(_ drivers: [SensorDriver]) async {
        await withTaskGroup(of: Void.self) { group in
            for driver in drivers {
                group.addTask { await self.drive(driver) }
            }
        }
    }

    private func drive(_ driver: SensorDriver) async {
        switch driver.cadence {
        case .heartbeat:
            // 心跳型指标住 Sampler 单一循环节拍(ADR-0004):登记到调度器
            // 属编程错误,安静忽略——不产生读数、不等待。
            return
        case .every(let interval):
            while !Task.isCancelled {
                await driver.tick()
                do {
                    try await sleep(interval)
                } catch {
                    return // sleep 抛错(典型:取消)= 停机信号
                }
            }
        case .onEvent:
            guard let wakeups = driver.wakeups?() else { return }
            for await _ in wakeups {
                if Task.isCancelled { return }
                await driver.tick()
            }
        }
    }
}
