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

    init(source: any SmcSource) {
        provider = SmcSensorProvider(source: source)
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            provider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in
                    guard let reading else { return }
                    self.reading = reading
                }
            },
        ]
    }

    /// SMC 采样闸:弹窗 ∨ 传感器页(与 GPU/排行闸分旗,ADR-0006 语义不混)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.popover || visibility.sensorsPage)
    }
}
