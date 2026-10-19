import Foundation

/// 采样 → 组卡的纯粘合逻辑(工单 05):持有出生登记表与归组配置,
/// 每轮采样"登记新出生 pid → 引擎归组 → 截组 CPU% 降序前 displayLimit 个"。
///
/// 出生登记有两个来源(评审 S1):独立出生扫描(BirthScanner,~2s 节奏,
/// 经 `mergeBirths` 并入)与每轮采样的 `registeringBirths` 兜底——
/// 后者仍保留,覆盖扫描间隙的漏网。
///
/// 值类型状态机:主干 RoundSpine(SystemMonitor 持有)每轮把快照与差分进程 CPU%
/// 喂进来,取截取前的全部组;单测用 SyntheticProcessSource 序列驱动。
struct GroupingPipeline {
    /// 弹窗展示组数(spec:Top-5)。
    static let defaultDisplayLimit = 5

    /// 出生登记表随轮次增长(内存版,重启即失——P0 决定)。
    private(set) var lineage = LineageRegistry()
    /// 全部组(工单 P0.5-01):最近一轮 update 截取**之前**的完整榜单,
    /// 与 Top 组同序同源——主窗口读这里,弹窗读 update 的返回值。
    private(set) var allGroups: [ProcessGroup] = []
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

    /// 并入出生扫描器(BirthScanner)在外部登记的出生(评审 S1):只补缺,
    /// 不改既有记录;扫描间隙出生、又在下一轮采样前退场的短命父进程由此留下快照。
    mutating func mergeBirths(_ external: LineageRegistry) {
        lineage = lineage.merging(external)
    }

    /// 一轮采样的推进。新出生进程的 CPU%(差分为 nil,无前值)按 0 计——
    /// 与引擎"缺失条目按 0 计"口径一致,首轮榜单全 0 属正常。
    mutating func update(
        snapshot: ProcessSnapshot,
        processCPU: [ProcessCPU]
    ) -> [ProcessGroup] {
        lineage = lineage.registeringBirths(in: snapshot)

        let groups = GroupingEngine.groups(
            from: snapshot,
            lineage: lineage,
            configuration: configuration,
            cpuPercentByPID: processCPU.cpuPercentByPID
        )
        allGroups = groups
        return Array(groups.prefix(displayLimit))
    }
}
