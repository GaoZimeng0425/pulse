import Foundation
import Observation
import PulseCore

/// 五路功率功能模块(工单 p2-sensors/03;ADR-0003 MonitorFeature):Energy Model
/// 传感器(ADR-0004;p2-review/06 起分档单循环,与 GPU 同门控)经 sensorDrivers
/// 登记;GPU 页的 ANE 卡与五路功率区直读 `reading` / `aneTrend` / `aneNormalizedPercent`。
/// 读失败交付上次好值(lastGood),不白屏。
@Observable
@MainActor
final class PowerFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义;首读/断档轮不交读数(未首读前为 nil 占位)。
    private(set) var reading: PowerReading?
    /// ANE 瓦数走势环(最近 60 个样本;分档单循环 p2-review/06 后为混排节拍,
    /// 可见 5s / 不可见 30s,窗长按样本数计)。
    private var aneRing = TrendRing<Double>(limit: 60)
    var aneTrend: [Double] {
        aneRing.values
    }

    /// 芯片名(ANE 归一化表的键源,装配时注入)。
    private let chipName: String
    private let provider: EnergyModelSensorProvider
    /// 广播出口(历史记账,08);start 前为 nil。
    @ObservationIgnored private var host: MonitorHost?

    init(source: any PowerSource, chipName: String, trendLimit: Int = 60) {
        provider = EnergyModelSensorProvider(source: source)
        self.chipName = chipName
        aneRing = TrendRing(limit: trendLimit)
    }

    /// ANE 归一化百分比(M4 = 6.0W 上限,stats 表);未首读或 ANE 通道缺席为 nil
    /// (占位,不伪造 0——p2-review/01 ④)。
    var aneNormalizedPercent: Double? {
        reading?.watts[.ane].map { AnePowerCap.normalizedPercent(watts: $0, chipName: chipName) }
    }

    func start(_ host: MonitorHost) {
        self.host = host
    }

    /// 分档单驱动(p2-review/06):一条循环两个节奏(可见 5s / 不可见 30s);
    /// 历史广播 HistoryThrottle 节流,每满 30s 放行一次——差分窗 = 实测时差,
    /// 旧双档"可见期历史档只拿到最近 5s 窗"的口径问题就此根治。
    func sensorDrivers() -> [SensorDriver] {
        let historyPass = HistoryThrottle(interval: 30)
        return [
            // 带新鲜度:stale 重投不灌 ANE 走势环/不打脏观察(审计④)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    self.apply(delivery)
                    if case let .fresh(reading) = delivery, historyPass.shouldPass() {
                        self.host?.broadcast(.powerSample(.fresh(reading)))
                    }
                }
            },
        ]
    }

    /// 功率采样闸:ANE 卡与五路功率只在 GPU 页展示(`displayedFamilies`,
    /// p2-review/05;总览的 GPU 卡只吃利用率,不消费功率家族)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.shows(.power))
    }

    /// nil = 从未有过读数(订阅缺席 / 组不在)→ ANE 卡与功率区占位。
    /// stale(读失败重投的 lastGood)整笔跳过:显示保留既有值,走势环不被
    /// 旧值灌满(审计④)。
    private func apply(_ delivery: SensorDelivery<PowerReading>?) {
        guard case let .fresh(reading) = delivery else { return }
        self.reading = reading
        // ANE 缺席不追加:走势只画真读数(p2-review/01 ④)。
        guard let aneWatts = reading.watts[.ane] else { return }
        aneRing.append(aneWatts)
    }
}
