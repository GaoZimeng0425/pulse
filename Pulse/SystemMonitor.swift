import Foundation
import Observation
import AppKit
import Darwin

/// 呈现层模型(spec 命名 SystemMonitor):持有采样管线,把每轮采样变成可观察状态。
/// 菜单栏数字 = 系统 CPU 负载(GLOSSARY:0–100%,每核 tick 口径,评审 S6);
/// 弹窗 = Top-5 组(组 CPU% 降序,系统组参榜)。
///
/// 主干(RoundSpine):每轮心跳并入出生登记 → 归组 → 下钻,产出一份 RoundContext,
/// 既有扇出与已注册的功能模块(MonitorFeature,ADR-0003 扩展点)同轮读同一份。
/// 采样 / 差分 / 归组 / 主干逻辑分别在 Sampler / CPUDiffer+CoreTickDiffer /
/// GroupingEngine / RoundSpine 里被单测覆盖;本类只做 MainActor 粘合与派发。
/// 装配(采集源 + 功能模块的构造)在工厂里(MonitorAssembly:`live` / `preview`)。
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
    /// (落库的历史管线是另一回事:功能模块 `history`。)
    private(set) var sampleHistory = SampleHistoryStore()
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
    /// 网络页读数(工单 06):当前速率 + 锁定的物理口名;读缺失轮保留上次
    /// 好值。首轮前 nil → 全占位。徽标槽位的网络速率也从这里取
    /// (`network?.rates`,09 壳契约的副本类型已并入 NetworkRates)。
    private(set) var network: NetworkRatesReading?
    /// 网络速率走势(工单 06):心跳轮逐轮推进的纯逻辑环,面积图数据源。
    private(set) var networkTrend = NetworkTrendBuffer()
    /// dev server 盘点(工单 08):每轮采样对 argv 命中的候选进程合成状态
    /// (闲置时长/内存/监听端口);无候选为空数组。主窗口总览页卡片读这里。
    private(set) var devServers: [DevServerStatus] = []
    /// 告警编排(工单 P1-07):每轮采样与磁盘容量读数喂进来,触发/恢复的
    /// 系统通知与应用内提示都由它出。设置页也读它(alerts.store)。
    let alerts: AlertCenter
    /// 模块排行(工单 module-rankings/01,MonitorFeature):电池/磁盘/网络三页的排行行
    /// 与主干同轮出,自带 nettop 传感器与采样成本闸门。主窗口排行卡直读这里。
    var rankings: RankingsFeature { features.rankings }
    /// 历史功能模块(工单 p1-history/03、04、06,ADR-0003):每轮落库(串行写入)、出生
    /// 登记回灌、网络 Today/7 天累计与历史页查询都在它那里。库打开失败(引擎缺席)
    /// 时整体降级,实时页不受影响。
    var history: HistoryFeature { features.history }

    private let sampler: Sampler
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
    /// 窗口可见性的两个信号(工单 module-rankings/01):弹窗在场与主窗口模块页在场;
    /// 值真变化时派发给功能模块(排行闸门在 RankingsFeature)。
    private var visibility = MonitorVisibility()
    /// 排行门控消息的代号(单调递增):Sampler 侧丢弃迟到的旧消息。
    @ObservationIgnored private var rankingsGateGeneration: UInt64 = 0
    /// 主干纯内核:出生登记(扫描 / 回灌并入 + 采样轮兜底)、归组配置与下钻
    /// 构建;每轮 apply 产出 RoundContext。
    private var spine: RoundSpine
    /// 功能模块(ADR-0003 扩展点):工厂构造后整份传入;每轮 onRound、可见性变化、
    /// 磁盘读数、传感器登记与启停都按 `registry` 顺序派发。组装接线,不参与观察。
    @ObservationIgnored private let features: MonitorFeatures
    /// dev server 盘点器(工单 08):闲置环状态随采样轮推进,端口扫描走缝。
    private var devServerFinder: DevServerFinder
    private let killService: any KillService
    private var samplingTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var sensorTask: Task<Void, Never>?
    private var started = false

    /// 依赖全部显式注入,无 Live 默认值(默认 `HistoryEngine.openDefault()` 曾让
    /// 测试 / 预览误连生产库,见 0c892c1)。真实装配 = `live(projectRoots:)`,
    /// 预览 = `preview(...)`(MonitorAssembly / InertSources)。
    /// 心跳中继在此构造:磁盘求和回退源经它取心跳那一趟 rusage
    /// (arch-review-2026-10-18/01 高2),中继与 Sampler 必须是同一个。
    init(
        sources: MonitorSources,
        projectRoots: [String],
        alerts: AlertCenter,
        features: MonitorFeatures
    ) {
        let heartbeatRelay = HeartbeatRusageRelay()
        self.sampler = Sampler(
            source: sources.process,
            coreTicks: sources.coreTicks,
            memoryStats: sources.memoryStats,
            networkCounters: sources.networkCounters,
            heartbeatRelay: heartbeatRelay
        )
        self.birthScanner = BirthScanner(source: sources.birthScan)
        self.batteryProvider = BatterySensorProvider(source: sources.battery)
        self.diskCapacityProvider = DiskCapacityProvider(source: sources.diskCapacity)
        self.diskThroughputProvider = DiskThroughputProvider(
            source: sources.diskThroughput(heartbeatRelay)
        )
        self.spine = RoundSpine(
            configuration: GroupingConfiguration(
                projectRoots: projectRoots,
                bundleDisplayName: BundleDisplayNameReader.shared.displayName
            )
        )
        self.killService = sources.killService
        self.devServerFinder = DevServerFinder(portScanner: sources.devServerPortScanner)
        self.alerts = alerts
        self.features = features
    }

    /// 启动采样循环(默认弹窗关闭节奏 5s)、独立出生扫描(~2s 节奏)与电池
    /// 传感器调度器(事件驱动):菜单栏数字与组卡从拉起就是真的,采样间隙
    /// 出生的短命父进程也留得下快照。幂等;由 UI 的 `.task` 触发。
    /// weak self:循环与 app 同寿命,不构成保留环。
    func start() {
        guard !started else { return }
        started = true
        observeWake()
        startBirthScan()
        startSampling()
        startSensors()
        // 通知授权:启动现查;规则开着而系统还没问过则补一次请求(AlertCenter)。
        Task { [weak self] in
            await self?.alerts.refreshAuthorization()
        }
        let host = makeHost()
        for feature in features.registry {
            feature.start(host)
        }
    }

    /// 唤醒处理(spec):差分基线清零——唤醒后第一轮作废,无巨大尖刺。
    /// 观察者与 app 同寿命,stop 时摘除。
    private func observeWake() {
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let sampler = self.sampler
            Task { await sampler.invalidateDeltas() }
        }
    }

    /// 出生扫描交付的累计登记表暂存进主干(整表替换),每轮采样落地时先并入
    /// (只补缺)——扫描间隙出生的短命父进程由此参与该轮归组。
    private func startBirthScan() {
        let scanner = birthScanner
        scanTask = Task { [weak self] in
            await scanner.run { [weak self] lineage in
                guard let self else { return }
                Task { @MainActor in
                    self.spine.stageScannerBirths(lineage)
                }
            }
        }
    }

    private func startSampling() {
        let sampler = self.sampler
        samplingTask = Task { [weak self] in
            await sampler.run { [weak self] update in
                guard let self else { return }
                Task { @MainActor in
                    self.apply(update)
                }
            }
        }
    }

    /// 非心跳型传感器(ADR-0004):单一调度器 actor 按 cadence 驱动——电池
    /// 事件档、磁盘容量 30s 低频档、磁盘吞吐 5s/30s 分档(工单 p1-history/05"调度器
    /// 体现分档"),心跳型仍住 Sampler 不登记;功能模块自有的传感器排在其后。
    private func startSensors() {
        let drivers = [
            batteryProvider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.applyBattery(reading) }
            },
            diskCapacityProvider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.applyDiskCapacity(reading) }
            },
            diskThroughputProvider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.applyDiskThroughput(reading) }
            },
        ] + features.registry.flatMap { $0.sensorDrivers() }
        let scheduler = SensorScheduler()
        sensorTask = Task {
            await scheduler.run(drivers)
        }
    }

    /// 功能模块回调主干 / 心跳的宿主接口(MonitorHost):回灌叠加进主干;排行门控
    /// 编代号后转给 Sampler。weak self:模块持有宿主,不构成保留环。
    private func makeHost() -> MonitorHost {
        MonitorHost(
            restoreBirths: { [weak self] restored in
                self?.spine.restoreBirths(restored)
            },
            setRankingsActive: { [weak self] active in
                guard let self else { return }
                rankingsGateGeneration &+= 1
                let generation = rankingsGateGeneration
                let sampler = self.sampler
                Task { await sampler.setRankingsActive(active, generation: generation) }
            }
        )
    }

    /// 停机(单测收尾用):取消采样 / 出生扫描 / 传感器调度三条循环(电池事件流
    /// 随之摘除 RunLoop source),停功能模块(历史收串行写入流),摘除唤醒观察者。产品运行期
    /// monitor 与 app 同寿命,从不调用;停机后不再重启(start 的幂等标记保持)。
    func stop() {
        samplingTask?.cancel()
        scanTask?.cancel()
        sensorTask?.cancel()
        for feature in features.registry {
            feature.stop()
        }
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    /// 弹窗可见性变化:采样节奏在 5s/1s 间切换(合盖省电,spec)。
    /// 出生扫描不受弹窗影响:登记的完整性不依赖观看。弹窗也是模块排行
    /// (工单 module-rankings/01)的可见性信号之一:弹窗在场即开闸(RankingsFeature.visibilityChanged)。
    func setPopoverVisible(_ visible: Bool) {
        updateVisibility(MonitorVisibility(popover: visible, moduleRankings: visibility.moduleRankings))
        let sampler = self.sampler
        Task { await sampler.setPopoverVisible(visible) }
    }

    /// 模块排行可见性变化(工单 01):主窗口模块页在场时由 UI 调用。与弹窗
    /// 信号合并门控——任一窗口可见即开闸,全关才停采(采样成本闸门)。
    func setModuleRankingsVisible(_ visible: Bool) {
        updateVisibility(MonitorVisibility(popover: visibility.popover, moduleRankings: visible))
    }

    /// 可见性落地:值真变化才派发给功能模块(MonitorFeature.visibilityChanged);
    /// 排行门控由 RankingsFeature 折算下发。
    private func updateVisibility(_ next: MonitorVisibility) {
        guard next != visibility else { return }
        visibility = next
        for feature in features.registry {
            feature.visibilityChanged(next)
        }
    }

    /// 项目根变更(工单 p0/07 设置窗):立即写入主干的归组配置,**下一轮采样即以
    /// 新根归组**(增删 ≤1 轮生效);清空列表 = 回到 03 的降级路径。传播逻辑在
    /// RoundSpineTests / GroupingPipelineTests"项目根热更新"用例单测,此处仅粘合。
    func setProjectRoots(_ roots: [String]) {
        spine.setProjectRoots(roots)
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

    /// 一轮采样落地:菜单栏负载 + 主干推进(出生登记 → 归组 → 下钻,纯逻辑在
    /// RoundSpine,同轮一致),再按既有扇出落地各项状态;最后把同一份上下文
    /// 派发给已注册的功能模块。外部登记(出生扫描 / 历史回灌)已随到随并入主干。
    private func apply(_ update: SamplingUpdate) {
        systemCPULoad = update.systemCPULoad
        cpuBreakdown = update.cpu
        memory = update.memory
        let context = spine.advance(update)
        allGroups = context.groups
        // 采样历史随同一轮推进:在场组追加,消失组逐出。组采样与历史落库同一个
        // 折算(GroupSample(group:),落库在历史模块的 onRound)。
        sampleHistory.advance(
            systemCPULoad: update.systemCPULoad,
            memoryUsedBytes: update.memory?.usedBytes,
            groups: allGroups.map(GroupSample.init(group:))
        )
        drilldown = context.drilldown
        // 网络心跳轮(工单 p1-history/06):速率/徽标/走势在 UI 粘合层落地;记账增量随同轮
        // 上下文由历史模块落库(HistoryFeature.onRound)。
        if let network = update.network {
            applyNetwork(network)
        }
        // 告警喂食(工单 P1-07):系统负载 + 全部组(引擎只读聚合口径,不持快照)。
        alerts.ingestSampling(
            systemCPULoad: update.systemCPULoad,
            groups: allGroups.map { group in
                AlertGroupSnapshot(
                    id: group.id,
                    name: group.name,
                    cpuPercent: group.cpuPercent,
                    memoryBytes: group.memoryBytes
                )
            }
        )
        // dev server 盘点(工单 08):argv 分类 → 候选进程闲置环 + 端口扫描;
        // 盘点时刻与快照同一时间轴(不另取钟),未闲置(nil)的 server 不喂告警。
        let cpuByPID = update.diff.processCPU.cpuPercentByPID
        let now = update.snapshot.takenAt
        devServers = devServerFinder.update(
            snapshot: update.snapshot,
            processCPU: cpuByPID,
            now: now
        )
        alerts.ingestDevServers(devServers.compactMap { server in
            server.idleSeconds.map {
                AlertDevServerSnapshot(pid: server.pid, name: server.displayName, idleSeconds: $0)
            }
        })
        // 功能模块(ADR-0003 扩展点):既有发布状态落定之后,同一份上下文按登记顺序派发。
        for feature in features.registry {
            feature.onRound(context)
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
        // 磁盘剩余规则喂食(工单 07):Finder「可用」口径;读不到不喂(不伪造)。
        if let available = reading.availableForImportantUsageBytes {
            alerts.ingestDisk(availableBytes: available)
        }
    }

    /// 磁盘吞吐读数落地(工单 p1-history/05):nil 首轮前保持占位,此后 lastGood 口径同上。
    /// 每份交付都派发给功能模块(历史记账的恰好一次由它的内核负责——HistoryFeed:
    /// 重投的同一读数不再记);展示侧同值不重画。
    private func applyDiskThroughput(_ reading: DiskThroughputReading?) {
        guard let reading else { return }
        for feature in features.registry {
            feature.diskThroughputDelivered(reading)
        }
        guard reading != diskThroughput else { return }
        diskThroughput = reading
    }

    /// 网络心跳轮落地(工单 06):速率读数 + 走势环推进。徽标直取
    /// `network?.rates`(09 壳契约副本已并入 NetworkRates)。
    /// 读缺失(nil)整轮跳过,保留上次好值(不回退为 nil、不白屏);
    /// 丢弃轮(首读/重连跳变/换口)速率如实为 0——菜单栏与图表都见谷底。
    private func applyNetwork(_ result: NetworkRoundResult) {
        network = NetworkRatesReading(rates: result.rates, interfaceName: result.interface)
        networkTrend.append(result.rates)
    }
}
