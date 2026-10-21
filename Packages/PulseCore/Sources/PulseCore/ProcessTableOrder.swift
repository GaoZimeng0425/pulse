import Foundation

// MARK: - 主窗口进程表排序(工单 P0.5-01)

/// 进程表排序键:主窗口进程表的 CPU% / 内存两列可点表头排序。
public enum ProcessTableSortKey: String, Equatable, Sendable {
    /// 进程 CPU%(单核 100% 口径,与组 CPU% 同源差分)。
    case cpu
    /// 物理足迹(活动监视器"内存"列口径)。
    case memory
}

/// 进程表排序(纯逻辑):默认 = 引擎既定序(CPU% 降序)——进窗口不点表头时
/// 与弹窗下钻同观感;点表头切换键与方向。同值次键 pid 升序,排序跨采样轮稳定。
/// 单测见 MainWindowModelTests;表头 UI(指示符渲染)属手动验收。
public struct ProcessTableOrder: Equatable, Sendable {
    public var key: ProcessTableSortKey
    public var ascending: Bool

    public init(key: ProcessTableSortKey = .cpu, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }

    /// 点表头:同一列 = 升降切换;换列 = 回到该列主视角(降序,占大头在前)。
    public mutating func toggle(_ newKey: ProcessTableSortKey) {
        if key == newKey {
            ascending.toggle()
        } else {
            key = newKey
            ascending = false
        }
    }

    /// 按当前键与方向排序;同值以 pid 升序破平(与方向无关)——
    /// 不引入额外状态,输入序不影响结果,排序跨采样轮稳定。
    public func sorted(_ rows: [ProcessRowModel]) -> [ProcessRowModel] {
        rows.sorted { lhs, rhs in
            switch key {
            case .cpu:
                if lhs.cpuPercent == rhs.cpuPercent {
                    return lhs.pid < rhs.pid
                }
                return ascending ? lhs.cpuPercent < rhs.cpuPercent : lhs.cpuPercent > rhs.cpuPercent
            case .memory:
                if lhs.memoryBytes == rhs.memoryBytes {
                    return lhs.pid < rhs.pid
                }
                return ascending ? lhs.memoryBytes < rhs.memoryBytes : lhs.memoryBytes > rhs.memoryBytes
            }
        }
    }
}
