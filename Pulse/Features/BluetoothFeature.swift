import Foundation
import Observation
import PulseCore

/// 蓝牙功能模块(工单 p2-sensors/06;ADR-0003 MonitorFeature):三源电量合并
/// 传感器(ADR-0004,可见 30s 档 + 可见性门控,不可见完全停)经 sensorDrivers
/// 登记;外设 tab 蓝牙区与弹窗蓝牙紧凑组直读 `reading`。读失败交付上次好值。
@Observable
@MainActor
final class BluetoothFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义;nil = 从未读到(蓝牙栈不可用)→ 占位。
    private(set) var reading: BluetoothReading?

    private let provider: BluetoothSensorProvider

    init(source: any BluetoothSource) {
        provider = BluetoothSensorProvider(source: source)
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

    /// 蓝牙扫描闸:弹窗 ∨ 外设页(05 票立的 peripheralsPage 旗标在此消费;
    /// 与 GPU/传感器/排行闸分旗,ADR-0006 语义不混)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.popover || visibility.peripheralsPage)
    }
}
