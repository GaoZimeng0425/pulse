import Foundation
import Observation
import PulseCore

/// 容器功能模块(工单 p2-sensors/07;ADR-0003 MonitorFeature):docker.sock
/// 传感器(ADR-0004,可见 30s 档 + 可见性门控,不可见完全停)经 sensorDrivers
/// 登记;容器 tab 与弹窗容器紧凑组直读 `reading`。读失败交付上次好值;
/// 引擎缺席 = engineReachable false 的空表(安静空态)。
@Observable
@MainActor
final class ContainerFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义;nil = 从未读到(首读前占位)。
    private(set) var reading: ContainersReading?

    private let provider: ContainerSensorProvider

    init(source: any ContainerSource) {
        provider = ContainerSensorProvider(source: source)
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            // 带新鲜度:stale 重投跳过(读失败保显示 = 字段已持旧值,审计④)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    guard case let .fresh(reading) = delivery else { return }
                    self.reading = reading
                }
            },
        ]
    }

    /// 容器采样闸:弹窗 ∨ 容器页(一族一旗,ADR-0006 语义不混)。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.popover || visibility.containersPage)
    }
}
