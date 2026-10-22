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

    init(source: any GpuSource, trendLimit: Int = 60) {
        provider = GpuSensorProvider(source: source)
        self.trendLimit = trendLimit
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            provider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.apply(reading) }
            },
        ]
    }

    /// GPU 采样闸:弹窗在场 ∨ 主窗口停在 GPU 页(旗标与排行闸刻意分立,
    /// MonitorVisibility.gpuPage 的文档注释,ADR-0006 语义不混)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.popover || visibility.gpuPage)
    }

    /// nil = 从未有过读数(无加速器)→ 卡片占位;首读前不追加走势。
    private func apply(_ reading: GpuReading?) {
        guard let reading else { return }
        self.reading = reading
        trend.append(reading.utilizationPercent)
        if trend.count > trendLimit {
            trend.removeFirst(trend.count - trendLimit)
        }
    }
}
