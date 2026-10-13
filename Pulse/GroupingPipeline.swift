import Foundation

/// 采样 → 组卡的纯粘合逻辑(工单 05):持有出生登记表与归组配置,
/// 每轮采样"登记新出生 pid → 引擎归组 → 截组 CPU% 降序前 displayLimit 个"。
///
/// 值类型状态机:SystemMonitor(呈现层)每轮把快照与差分进程 CPU% 喂进来,
/// 拿到弹窗要显示的 Top 组;单测用 SyntheticProcessSource 序列驱动。
struct GroupingPipeline {
    /// 弹窗展示组数(spec:Top-5)。
    static let defaultDisplayLimit = 5

    /// 出生登记表随轮次增长(内存版,重启即失——P0 决定)。
    private(set) var lineage = LineageRegistry()
    /// 归组配置:`projectRoots` 允许热更新(setProjectRoots,工单 07),其余构造时定型。
    private(set) var configuration: GroupingConfiguration
    let displayLimit: Int

    init(
        configuration: GroupingConfiguration = GroupingConfiguration(),
        displayLimit: Int = GroupingPipeline.defaultDisplayLimit
    ) {
        self.configuration = configuration
        self.displayLimit = displayLimit
    }

    /// 更新项目根列表(工单 07 设置窗):立即写入配置,**下一轮 update 即以新根归组**
    /// ——增删根 ≤1 轮采样生效;清空列表 = 回到 03 的降级路径。
    /// 热更新行为单测见 GroupingPipelineTests"项目根热更新"用例。
    mutating func setProjectRoots(_ roots: [String]) {
        configuration.projectRoots = roots
    }

    /// 一轮采样的推进。新出生进程的 CPU%(差分为 nil,无前值)按 0 计——
    /// 与引擎"缺失条目按 0 计"口径一致,首轮榜单全 0 属正常。
    mutating func update(
        snapshot: ProcessSnapshot,
        processCPU: [ProcessCPU]
    ) -> [ProcessGroup] {
        lineage = lineage.registeringBirths(in: snapshot)

        var cpuPercentByPID: [pid_t: Double] = [:]
        cpuPercentByPID.reserveCapacity(processCPU.count)
        for entry in processCPU {
            cpuPercentByPID[entry.pid] = entry.cpuPercent ?? 0
        }

        let groups = GroupingEngine.groups(
            from: snapshot,
            lineage: lineage,
            configuration: configuration,
            cpuPercentByPID: cpuPercentByPID
        )
        return Array(groups.prefix(displayLimit))
    }
}
