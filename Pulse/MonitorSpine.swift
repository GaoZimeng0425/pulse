import Foundation

// MARK: - 一轮心跳的共享上下文(主干产出)

/// 一轮心跳的共享上下文(主干 RoundSpine 产出):全部功能模块同轮读同一份——
/// 组、出生登记与下钻同轮同源,模块之间不再各自拼凑、互相错位一轮。
/// ADR-0003「每个服务以独立模块 + 小协议扩展点组织,经注册表组装」的数据面。
struct RoundContext: Sendable {
    /// 本轮心跳原始产出:快照 / 差分 / 系统负载 / 内存 / 网络 / 排行原始读数。
    let update: SamplingUpdate
    /// 本轮全部组(组 CPU% 降序;不截弹窗 displayLimit)。
    let groups: [ProcessGroup]
    /// 截至本轮累计的出生登记(外部并入 + 本轮快照兜底登记)。
    let lineage: LineageRegistry
    /// 下钻输入:与 groups 同轮同源(同一快照 + 同一登记表 + 同一差分)。
    let drilldown: DrilldownState

    /// 本轮采样时刻(快照时间轴):模块的盘点 / 闲置计时以它为准,不另取钟。
    var takenAt: Date { update.snapshot.takenAt }
}

// MARK: - 主干纯内核

/// 主干纯内核:每轮心跳「并入出生登记 → 归组 → 下钻」,产出 RoundContext。
/// 包住 GroupingPipeline(登记表 + 归组配置 + 引擎调用),只多做一件事:以同一
/// 快照、同一登记表、同一差分构建下钻输入。值类型,由 SystemMonitor(MainActor)
/// 持有;单测见 RoundSpineTests。
///
/// 出生登记三个来源:出生扫描的累计表经 `stageScannerBirths` 暂存、每次 advance
/// 开头并入,其后本轮快照兜底——这两个是本会话活记录,只补缺、先进者为准;历史
/// 回灌经 `restoreBirths` 即时叠加,与活记录同 pid 时按身份判别:同一进程取回灌
/// (重启保归因),pid 复用则活记录胜——与到达先后无关(规则钉在 RoundSpineTests)。
struct RoundSpine {
    private var pipeline: GroupingPipeline
    /// 出生扫描最近交付的累计登记表(整表替换):每次 advance 归组之前并入。
    private var scannerBirths = LineageRegistry()

    init(configuration: GroupingConfiguration) {
        pipeline = GroupingPipeline(configuration: configuration)
    }

    /// 即时叠加历史库回灌的出生登记:同 pid 按身份判别,pid 复用时活记录胜。
    mutating func restoreBirths(_ restored: LineageRegistry) {
        pipeline.restoreBirths(restored)
    }

    /// 暂存出生扫描最近交付的累计登记表(BirthScanner 每 ~2s 交付一份整表,只增
    /// 不删):整表替换,下一次 advance 归组之前并入(只补缺)——扫描间隙出生的
    /// 短命父进程由此参与该轮归组。
    mutating func stageScannerBirths(_ latest: LineageRegistry) {
        scannerBirths = latest
    }

    /// 更新项目根(设置窗,工单 p0/07):立即写入归组配置,下一次 advance 即以新根
    /// 归组(增删 ≤1 轮生效);清空列表 = 回到父链上溯的降级路径。
    mutating func setProjectRoots(_ roots: [String]) {
        pipeline.setProjectRoots(roots)
    }

    /// 推进一轮:并入暂存的扫描登记 → 本轮快照兜底登记出生 → 归组(全部组)
    /// → 同轮构建下钻。
    mutating func advance(_ update: SamplingUpdate) -> RoundContext {
        pipeline.mergeBirths(scannerBirths)
        let processCPU = update.diff.processCPU
        // 管线的返回值是弹窗 Top-N 截取;主干只要截取前的全部组。
        _ = pipeline.update(snapshot: update.snapshot, processCPU: processCPU)
        let lineage = pipeline.lineage
        return RoundContext(
            update: update,
            groups: pipeline.allGroups,
            lineage: lineage,
            drilldown: DrilldownState(
                snapshot: update.snapshot,
                lineage: lineage,
                processCPU: processCPU
            )
        )
    }
}

// MARK: - 功能模块扩展点(ADR-0003)

/// 窗口可见性:功能模块的采样成本闸门信号——弹窗在场 / 主窗口模块排行页在场。
/// 任一为真即「有窗口在看」(模块排行只在有人看时推进,工单 module-rankings/01)。
struct MonitorVisibility: Equatable, Sendable {
    var popover = false
    var moduleRankings = false

    /// 任一窗口可见。
    var anyWindow: Bool { popover || moduleRankings }
}

/// 功能模块回调主干 / 心跳的明确接口(SystemMonitor.start 时交给每个模块):模块
/// 构造只吃自己的采集源,对主干与心跳的影响只经这两个口——装配因此可以挪到工厂
/// (`SystemMonitor.live` / `preview`),不必在 SystemMonitor.init 里两段式接线。
@MainActor
struct MonitorHost {
    /// 叠加历史库回灌的出生登记进主干(RoundSpine.restoreBirths)。
    let restoreBirths: (LineageRegistry) -> Void
    /// 心跳排行账本门控(Sampler.setRankingsActive):宿主给每条消息编代号,
    /// 迟到的旧消息在 Sampler 侧丢弃。
    let setRankingsActive: (Bool) -> Void
    /// 模块间广播:同步派发给全部功能模块的 onEvent(含发出者自己,按注册顺序)。
    let broadcast: (FeatureEvent) -> Void

    /// 全不接线的宿主(单测直驱模块用)。
    static let inert = MonitorHost(
        restoreBirths: { _ in },
        setRankingsActive: { _ in },
        broadcast: { _ in }
    )
}

/// 功能模块之间的广播事件:一个模块的产出是另一个模块的输入时走这里(磁盘读数 →
/// 历史记账 / 磁盘告警;dev server 盘点 → 闲置告警),模块之间不互相持有引用。
enum FeatureEvent {
    /// 磁盘吞吐交付(DiskFeature;带新鲜度,记账只认 fresh)。
    case diskThroughput(SensorDelivery<DiskThroughputReading>)
    /// 磁盘容量交付(DiskFeature;读失败时为重投的上次好值)。
    case diskCapacity(DiskCapacityReading)
    /// 本轮 dev server 盘点(DevServerFeature,每轮一次)。
    case devServers([DevServerStatus])
}

/// 功能模块扩展点(ADR-0003 预约「每个服务以独立模块 + 小协议扩展点组织,经注册表
/// 组装」,此处兑现):每个功能(历史 / 告警 / 排行 / dev server / 网络 / 磁盘 / 电池,
/// 及 P2 传感器)= @Observable 薄壳 + 纯值内核(AlertCenter + AlertEngine 即样板),
/// 由工厂构造、经 MonitorFeatures 注册列表交给 SystemMonitor;视图直读模块自身状态。
/// 编译期模块,不是运行时插件(ADR-0003)。钩子都有默认空实现,模块只实现自己关心的。
@MainActor
protocol MonitorFeature: AnyObject {
    /// 每轮心跳落地(SystemMonitor 的既有发布状态已更新为同一轮之后):主干产出的
    /// 同轮上下文;模块据此推进自身状态、执行自身效果(落库 / 告警 / 通知)。
    func onRound(_ context: RoundContext)
    /// 窗口可见性变化:值真变化才派发(同值重复调用不派发);初值为全不可见,
    /// 可能早于 start 到达。
    func visibilityChanged(_ visibility: MonitorVisibility)
    /// 其他模块的广播(MonitorHost.broadcast);模块只 switch 自己关心的事件。
    func onEvent(_ event: FeatureEvent)
    /// 项目根:SystemMonitor.start 时(模块 start 之后)派发一次当前值,此后每次在设置里
    /// 改根再派发(历史模块据此迁移组身份,arch-review-2026-10-18/03 乙3)。
    func projectRootsChanged(_ roots: [String])
    /// 本模块自有的非心跳传感器(ADR-0004 SensorScheduler 登记项):SystemMonitor.start
    /// 时取一次,与既有传感器同一个调度器驱动。心跳型读数不走这里(住 Sampler,
    /// 经 onRound 的 `context.update` 送达)。
    func sensorDrivers() -> [SensorDriver]
    /// 随 SystemMonitor.start 启动一次(start 幂等,模块不会被启动两次),同时拿到
    /// 回调主干 / 心跳的宿主接口。
    func start(_ host: MonitorHost)
    /// 随 SystemMonitor.stop 停机一次(单测收尾;产品运行期不调用)。
    func stop()
}

extension MonitorFeature {
    func onRound(_ context: RoundContext) {}
    func visibilityChanged(_ visibility: MonitorVisibility) {}
    func onEvent(_ event: FeatureEvent) {}
    func projectRootsChanged(_ roots: [String]) {}
    func sensorDrivers() -> [SensorDriver] { [] }
    func start(_ host: MonitorHost) {}
    func stop() {}
}
