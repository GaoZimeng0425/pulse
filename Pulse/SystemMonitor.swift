import Foundation
import Observation
import Darwin

/// 呈现层模型(spec 命名 SystemMonitor):持有采样管线,把每轮采样变成可观察状态。
/// 菜单栏数字 = 系统 CPU 负载(GLOSSARY:0–100%,每核 tick 口径,评审 S6);
/// 弹窗 = Top-5 组(组 CPU% 降序,系统组参榜)。
///
/// UI 粘合层,按 spec 测试决策不写单元测试;采样 / 差分 / 归组 / 截取逻辑分别在
/// Sampler / CPUDiffer+CoreTickDiffer / GroupingEngine / GroupingPipeline 里被单测覆盖。
@Observable
@MainActor
final class SystemMonitor {
    /// 系统 CPU 负载超过该值菜单栏变红(spec:70%)。
    static let redThreshold: Double = 70

    /// 系统 CPU 负载,0–100%,随采样跳动。
    private(set) var systemCPULoad: Double = 0
    /// 负载的用户/系统拆分(工单 P0.6-05 总览 CPU 卡)。
    private(set) var cpuBreakdown: CPULoadBreakdown = .zero
    /// 系统内存构成(工单 P0.6-05);首轮采样前或读失败为 nil。
    private(set) var memory: MemoryBreakdown?
    /// 全部组(GLOSSARY 组),组 CPU% 降序,每轮整体刷新;首轮采样前为空。
    /// 弹窗与主窗口都读这里(用户拍板:弹窗不再截 Top-5,滚动展示全部)。
    private(set) var allGroups: [ProcessGroup] = []
    /// 采样历史(工单 P0.6-01):系统负载 + 每组 CPU%/内存的近期窗口
    /// (~60 点),随每轮 apply 推进;走势图与 avg/peak 统计读这里。
    /// 纯逻辑在 SampleHistoryStore(单测见 SampleHistoryTests),此处仅粘合。
    private(set) var history = SampleHistoryStore()
    /// 最近一轮采样留下的下钻输入(工单 06):组卡展开 / 进程详情从这里只读取数,
    /// 下钻不触发额外采集;首轮采样前为 nil。
    private(set) var drilldown: DrilldownState?
    /// 电池读数(工单 02):最近一次交付,LastGood 语义——读失败交付上次好值,
    /// 不回退为 nil、不白屏。弹窗与主窗口的电池 tab 读这里。
    private(set) var battery: BatteryReading?
    /// 本机有内建电池(工单 02):首次成功读数置真,电池 tab 随之入轴;
    /// 台式机永无交付 → 恒假,电池页整页隐藏。只翻真不翻假。
    private(set) var hasBattery = false

    private let sampler: Sampler
    /// 独立出生扫描(评审 S1):~2s 节奏登记新 pid,与采样节奏解耦。
    private let birthScanner: BirthScanner
    /// 电池传感器(工单 02,ADR-0004 第一个真 provider):事件驱动,IOPS 通知。
    private let batteryProvider: BatterySensorProvider
    /// 出生扫描最近交付的登记表:每轮采样落地时并入管线(只补缺)。
    private var birthLineage = LineageRegistry()
    private var pipeline: GroupingPipeline
    private let killService: any KillService
    private var samplingTask: Task<Void, Never>?
    private var sensorTask: Task<Void, Never>?
    private var started = false

    init(
        source: any ProcessSource = LiveProcessSource(),
        coreTicks: any CoreTickSource = LiveCoreTickSource(),
        memoryStats: any MemoryStatsSource = LiveMemoryStatsSource(),
        projectRoots: [String] = [],
        killService: any KillService = LiveKillService(),
        birthScanSource: any BirthScanSource = LiveBirthScanSource(),
        batterySource: any BatterySource = LiveBatterySource()
    ) {
        self.sampler = Sampler(source: source, coreTicks: coreTicks, memoryStats: memoryStats)
        self.birthScanner = BirthScanner(source: birthScanSource)
        self.batteryProvider = BatterySensorProvider(source: batterySource)
        self.pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(
                projectRoots: projectRoots,
                bundleDisplayName: BundleDisplayNameReader.shared.displayName
            )
        )
        self.killService = killService
    }

    /// 启动采样循环(默认弹窗关闭节奏 5s)、独立出生扫描(~2s 节奏)与电池
    /// 传感器调度器(事件驱动):菜单栏数字与组卡从拉起就是真的,采样间隙
    /// 出生的短命父进程也留得下快照。幂等;由 UI 的 `.task` 触发。
    /// weak self:循环与 app 同寿命,不构成保留环。
    func start() {
        guard !started else { return }
        started = true
        let scanner = birthScanner
        Task { [weak self] in
            await scanner.run { [weak self] lineage in
                guard let self else { return }
                Task { @MainActor in
                    self.birthLineage = lineage
                }
            }
        }
        let sampler = self.sampler
        samplingTask = Task { [weak self] in
            await sampler.run { [weak self] update in
                guard let self else { return }
                Task { @MainActor in
                    self.apply(update)
                }
            }
        }
        // 非心跳型传感器(ADR-0004):单一调度器 actor 按 cadence 驱动。
        let provider = batteryProvider
        let scheduler = SensorScheduler()
        sensorTask = Task { [weak self] in
            await scheduler.run([provider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in
                    self.applyBattery(reading)
                }
            }])
        }
    }

    /// 弹窗可见性变化:采样节奏在 5s/1s 间切换(合盖省电,spec)。
    /// 出生扫描不受弹窗影响:登记的完整性不依赖观看。
    func setPopoverVisible(_ visible: Bool) {
        let sampler = self.sampler
        Task { await sampler.setPopoverVisible(visible) }
    }

    /// 项目根变更(工单 07 设置窗):立即写入管线配置,**下一轮采样即以新根归组**
    /// (增删 ≤1 轮生效);清空列表 = 回到 03 的降级路径。传播逻辑在
    /// GroupingPipelineTests"项目根热更新"用例单测,此处仅 MainActor 粘合。
    func setProjectRoots(_ roots: [String]) {
        pipeline.setProjectRoots(roots)
    }

    /// 结束进程(工单 08):UI 确认后调用——SIGTERM 逐目标投递,
    /// 永不包含自身 pid(getpid),失败逐目标浮出(KillReport)。
    /// 下轮采样自然反映消失;此处仅 MainActor 粘合(编排单测见 KillActionTests)。
    func terminate(_ targets: [KillTarget]) -> KillReport {
        KillReport(outcomes: KillAction.terminate(
            targets,
            excluding: getpid(),
            service: killService
        ))
    }

    /// 结束整组(工单 08):执行瞬间从**最新一轮采样**的组里重取成员
    /// (确认对话框打开期间可能又采了一轮,以最新存活名单为准);
    /// 组已消失 → 空报告(无需处置,也无失败可报)。
    /// 工单 P0.5-01:查全组列表(主窗口与弹窗可见的组都要能处置)。
    func terminateGroup(id groupID: String) -> KillReport {
        guard let group = allGroups.first(where: { $0.id == groupID }) else {
            return KillReport(outcomes: [])
        }
        return terminate(group.killTargets)
    }

    /// 一轮采样落地:菜单栏负载 + 出生登记、归组(纯逻辑在 GroupingPipeline),
    /// 同时构建下钻输入(快照 + 累计登记表 + 进程差分,同轮一致)。
    /// 出生扫描的登记表先并入——扫描间隙出生的短命父进程由此参与本轮归组。
    private func apply(_ update: SamplingUpdate) {
        systemCPULoad = update.systemCPULoad
        cpuBreakdown = update.cpu
        memory = update.memory
        pipeline.mergeBirths(birthLineage)
        pipeline.update(
            snapshot: update.snapshot,
            processCPU: update.diff.processCPU
        )
        allGroups = pipeline.allGroups
        // 采样历史(工单 P0.6-01)随同一轮推进:在场组追加,消失组逐出。
        history.advance(
            systemCPULoad: update.systemCPULoad,
            memoryUsedBytes: update.memory?.usedBytes,
            groups: allGroups.map { group in
                GroupSample(id: group.id, cpuPercent: group.cpuPercent, memoryBytes: group.memoryBytes)
            }
        )
        drilldown = DrilldownState(
            snapshot: update.snapshot,
            lineage: pipeline.lineage,
            processCPU: update.diff.processCPU
        )
    }

    /// 电池读数落地(工单 02):nil = 从未有过读数(无内建电池)→ 页面保持
    /// 隐藏;有读数即 hasBattery 置真(此后读失败交付 lastGood 同值重画,
    /// 不白屏不崩溃——driver 的 `snapshot() ?? lastGood` 交付口径)。
    private func applyBattery(_ reading: BatteryReading?) {
        guard let reading else { return }
        hasBattery = true
        battery = reading
    }
}
