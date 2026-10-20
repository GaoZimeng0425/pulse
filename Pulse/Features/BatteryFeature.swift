import Foundation
import Observation
import PulseCore

/// 电池功能模块(工单 p1-history/02;ADR-0003 MonitorFeature):事件驱动的电池
/// 传感器(IOPS 通知,ADR-0004 第一个真 provider)经 sensorDrivers 登记;弹窗与
/// 主窗口的电池 tab 直读 `reading` / `hasBattery`。
@Observable
@MainActor
final class BatteryFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义——读失败交付上次好值,不回退为 nil、不白屏。
    private(set) var reading: BatteryReading?
    /// 本机有内建电池:首次成功读数置真,电池 tab 随之入轴;台式机永无交付 →
    /// 恒假,电池页整页隐藏。只翻真不翻假。
    private(set) var hasBattery = false

    private let provider: BatterySensorProvider

    init(source: any BatterySource) {
        self.provider = BatterySensorProvider(source: source)
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            provider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.apply(reading) }
            },
        ]
    }

    /// nil = 从未有过读数(无内建电池)→ 页面保持隐藏。
    private func apply(_ reading: BatteryReading?) {
        guard let reading else { return }
        hasBattery = true
        self.reading = reading
    }
}
