import Foundation
import Observation
import PulseCore

/// GPU 功能模块(工单 p2-sensors/02;ADR-0003 MonitorFeature):IORegistry
/// 传感器(ADR-0004;p2-review/06 起分档单循环)经 sensorDrivers 登记;GPU tab
/// 与弹窗 GPU 组直读 `reading` / `trend`。读失败交付上次好值(lastGood),不白屏。
@Observable
@MainActor
final class GpuFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义。
    private(set) var reading: GpuReading?
    /// 利用率走势环(最近 60 个样本,主卡走势图读这里);分档单循环
    /// (p2-review/06)后为混排节拍——可见 5s / 不可见 30s,窗长按样本数计。
    /// 关电归 0 与真 0 同记——走势如实反映"没在用"。
    private var ring = TrendRing<Double>(limit: 60)
    var trend: [Double] {
        ring.values
    }

    private let provider: GpuSensorProvider
    /// 广播出口(历史记账,08);start 前为 nil。
    @ObservationIgnored private var host: MonitorHost?

    init(source: any GpuSource, trendLimit: Int = 60) {
        provider = GpuSensorProvider(source: source)
        ring = TrendRing(limit: trendLimit)
    }

    func start(_ host: MonitorHost) {
        self.host = host
    }

    /// 分档单驱动(p2-review/06):一条循环两个节奏(可见 5s / 不可见 30s,
    /// provider.adaptiveInterval);历史广播由 HistoryThrottle 节流——每满 30s
    /// 放行一次,替代旧 30s 历史档驱动。
    func sensorDrivers() -> [SensorDriver] {
        let historyPass = HistoryThrottle(interval: 30)
        return [
            // 带新鲜度(stale 重投不灌走势环/不打脏观察,2026-10-23 审计④)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    self.apply(delivery)
                    if case let .fresh(reading) = delivery, historyPass.shouldPass() {
                        self.host?.broadcast(.gpuSample(.fresh(reading)))
                    }
                }
            },
        ]
    }

    /// GPU 采样闸:任一在场窗口停在展示 GPU 家族的 tab(总览的 GPU 卡 ∨ GPU 页,
    /// `MetricTab.displayedFamilies`,p2-review/05)——弹窗停在 CPU 等无 GPU 内容的
    /// tab 不再白采。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.shows(.gpu))
    }

    /// nil = 从未有过读数(无加速器)→ 卡片占位;首读前不追加走势。
    /// stale(读失败重投的 lastGood)整笔跳过:显示保留既有值(同一对象),
    /// 走势环不被旧值灌满,关窗期不逐 5s 打脏观察(审计④)。
    private func apply(_ delivery: SensorDelivery<GpuReading>?) {
        guard case let .fresh(reading) = delivery else { return }
        self.reading = reading
        ring.append(reading.utilizationPercent)
    }
}
