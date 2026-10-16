import Foundation
import Observation
import AppKit
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
    /// 磁盘容量读数(工单 05):容器对账 + 可清除 + 各卷 + 快照,低频档(30s)
    /// 交付;首轮前 nil → 卡片全占位(磁盘页常驻轴,无电池页的隐藏问题)。
    private(set) var diskCapacity: DiskCapacityReading?
    /// 磁盘吞吐读数(工单 05):系统级读写速率 + 走势,短档(5s)或回退档
    /// (30s,随源路径)交付;首轮前 nil → 速率列占位。
    private(set) var diskThroughput: DiskThroughputReading?
    /// 网络速率读数(**工单 09 预留的徽标壳契约,字段由工单 06 填充**):
    /// 网络卡传感器落地时把读数写到此处——类型若与 NetworkRateReading 不同,
    /// 在落地处转换即可(徽标只消费上/下行字节速率两个字段)。填充前恒 nil,
    /// 菜单栏网络槽位显示占位"—",不伪造。
    private(set) var networkRate: NetworkRateReading?

    private let sampler: Sampler
    /// 历史引擎(工单 03):5s 采样经它卷积落库 + 出生登记持久化 + 唤醒清基线。
    /// 库打开失败时为 nil(已记日志),历史降级缺席,实时页不受影响。
    private let historyEngine: HistoryEngine?
    /// 唤醒通知观察者(与 app 同寿命,start 建立一次;monitor 是 app 唯一的
    /// @State 管线持有者,观察者随进程结束——闭包 weak self,无保留环,
    /// deinit 属非隔离上下文,不做摘除)。
    private var wakeObserver: NSObjectProtocol?
    /// 独立出生扫描(评审 S1):~2s 节奏登记新 pid,与采样节奏解耦。
    private let birthScanner: BirthScanner
    /// 电池传感器(工单 02,ADR-0004 第一个真 provider):事件驱动,IOPS 通知。
    private let batteryProvider: BatterySensorProvider
    /// 磁盘容量传感器(工单 05,ADR-0004):低频档 30s,不进 1s 心跳。
    private let diskCapacityProvider: DiskCapacityProvider
    /// 磁盘吞吐传感器(工单 05,ADR-0004):短档 5s(IORegistry 主路径)或
    /// 低频档 30s(rusage 回退),节奏随源路径在构造期钉死。
    private let diskThroughputProvider: DiskThroughputProvider
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
        historyEngine: HistoryEngine? = HistoryEngine.openDefault(),
        batterySource: any BatterySource = LiveBatterySource(),
        diskCapacitySource: any DiskCapacitySource = LiveDiskCapacitySource(),
        diskThroughputSource: any DiskThroughputSource = LiveDiskThroughputSource.adoptingBestPath()
    ) {
        self.sampler = Sampler(source: source, coreTicks: coreTicks, memoryStats: memoryStats)
        self.historyEngine = historyEngine
        self.birthScanner = BirthScanner(source: birthScanSource)
        self.batteryProvider = BatterySensorProvider(source: batterySource)
        self.diskCapacityProvider = DiskCapacityProvider(source: diskCapacitySource)
        self.diskThroughputProvider = DiskThroughputProvider(source: diskThroughputSource)
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
        // 出生登记回灌(工单 03):库中既往登记并入管线——重启后,此前归到
        // 宿主的断链进程仍归原宿主(验收锚点①先半)。合并只补缺,与扫描
        // /采样轮的登记互不覆盖;身份字段进程终身不变,先后无差。
        if let historyEngine {
            let engine = historyEngine
            Task { [weak self] in
                let restored = await engine.importLineage()
                guard let self else { return }
                self.pipeline.mergeBirths(restored)
            }
        }
        // 唤醒处理(spec):差分基线清零——唤醒后第一轮作废,无巨大尖刺。
        // 观察者与 app 同寿命,随 monitor 释放移除。
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let sampler = self.sampler
            Task { await sampler.invalidateDeltas() }
        }
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
        // 非心跳型传感器(ADR-0004):单一调度器 actor 按 cadence 驱动——电池
        // 事件档、磁盘容量 30s 低频档、磁盘吞吐 5s/30s 分档(工单 05"调度器
        // 体现分档"),心跳型仍住 Sampler 不登记。
        let capacityProvider = diskCapacityProvider
        let throughputProvider = diskThroughputProvider
        let provider = batteryProvider
        let scheduler = SensorScheduler()
        sensorTask = Task { [weak self] in
            await scheduler.run([
                provider.driver { [weak self] reading in
                    guard let self else { return }
                    Task { @MainActor in
                        self.applyBattery(reading)
                    }
                },
                capacityProvider.driver { [weak self] reading in
                    guard let self else { return }
                    Task { @MainActor in
                        self.applyDiskCapacity(reading)
                    }
                },
                throughputProvider.driver { [weak self] reading in
                    guard let self else { return }
                    Task { @MainActor in
                        self.applyDiskThroughput(reading)
                    }
                },
            ])
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

    /// 诊断报告取数(工单 11):按需向采样器要一份累计统计快照
    /// (运行起点/轮数/均值/峰值),不做常驻观察。
    func samplingStats() async -> SamplingStats {
        let sampler = self.sampler
        return await sampler.samplingStats()
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
    func terminateGroup(id groupID: GroupIdentity) -> KillReport {
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
        // 组采样快照:内存环形缓冲(工单 P0.6-01)与历史落库(工单 03)同一份形状。
        let groupSamples = allGroups.map { group in
            GroupSample(
                id: group.id,
                cpuPercent: group.cpuPercent,
                memoryBytes: group.memoryBytes,
                processCount: group.processes.count
            )
        }
        // 采样历史随同一轮推进:在场组追加,消失组逐出。
        history.advance(
            systemCPULoad: update.systemCPULoad,
            memoryUsedBytes: update.memory?.usedBytes,
            groups: groupSamples
        )
        drilldown = DrilldownState(
            snapshot: update.snapshot,
            lineage: pipeline.lineage,
            processCPU: update.diff.processCPU
        )
        // 历史管线(工单 03):5s 原始值只进引擎的内存缓冲,分钟卷积 / 小时卷积 /
        // 留存清理 / 出生登记与组元数据落库都在引擎侧一个事务完成;旁路失败只记日志。
        // 采样时刻在 MainActor 上现取(Task 外),顺序即 apply 顺序。
        if let historyEngine {
            let engine = historyEngine
            let now = Date()
            let displayNames = Dictionary(
                allGroups.map { ($0.id, $0.name) },
                uniquingKeysWith: { _, rhs in rhs }
            )
            let lineage = pipeline.lineage
            Task {
                await engine.ingest(
                    at: now,
                    systemLoad: update.systemCPULoad,
                    groups: groupSamples,
                    displayNames: displayNames,
                    lineage: lineage
                )
            }
        }
    }

    /// 电池读数落地(工单 02):nil = 从未有过读数(无内建电池)→ 页面保持
    /// 隐藏;有读数即 hasBattery 置真(此后读失败交付 lastGood 同值重画,
    /// 不白屏不崩溃——driver 的 `snapshot() ?? lastGood` 交付口径)。
    private func applyBattery(_ reading: BatteryReading?) {
        guard let reading else { return }
        hasBattery = true
        battery = reading
    }

    /// 磁盘容量读数落地(工单 05):nil = 从未有过读数(非 APFS 系统/首轮前)
    /// → 保持占位;读失败交付 lastGood 同值重画(driver 口径),不回退为 nil。
    private func applyDiskCapacity(_ reading: DiskCapacityReading?) {
        guard let reading else { return }
        diskCapacity = reading
    }

    /// 磁盘吞吐读数落地(工单 05):nil 首轮前保持占位,此后 lastGood 口径同上。
    private func applyDiskThroughput(_ reading: DiskThroughputReading?) {
        guard let reading else { return }
        diskThroughput = reading
    }
}
