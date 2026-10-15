import Foundation
import Darwin

// MARK: - 系统内存构成(工单 P0.6-05:总览内存卡的实时口径)

/// 内存压力等级:`kern.memorystatus_vm_pressure_level` 的读数(1/2/4),
/// 总览内存卡的状态 chip(Vitals 的 `✓ Normal`)。
enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// 内核等级 → 枚举;未知值(含读失败的 0)按正常处理,不误报。
    init(kernelLevel: Int32) {
        switch kernelLevel {
        case 2: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }

    /// chip 文案。
    var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏高"
        case .critical: "紧张"
        }
    }
}

/// `host_statistics64(HOST_VM_INFO64)` 中参与构成计算的页计数。
struct VMPageCounts: Equatable, Sendable {
    let `internal`: UInt64
    let purgeable: UInt64
    let external: UInt64
    let wired: UInt64
    let compressor: UInt64
}

/// 系统内存构成,字节。口径与活动监视器一致:
/// App = 内部页 - 可清除页;联动 = wired;压缩 = compressor;
/// 缓存 = 外部页 + 可清除页;已用 = App + 联动 + 压缩;空闲 = 总 - 已用 - 缓存。
struct MemoryBreakdown: Equatable, Sendable {
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let pressure: MemoryPressure

    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    var freeBytes: UInt64 {
        let occupied = usedBytes + cachedBytes
        return totalBytes > occupied ? totalBytes - occupied : 0
    }

    /// 页计数 → 字节构成。计数非原子读取,瞬时不一致(可清除 > 内部、
    /// 已用 + 缓存 > 物理总量)一律夹紧到 0,不下溢。
    static func make(
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
}

// MARK: - 采集源

/// 内存构成采集接缝:OS 边界,协议之上纯逻辑。读失败返回 nil(卡片显示占位,不伪造)。
protocol MemoryStatsSource: Sendable {
    func sample() -> MemoryBreakdown?
}

/// Darwin 薄适配器:host_statistics64 + 物理内存 + 内存压力 sysctl。
struct LiveMemoryStatsSource: MemoryStatsSource {
    func sample() -> MemoryBreakdown? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        return MemoryBreakdown.make(
            pages: VMPageCounts(
                internal: UInt64(stats.internal_page_count),
                purgeable: UInt64(stats.purgeable_count),
                external: UInt64(stats.external_page_count),
                wired: UInt64(stats.wire_count),
                compressor: UInt64(stats.compressor_page_count)
            ),
            pageSize: UInt64(getpagesize()),
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            pressure: MemoryPressure(kernelLevel: Self.pressureLevel())
        )
    }

    private static func pressureLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 0
        }
        return level
    }
}

/// 合成源:固定吐出注入值(nil = 模拟读失败)。
struct SyntheticMemoryStatsSource: MemoryStatsSource {
    let breakdown: MemoryBreakdown?

    func sample() -> MemoryBreakdown? { breakdown }
}
