import Foundation
import Observation
import PulseCore

/// 声音功能模块(工单 p2-sensors/05;ADR-0003 MonitorFeature):CoreAudio
/// 传感器(ADR-0004,`.onEvent` 事件档——设备/属性变更通知,零轮询)经
/// sensorDrivers 登记;外设 tab 声音区与弹窗声音紧凑组直读 `reading`。
/// 读失败交付上次好值(lastGood)。事件稀少且便宜,刻意不设可见性闸
/// (MonitorVisibility 有 peripheralsPage 旗标,但消费方是 p2-sensors/06 的蓝牙)。
@Observable
@MainActor
final class SoundFeature: MonitorFeature {
    /// 最近一次交付,LastGood 语义;nil = 从未有过读数(无输出设备)→ 占位。
    private(set) var reading: SoundReading?

    private let provider: SoundSensorProvider

    init(source: any SoundSource) {
        provider = SoundSensorProvider(source: source)
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
}
