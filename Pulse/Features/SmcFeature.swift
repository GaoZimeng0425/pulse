import Foundation
import Observation
import PulseCore

/// SMC 传感器功能模块(工单 p2-sensors/04;ADR-0003 MonitorFeature):AppleSMC
/// 传感器(ADR-0004;p2-review/06 起分档单循环)经 sensorDrivers 登记;传感器 tab 的
/// 派生值/明细/风扇与弹窗温度组直读 `reading`。读失败交付上次好值(lastGood)。
@Observable
@MainActor
final class SmcFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义;nil = 无 SMC / 从未读到(整页占位)。
    private(set) var reading: SmcReading?

    private let provider: SmcSensorProvider
    /// 广播出口(历史记账,08);start 前为 nil。
    @ObservationIgnored private var host: MonitorHost?

    init(source: any SmcSource) {
        provider = SmcSensorProvider(source: source)
    }

    func start(_ host: MonitorHost) {
        self.host = host
    }

    /// 分档单驱动(p2-review/06):一条循环两个节奏(可见 5s / 不可见 30s);
    /// 历史广播 HistoryThrottle 节流,每满 30s 放行一次。
    func sensorDrivers() -> [SensorDriver] {
        let historyPass = HistoryThrottle(interval: SensorTier.history)
        return [
            // 带新鲜度:stale 重投整笔跳过,不打脏观察(审计④)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    guard case let .fresh(reading) = delivery else { return }
                    self.reading = reading
                    if historyPass.shouldPass() {
                        self.host?.broadcast(.gauges(reading.historyGauges))
                    }
                }
            },
        ]
    }

    /// SMC 采样闸:任一在场窗口停在传感器 tab(`displayedFamilies`,p2-review/05)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.shows(.smc))
    }
}
