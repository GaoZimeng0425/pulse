import Foundation
import Observation
import PulseCore

/// 五路功率功能模块(工单 p2-sensors/03;ADR-0003 MonitorFeature):Energy Model
/// 传感器(ADR-0004,5s 档,与 GPU 同门控)经 sensorDrivers 登记;GPU 页的 ANE 卡
/// 与五路功率区直读 `reading` / `aneTrend` / `aneNormalizedPercent`。
/// 读失败交付上次好值(lastGood),不白屏。
@Observable
@MainActor
final class PowerFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义;首读/断档轮 = 在场域全 0(不是 nil)。
    private(set) var reading: PowerReading?
    /// ANE 瓦数走势环(~60 点 × 5s 档 ≈ 5 分钟窗)。
    private(set) var aneTrend: [Double] = []

    /// 走势环上限(SampleHistory/GpuFeature 同款窗口量级)。
    private let trendLimit: Int
    /// 芯片名(ANE 归一化表的键源,装配时注入)。
    private let chipName: String
    private let provider: EnergyModelSensorProvider
    /// 广播出口(历史记账,08);start 前为 nil。
    @ObservationIgnored private var host: MonitorHost?

    init(source: any PowerSource, chipName: String, trendLimit: Int = 60) {
        provider = EnergyModelSensorProvider(source: source)
        self.chipName = chipName
        self.trendLimit = trendLimit
    }

    /// ANE 归一化百分比(M4 = 6.0W 上限,stats 表);未首读为 nil(占位)。
    var aneNormalizedPercent: Double? {
        reading.map { AnePowerCap.normalizedPercent(watts: $0.watts[.ane] ?? 0, chipName: chipName) }
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
                        self.host?.broadcast(.powerSample(.fresh(reading)))
                    }
                }
            },
            wakeups: nil,
            label: "功率历史档"
        )
        return [
            provider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.apply(reading) }
            },
            historyDriver,
        ]
    }

    /// 功率采样闸:与 GPU 传感同门控(弹窗 ∨ GPU 页,GLOSSARY「五路功率」数据
    /// 全部消费在 GPU 页)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.popover || visibility.gpuPage)
    }

    /// nil = 从未有过读数(订阅缺席 / 组不在)→ ANE 卡与功率区占位。
    private func apply(_ reading: PowerReading?) {
        guard let reading else { return }
        self.reading = reading
        aneTrend.append(reading.watts[.ane] ?? 0)
        if aneTrend.count > trendLimit {
            aneTrend.removeFirst(aneTrend.count - trendLimit)
        }
    }
}
