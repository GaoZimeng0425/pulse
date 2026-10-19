import Foundation
import Observation
import Darwin

/// 模块排行功能模块(工单 01;ADR-0003 MonitorFeature):电池 / 磁盘 / 网络三页的
/// 「能耗影响 / 读写最多 / 每进程流量」三张只读榜。@Observable 薄壳 + 纯值核
/// RankingBoard(AlertCenter + AlertEngine 同款样板);视图直读 `energyRows /
/// diskRows / networkRows`,不在视图体里现场聚合。
///
/// 三路读数、一只组钟:
/// - 能耗(5s 窗)/ 磁盘(30s 窗)两本账本住 Sampler 心跳(票 A 高2),经 onRound 的
///   `context.update.rankings` 送达,满窗才出数;行与主干同轮的组一起出。
/// - 网络每进程是本模块自有的 nettop 传感器(ADR-0004,5s),经 sensorDrivers 登记进
///   SystemMonitor 的调度器;轮间交付按最新一轮的组重算网络行。
/// - 采样成本闸门(任一窗口可见才推进):visibilityChanged 折算 anyWindow,下发心跳
///   账本门控(注入的 setRankingsActive → Sampler)与 nettop 门控(门关不起子进程)。
///   翻转为关时两边各自清账,重开首轮只记基线不出数;已发布的行保留(不白屏)。
@Observable
@MainActor
final class RankingsFeature: MonitorFeature {
    /// 电池页·能耗影响行;首个满窗前为空。
    private(set) var energyRows: [ModuleRankingRow] = []
    /// 磁盘页·读写最多行;首个满窗前为空。
    private(set) var diskRows: [ModuleRankingRow] = []
    /// 网络页·每进程流量行;nettop 首次出数前为空。
    private(set) var networkRows: [ModuleRankingRow] = []

    /// 纯值核:最新一轮的组 + 三份最新读数。内部状态,不参与观察(发布走上面三张榜)。
    @ObservationIgnored private var board = RankingBoard()
    /// 网络每进程 provider(nettop 子进程 5s,门控在 provider 内部)。
    private let networkRateProvider: ProcessNetworkRateProvider
    /// 心跳账本门控(SystemMonitor 接到 `Sampler.setRankingsActive`;同值重复调用是 no-op)。
    private let setRankingsActive: @Sendable (Bool) async -> Void

    init(
        nettopSource: any NettopCSVSource,
        setRankingsActive: @escaping @Sendable (Bool) async -> Void
    ) {
        self.networkRateProvider = ProcessNetworkRateProvider(source: nettopSource)
        self.setRankingsActive = setRankingsActive
    }

    // MARK: - MonitorFeature

    /// 每轮心跳:组换新、满窗读数入账,三张榜按同轮的组重出。
    func onRound(_ context: RoundContext) {
        board.recordRound(groups: context.groups, rankings: context.update.rankings)
        publish(energy: board.energyRows, disk: board.diskRows)
        publish(network: board.networkRows)
    }

    /// 可见性 → 采样成本闸门:任一窗口可见即开闸,全关才停采。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        let active = visibility.anyWindow
        let setRankingsActive = self.setRankingsActive
        Task { await setRankingsActive(active) }
        networkRateProvider.setVisible(active)
    }

    /// nettop 登记项:调度器按 cadence 驱动,门关时 tick 在门口空转;交付在调度上下文,
    /// 跳回 MainActor 入账并按最新一轮的组重算网络行。
    func sensorDrivers() -> [SensorDriver] {
        [
            networkRateProvider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in
                    self.recordNetworkRates(reading)
                }
            },
        ]
    }

    // MARK: - 落地

    /// nil = 基线轮 / 读失败且从未有过好值 → 保留上次(RankingBoard 口径)。
    private func recordNetworkRates(_ reading: [pid_t: ProcessNetworkRates]?) {
        board.recordNetworkRates(reading)
        publish(network: board.networkRows)
    }

    /// 只在行真变化时写入(卡片不空转重画)。Swift 6.2+ 的 @Observable 宏对 Equatable
    /// 同值写入本已不通知(shouldNotifyObservers);显式比较让这条契约不依赖宏的版本。
    private func publish(energy: [ModuleRankingRow], disk: [ModuleRankingRow]) {
        if energy != energyRows { energyRows = energy }
        if disk != diskRows { diskRows = disk }
    }

    private func publish(network: [ModuleRankingRow]) {
        if network != networkRows { networkRows = network }
    }
}
