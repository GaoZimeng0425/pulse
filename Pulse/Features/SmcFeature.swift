import Foundation
import Observation
import PulseCore

/// SMC 传感器功能模块(工单 p2-sensors/04;ADR-0003 MonitorFeature):AppleSMC
/// 传感器(ADR-0004,5s 档,可见性门控)经 sensorDrivers 登记;传感器 tab 的
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

    func sensorDrivers() -> [SensorDriver] {
        let provider = provider
        let historyDriver = SensorDriver(
            cadence: .every(seconds: 30),
            tick: { [weak self] in
                guard let self else { return }
                if let reading = await provider.historySnapshot() {
                    Task { @MainActor in
                        self.host?.broadcast(.smcSample(.fresh(reading)))
                    }
                }
            },
            wakeups: nil,
            label: "SMC历史档"
        )
        return [
            // UI 档带新鲜度:stale 重投整笔跳过,关窗期不逐 5s 打脏观察(审计④)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    guard case let .fresh(reading) = delivery else { return }
                    self.reading = reading
                }
            },
            historyDriver,
        ]
    }

    /// SMC 采样闸:弹窗 ∨ 传感器页(与 GPU/排行闸分旗,ADR-0006 语义不混)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.popover || visibility.sensorsPage)
    }
}
