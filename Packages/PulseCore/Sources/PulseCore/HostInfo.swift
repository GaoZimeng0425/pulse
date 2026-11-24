import Foundation

// MARK: - 主机信息(工单 P0.6-05:主窗口副标题 / 弹窗运行时长)

/// 主机静态信息:芯片名 · 核数 · 物理内存。启动后不变,读一次即可。
/// 纯数据(arch-clean/02 挪入核心包);实机读取 `HostInfo.current` 在 app 的 Live 层。
/// 格式化出口在 PulseFormat.hostSummary。
public struct HostInfo: Equatable, Sendable {
    public let chipName: String?
    public let coreCount: Int
    public let physicalMemoryBytes: UInt64

    public init(chipName: String?, coreCount: Int, physicalMemoryBytes: UInt64) {
        self.chipName = chipName
        self.coreCount = coreCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}
