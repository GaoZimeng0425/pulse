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
public struct GroupingPipeline {
    /// 弹窗展示组数(spec:Top-5)。
    public static let defaultDisplayLimit = 5

    /// 出生登记表随轮次增长:本会话活记录(出生扫描并入 + 采样轮兜底)与历史回灌
    /// (工单 p1-history/03)汇在一张表里。同 pid 冲突按身份裁决、每个 pid 只裁一次:
    /// 同一进程取回灌(出生时刻的父链比重挂 launchd 之后的现场更真),pid 复用取
    /// 活记录(Entry.isSameProcess)。
    public private(set) var lineage = LineageRegistry()
    /// 记录取自回灌、尚未遇到本会话活记录对质的 pid:活记录到来时裁决一次即移出。
    private var unsettledRestoredPIDs: Set<pid_t> = []
    /// 上次 update 以来出生扫描并入的 pid:当轮修剪时保留(它们可能还没进快照)。
    private var recentScannerBirths: Set<pid_t> = []
    /// 跨轮的自身归属缓存(arch-review-2026-10-18/04):项目根变化时缓存自行作废。
    private let attributionCache = SelfAttributionCache()
    /// 全部组(工单 P0.5-01):最近一轮 update 截取**之前**的完整榜单,
    /// 与 Top 组同序同源——主窗口读这里,弹窗读 update 的返回值。
    public private(set) var allGroups: [ProcessGroup] = []
    /// 归组配置:`projectRoots`(setProjectRoots,工单 07)与 `launchdServiceExecutablePaths`
    /// (setLaunchdServiceExecutablePaths,launchd-attribution/01)允许热更新,其余构造时定型。
    public private(set) var configuration: GroupingConfiguration
    public let displayLimit: Int

    public init(
        configuration: GroupingConfiguration = GroupingConfiguration(),
        displayLimit: Int = GroupingPipeline.defaultDisplayLimit
    ) {
        self.configuration = configuration
        self.displayLimit = displayLimit
    }

    /// 更新项目根列表(工单 07 设置窗):立即写入配置,**下一轮 update 即以新根归组**
    /// ——增删根 ≤1 轮采样生效;清空列表 = 回到 03 的降级路径。
    /// 热更新行为单测见 GroupingPipelineTests"项目根热更新"用例。
    public mutating func setProjectRoots(_ roots: [String]) {
        configuration.projectRoots = roots
    }

    /// 更新 launchd 服务清单(launchd-attribution/01):低频传感器每次交付整份替换,
    /// 下一轮 update 即以新清单判定后台服务;空集 = 只剩静态 launchd 域。
    public mutating func setLaunchdServiceExecutablePaths(_ paths: Set<String>) {
        configuration.launchdServiceExecutablePaths = paths
    }

    /// 并入出生扫描器(BirthScanner)在外部登记的出生(评审 S1):只补缺,
    /// 不改既有记录;扫描间隙出生、又在下一轮采样前退场的短命父进程由此留下快照。
    public mutating func mergeBirths(_ external: LineageRegistry) {
        for (pid, entry) in external.entries {
            adoptLive(pid: pid, entry: entry)
            recentScannerBirths.insert(pid)
        }
    }

    /// 并入历史回灌的出生登记(工单 p1-history/03):已有活记录的 pid 当场裁决
    /// (同一进程取回灌,pid 复用留活记录);其余补缺,待活记录到来时再裁。
    /// 已有回灌记录的 pid 不覆盖(首记为准)。
    public mutating func restoreBirths(_ restored: LineageRegistry) {
        for (pid, entry) in restored.entries {
            if let existing = lineage.entries[pid] {
                if !unsettledRestoredPIDs.contains(pid), existing.isSameProcess(as: entry) {
                    lineage.replace(pid: pid, with: entry)
                }
            } else {
                lineage.replace(pid: pid, with: entry)
                unsettledRestoredPIDs.insert(pid)
            }
        }
    }

    /// 一条活记录到来:无记录即登记;记录取自回灌且尚未裁决 → 裁决一次(pid 复用则
    /// 活记录覆盖);其余既有记录不动(活记录之间首记为准)。
    private mutating func adoptLive(pid: pid_t, entry: LineageRegistry.Entry) {
        guard let existing = lineage.entries[pid] else {
            lineage.replace(pid: pid, with: entry)
            return
        }
        guard unsettledRestoredPIDs.remove(pid) != nil else { return }
        if !existing.isSameProcess(as: entry) {
            lineage.replace(pid: pid, with: entry)
        }
    }

    /// 一轮采样的推进。新出生进程的 CPU%(差分为 nil,无前值)按 0 计——
    /// 与引擎"缺失条目按 0 计"口径一致,首轮榜单全 0 属正常。
    public mutating func update(
        snapshot: ProcessSnapshot,
        processCPU: [ProcessCPU]
    ) -> [ProcessGroup] {
        for process in snapshot.processes {
            adoptLive(pid: process.pid, entry: LineageRegistry.Entry(
                parentPID: process.parentPID,
                identity: process.identity
            ))
        }
        // 修剪(arch-review-2026-10-18/04):只留在场进程、刚由扫描并入的新出生,以及
        // 它们父链上的祖先;死进程的其余记录丢掉——登记表规模随活进程数,不随运行时长
        // (此前只增不删,回灌 + 扫描 4 天累到近 10 万条,每轮归组 / 并入 / 落库都要过一遍)。
        var keep = recentScannerBirths
        for process in snapshot.processes {
            keep.insert(process.pid)
        }
        lineage = lineage.pruned(keeping: keep)
        unsettledRestoredPIDs.formIntersection(lineage.entries.keys)
        recentScannerBirths = []

        let groups = GroupingEngine.groups(
            from: snapshot,
            lineage: lineage,
            configuration: configuration,
            cpuPercentByPID: processCPU.cpuPercentByPID,
            selfAttributionCache: attributionCache
        )
        allGroups = groups
        return Array(groups.prefix(displayLimit))
    }
}
