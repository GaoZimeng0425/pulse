import Foundation
import Observation

/// 网络功能模块(工单 p1-history/06;ADR-0003 MonitorFeature):网络吞吐是心跳型
/// 读数(住 Sampler,ADR-0004),经 onRound 的 `context.update.network` 送达;本模块
/// 只落地速率读数与走势环。网络页与菜单栏徽标直读 `reading` / `trend`;记账增量随
/// 同一份上下文由历史模块落库。
@Observable
@MainActor
final class NetworkFeature: MonitorFeature {
    /// 当前速率 + 锁定的物理口名;读缺失轮保留上次好值。首轮前 nil → 全占位。
    /// 徽标槽位的网络速率也从这里取(`reading?.rates`)。
    private(set) var reading: NetworkRatesReading?
    /// 速率走势:心跳轮逐轮推进的纯逻辑环,面积图数据源。
    private(set) var trend = NetworkTrendBuffer()

    /// 读缺失(nil)整轮跳过,保留上次好值(不回退为 nil、不白屏);丢弃轮(首读 /
    /// 重连跳变 / 换口)速率如实为 0——菜单栏与图表都见谷底。
    func onRound(_ context: RoundContext) {
        guard let result = context.update.network else { return }
        reading = NetworkRatesReading(rates: result.rates, interfaceName: result.interface)
        trend.append(result.rates)
    }
}
