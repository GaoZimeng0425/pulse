import Darwin
import Foundation
import PulseCore

// MARK: - 主机信息(工单 P0.6-05:主窗口副标题 / 弹窗运行时长)

/// 实机读取(sysctl / ProcessInfo);数据类型本身在 PulseCore(arch-clean/02)。
extension HostInfo {
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
        // sysctl 缓冲自带 NUL 终止;decoding 不在 NUL 截断,先截再映 UInt8
        // (CChar 是 Int8,废弃的 String(cString:) 替换口径)。
        let value = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
