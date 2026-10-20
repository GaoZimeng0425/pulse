import Foundation
import Darwin
import PulseCore

// MARK: - 采集源

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

