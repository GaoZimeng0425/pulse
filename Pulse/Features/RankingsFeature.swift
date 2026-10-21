import Darwin
import Foundation
import Observation
import PulseCore

/// 模块排行功能模块(工单 module-rankings/01;ADR-0003 MonitorFeature):电池 / 磁盘 / 网络三页的
/// 「能耗影响 / 读写最多 / 每进程流量」三张只读榜。@Observable 薄壳 + 纯值核
/// RankingBoard(AlertCenter + AlertEngine 同款样板);视图直读 `energyRows /
/// diskRows / networkRows`,不在视图体里现场聚合。
///
/// 三路读数、一只组钟:
/// - 能耗(5s 窗)/ 磁盘(30s 窗)两本账本住 Sampler 心跳(arch-review-2026-10-18/01 高2),经 onRound 的
///   `context.update.rankings` 送达,满窗才出数;行与主干同轮的组一起出。
/// - 网络每进程是本模块自有的 nettop 传感器(ADR-0004,5s),经 sensorDrivers 登记进
///   SystemMonitor 的调度器;轮间交付按最新一轮的组重算网络行。
/// - 采样成本闸门(任一窗口可见才推进):visibilityChanged 折算 anyWindow,下发心跳
///   账本门控(宿主 MonitorHost.setRankingsActive → Sampler)与 nettop 门控(门关不起
///   子进程)。翻转为关时两边各自清账,重开首轮只记基线不出数;已发布的行保留(不白屏)。
///   门关时照常记下每轮的组(只是换引用),但不重算三张榜——没人看;开门时按最新的组
///   重算一次。
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
    /// 宿主接口(start 时拿到):心跳账本门控经它下发。
    @ObservationIgnored private var host: MonitorHost?
    /// 闸门现值(任一窗口可见)。可见性可能早于 start 到达:先记下,start 时补发。
    @ObservationIgnored private var gateOpen = false

    init(nettopSource: any NettopCSVSource) {
        networkRateProvider = ProcessNetworkRateProvider(source: nettopSource)
    }

    // MARK: - MonitorFeature

    /// 每轮心跳:组换新、满窗读数入账;门开才按同轮的组重出三张榜。
    func onRound(_ context: RoundContext) {
        board.recordRound(groups: context.groups, rankings: context.update.rankings)
        guard gateOpen else { return }
        publishAll()
    }

    /// 可见性 → 采样成本闸门:任一窗口可见即开闸,全关才停采;开闸时重算一次。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        let active = visibility.anyWindow
        guard active != gateOpen else { return }
        gateOpen = active
        host?.setRankingsActive(active)
        networkRateProvider.setVisible(active)
        if active {
            publishAll()
        }
    }

    /// 拿到宿主接口;启动前闸门已开则当场补发(Sampler 初值为关)。
    func start(_ host: MonitorHost) {
        self.host = host
        if gateOpen {
            host.setRankingsActive(true)
        }
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
        guard gateOpen else { return }
        publish(network: board.networkRows)
    }

    private func publishAll() {
        publish(energy: board.energyRows, disk: board.diskRows)
        publish(network: board.networkRows)
    }

    /// 只在行真变化时写入(卡片不空转重画)。Swift 6.2+ 的 @Observable 宏对 Equatable
    /// 同值写入本已不通知(shouldNotifyObservers);显式比较让这条契约不依赖宏的版本。
    private func publish(energy: [ModuleRankingRow], disk: [ModuleRankingRow]) {
        if energy != energyRows {
            energyRows = energy
        }
        if disk != diskRows {
            diskRows = disk
        }
    }

    private func publish(network: [ModuleRankingRow]) {
        if network != networkRows {
            networkRows = network
        }
    }
}
