import Foundation
import Observation
import PulseCore

/// GPU 功能模块(工单 p2-sensors/02;ADR-0003 MonitorFeature):IORegistry
/// 传感器(ADR-0004,5s 档 + 可见性门控)经 sensorDrivers 登记;GPU tab 与弹窗
/// GPU 组直读 `reading` / `trend`。读失败交付上次好值(lastGood),不白屏。
@Observable
@MainActor
final class GpuFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义。
    private(set) var reading: GpuReading?
    /// 利用率走势环(~60 点 × 5s 档 ≈ 5 分钟窗),主卡走势图读这里;
    /// 关电归 0 与真 0 同记——走势如实反映"没在用"。
    private(set) var trend: [Double] = []

    /// 走势环上限(SampleHistory 同款窗口量级)。
    private let trendLimit: Int
    private let provider: GpuSensorProvider
    /// 广播出口(历史记账,08);start 前为 nil。
    @ObservationIgnored private var host: MonitorHost?

    init(source: any GpuSource, trendLimit: Int = 60) {
        provider = GpuSensorProvider(source: source)
        self.trendLimit = trendLimit
    }

    func start(_ host: MonitorHost) {
        self.host = host
    }

    func sensorDrivers() -> [SensorDriver] {
        let provider = provider
        let historyDriver = SensorDriver(
            cadence: .every(seconds: 30),
            tick: { [weak self] in
                guard let self else { return }
                if let reading = await provider.historySnapshot() {
                    Task { @MainActor in
                        self.host?.broadcast(.gpuSample(.fresh(reading)))
                    }
                }
            },
            wakeups: nil,
            label: "GPU历史档"
        )
        return [
            // UI 档带新鲜度(stale 重投不灌走势环/不打脏观察——门关期间调度器
            // 每 5s 重投 lastGood,2026-10-23 审计④:此前走势环被同一旧值灌满)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in self.apply(delivery) }
            },
            historyDriver,
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
        trend.append(reading.utilizationPercent)
        if trend.count > trendLimit {
            trend.removeFirst(trend.count - trendLimit)
        }
    }
}
