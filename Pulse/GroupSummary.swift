import Foundation

/// 组(GLOSSARY):归组的输出单位——显示名 + 聚合指标(组 CPU% / 内存 / 进程数)。
/// 本工单(01 工程骨架)只承载静态假数据;采集与归组引擎在后续工单接入。
struct GroupSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// 组 CPU%:单核 100% 累加,可超过 100%(如 445% ≈ 4.5 个核满载)。
    let cpuPercent: Double
    /// 组内聚合内存,字节。
    let memoryBytes: UInt64
    /// 组内进程数。
    let processCount: Int

    init(
        id: UUID = UUID(),
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        processCount: Int
    ) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processCount = processCount
    }
}

/// 工程骨架的静态假数据:菜单栏假"42%" + 三张组卡(P0 验收锚点场景)。
enum FakeSnapshot {
    /// 系统CPU负载(0–100% 口径),菜单栏数字用。假数据。
    static let systemCPULoad: Double = 42

    /// 静态组卡,组 CPU% 降序:门禁项目组 / OrbStack / 常驻 WaifuX。
    static let topGroups: [GroupSummary] = [
        GroupSummary(
            name: "octok-client @ skill-manage-read-and-index",
            cpuPercent: 445,
            memoryBytes: 2_400_000_000,
            processCount: 12
        ),
        GroupSummary(
            name: "OrbStack",
            cpuPercent: 38,
            memoryBytes: 1_600_000_000,
            processCount: 9
        ),
        GroupSummary(
            name: "WaifuX",
            cpuPercent: 12,
            memoryBytes: 512_000_000,
            processCount: 1
        ),
    ]
}
