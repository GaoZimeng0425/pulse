import Foundation

// 系统内存构成的纯值层与源接缝。host_statistics64 适配器在 app target(MemoryStats.swift)。

/// 内存压力等级:`kern.memorystatus_vm_pressure_level` 的读数(1/2/4),
/// 总览内存卡的状态 chip(Vitals 的 `✓ Normal`)。
public enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// 内核等级 → 枚举;未知值(含读失败的 0)按正常处理,不误报。
    public init(kernelLevel: Int32) {
        switch kernelLevel {
        case 2: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }

    /// chip 文案。
    public var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏高"
        case .critical: "紧张"
        }
    }
}

/// `host_statistics64(HOST_VM_INFO64)` 中参与构成计算的页计数。
public struct VMPageCounts: Equatable, Sendable {
    public let `internal`: UInt64
    public let purgeable: UInt64
    public let external: UInt64
    public let wired: UInt64
    public let compressor: UInt64

    public init(internal: UInt64, purgeable: UInt64, external: UInt64, wired: UInt64, compressor: UInt64) {
        self.internal = `internal`
        self.purgeable = purgeable
        self.external = external
        self.wired = wired
        self.compressor = compressor
    }
}

/// 系统内存构成,字节。口径与活动监视器一致:
/// App = 内部页 - 可清除页;联动 = wired;压缩 = compressor;
/// 缓存 = 外部页 + 可清除页;已用 = App + 联动 + 压缩;空闲 = 总 - 已用 - 缓存。
public struct MemoryBreakdown: Equatable, Sendable {
    public let totalBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let pressure: MemoryPressure

    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    public var freeBytes: UInt64 {
        let occupied = usedBytes + cachedBytes
        return totalBytes > occupied ? totalBytes - occupied : 0
    }

    /// 页计数 → 字节构成。计数非原子读取,瞬时不一致(可清除 > 内部、
    /// 已用 + 缓存 > 物理总量)一律夹紧到 0,不下溢。
    public static func make(
        pages: VMPageCounts,
        pageSize: UInt64,
        totalBytes: UInt64,
        pressure: MemoryPressure
    ) -> MemoryBreakdown {
        let appPages = pages.internal > pages.purgeable ? pages.internal - pages.purgeable : 0
        return MemoryBreakdown(
            totalBytes: totalBytes,
            appBytes: appPages * pageSize,
            wiredBytes: pages.wired * pageSize,
            compressedBytes: pages.compressor * pageSize,
            cachedBytes: (pages.external + pages.purgeable) * pageSize,
            pressure: pressure
        )
    }

    public init(
        totalBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        pressure: MemoryPressure
    ) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.pressure = pressure
    }
}

/// 内存构成采集接缝:OS 边界,协议之上纯逻辑。读失败返回 nil(卡片显示占位,不伪造)。
public protocol MemoryStatsSource: Sendable {
    func sample() -> MemoryBreakdown?
}

/// 合成源:固定吐出注入值(nil = 模拟读失败)。
public struct SyntheticMemoryStatsSource: MemoryStatsSource {
    public let breakdown: MemoryBreakdown?

    public func sample() -> MemoryBreakdown? { breakdown }

    public init(breakdown: MemoryBreakdown? = nil) {
        self.breakdown = breakdown
    }
}
