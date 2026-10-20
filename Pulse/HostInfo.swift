import Foundation
import Darwin
import PulseCore

// MARK: - 主机信息(工单 P0.6-05:主窗口副标题 / 弹窗运行时长)

/// 主机静态信息:芯片名 · 核数 · 物理内存。启动后不变,读一次即可。
/// 格式化出口在 PulseFormat.hostSummary(单测见 SystemStatsTests),
/// 读到的实机值以走查验收(硬件不会热变)。
struct HostInfo: Equatable, Sendable {
    let chipName: String?
    let coreCount: Int
    let physicalMemoryBytes: UInt64

    static let current = HostInfo(
        chipName: sysctlString("machdep.cpu.brand_string"),
        coreCount: ProcessInfo.processInfo.processorCount,
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
