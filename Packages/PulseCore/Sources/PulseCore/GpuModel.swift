import Foundation

// MARK: - GPU 传感器(p2-sensors/02,ADR-0004 SensorProvider 接缝)

/// GPU 原始读数(Live 交回的原始载荷,键提取在 Live、值折算在核心包):
/// IORegistry `IOAccelerator` 条目的 `PerformanceStatistics` 字典 + 条目顶层的
/// 静态信息。防御口径移植自 stats(MIT)`Modules/GPU/reader.swift`(调研
/// docs/research/sensor-impl-comparison.md §2.4):总利用率取
/// "Device Utilization %",缺键回退 "GPU Activity(%)"(reader.swift:139);
/// AGC 电源管理关电 = `AGCInfo["poweredOffByAGC"]`(条目顶层,reader.swift:205)。
/// 本机实证(2026-10-22 探针):M4 三利用率键在场,字典**无**温度/频率键——
/// GPU 温度归 SMC 家族(p2-sensors/04),不进本读数。
public struct GpuRawReading: Equatable, Sendable {
    /// 总利用率首选键 "Device Utilization %"。
    public var deviceUtilizationPercent: Double?
    /// 回退键 "GPU Activity(%)"(stats 同款回退序)。
    public var gpuActivityPercent: Double?
    public var rendererUtilizationPercent: Double?
    public var tilerUtilizationPercent: Double?
    /// "Alloc system memory"(驱动分配)。
    public var allocatedBytes: Int?
    /// "In use system memory"(实际在用)。
    public var inUseBytes: Int?
    /// 条目顶层 "model"(如 "Apple M4")。
    public var modelName: String?
    /// 条目顶层 "gpu-core-count"。
    public var coreCount: Int?
    /// AGC 电源管理已关电(Live 从条目顶层 AGCInfo 判定)。
    public var poweredOffByAGC: Bool

    public init(
        deviceUtilizationPercent: Double? = nil,
        gpuActivityPercent: Double? = nil,
        rendererUtilizationPercent: Double? = nil,
        tilerUtilizationPercent: Double? = nil,
        allocatedBytes: Int? = nil,
        inUseBytes: Int? = nil,
        modelName: String? = nil,
        coreCount: Int? = nil,
        poweredOffByAGC: Bool = false
    ) {
        self.deviceUtilizationPercent = deviceUtilizationPercent
        self.gpuActivityPercent = gpuActivityPercent
        self.rendererUtilizationPercent = rendererUtilizationPercent
        self.tilerUtilizationPercent = tilerUtilizationPercent
        self.allocatedBytes = allocatedBytes
        self.inUseBytes = inUseBytes
        self.modelName = modelName
        self.coreCount = coreCount
        self.poweredOffByAGC = poweredOffByAGC
    }
}

/// GPU 读数(折算后):数值全部钳位到 0…100(驱动偶尔回报越界,stats 同款防御);
/// AGC 关电时利用率归 0 是**正常态**不是故障(调研 §2.4 防御点),`poweredOff`
/// 保留原样供 UI 文案区分"空闲 0%"与"关电 0%"。
public struct GpuReading: Equatable, Sendable {
    public let utilizationPercent: Double
    public let rendererPercent: Double?
    public let tilerPercent: Double?
    public let allocatedBytes: Int?
    public let inUseBytes: Int?
    public let modelName: String?
    public let coreCount: Int?
    public let poweredOff: Bool

    /// 原始读数 → 展示读数:利用率 = 首选键回退回退键,关电归 0,百分位钳
    /// 0…100;Renderer/Tiler 同钳。两个利用率键全缺(未来芯片)时利用率落 0
    /// (stats 同款口径),静态信息照常透传——占位兜底在消费方。
    public static func make(from raw: GpuRawReading) -> GpuReading {
        let base = raw.deviceUtilizationPercent ?? raw.gpuActivityPercent
        let utilization = raw.poweredOffByAGC ? 0 : clamped(base)
        return GpuReading(
            utilizationPercent: utilization ?? 0,
            rendererPercent: clamped(raw.rendererUtilizationPercent),
            tilerPercent: clamped(raw.tilerUtilizationPercent),
            allocatedBytes: raw.allocatedBytes,
            inUseBytes: raw.inUseBytes,
            modelName: raw.modelName,
            coreCount: raw.coreCount,
            poweredOff: raw.poweredOffByAGC
        )
    }

    /// 百分位钳位(nil 穿透):>100 钳 100(stats reader.swift:209-226 同款防御);
    /// 负值钳 0(驱动回报 -1 之类的心跳位)。
    private static func clamped(_ value: Double?) -> Double? {
        value.map { min(max($0, 0), 100) }
    }
}

// MARK: - GPU 源协议(编译期测试接缝,ADR-0003 澄清条款同款)

/// GPU 源(ADR-0004 接缝):产品运行期唯一真实现 = app 的 Live 适配器
/// (IORegistry 调用),测试注入假源;缝上全部纯逻辑(本文件的折算)。
public protocol GpuSource: Sendable {
    /// 读一次;nil = 读失败(无加速器条目 / 字典缺失)。
    func read() -> GpuRawReading?
}

/// GPU 传感器:分档单循环(p2-review/06)——一条驱动两个节奏,可见 5s /
/// 不可见 30s(`adaptiveInterval`),历史广播由 feature 侧 HistoryThrottle 节流。
/// 旧形状(5s UI 档 + 30s 历史档两条驱动并发读同一 provider)就此收编:
/// 单循环天然串行,读失败交付 lastGood 不白屏(nettop 同款形状)。
public final class GpuSensorProvider: SensorProvider {
    public typealias Reading = GpuReading

    public let cadence: SensorCadence = .every(seconds: 5)

    private let source: any GpuSource
    /// 可见性闸(p2-review/06 起只驱动节奏分档,不再挡读——历史档本就 30s 恒采)。
    private let gate = SensorVisibilityGate()
    private let slot = SensorLastGoodBox<GpuReading>()

    public var lastGood: GpuReading? {
        slot.current
    }

    public init(source: any GpuSource) {
        self.source = source
    }

    /// 可见性切换(任一窗口停在展示 GPU 家族的 tab,GpuFeature 折算下发)。
    public func setVisible(_ visible: Bool) {
        _ = gate.setVisible(visible)
    }

    public var adaptiveInterval: (@Sendable () -> TimeInterval)? {
        { [gate] in gate.isVisible ? SensorTier.ui : SensorTier.history }
    }

    public func snapshot() async -> GpuReading? {
        guard let raw = source.read() else { return nil }
        let reading = GpuReading.make(from: raw)
        slot.store(reading)
        return reading
    }
}
