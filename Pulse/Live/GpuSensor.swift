import Foundation
import IOKit
import PulseCore

// 键名与防御口径移植自 stats(MIT)Modules/GPU/reader.swift(调研
// docs/research/sensor-impl-comparison.md §2.4;本机 2026-10-22 探针实证
// M4 三利用率键在场、字典无温度/频率键——GPU 温度归 SMC 家族,p2-sensors/04)。

// MARK: - Live GPU 源

/// Darwin 薄适配器:枚举 IORegistry `IOAccelerator` 条目,取第一个带
/// `PerformanceStatistics` 字典的条目(Apple Silicon 单 GPU;双 GPU 机器取
/// 排序首个,聚合口径 p2-sensors/03 随五路功率再议)。键提取在这里,值折算(钳位 /
/// AGC / 回退键序)在 PulseCore `GpuReading.make`——测试缝在协议上(ADR-0004)。
struct LiveGpuSource: GpuSource {
    func read() -> GpuRawReading? {
        var iterator: io_iterator_t = 0
        let matching: CFMutableDictionary = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service: io_object_t = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else { continue } // 无统计字典的条目跳过(stats :109-117 同款 continue)

            // AGCInfo 在条目顶层(reader.swift:205),不在统计字典里。
            let agcInfo = properties["AGCInfo"] as? [String: Int]
            return GpuRawReading(
                deviceUtilizationPercent: Self.doubleValue(statistics["Device Utilization %"]),
                gpuActivityPercent: Self.doubleValue(statistics["GPU Activity(%)"]),
                rendererUtilizationPercent: Self.doubleValue(statistics["Renderer Utilization %"]),
                tilerUtilizationPercent: Self.doubleValue(statistics["Tiler Utilization %"]),
                allocatedBytes: Self.intValue(statistics["Alloc system memory"]),
                inUseBytes: Self.intValue(statistics["In use system memory"]),
                modelName: properties["model"] as? String,
                coreCount: Self.intValue(properties["gpu-core-count"]),
                poweredOffByAGC: agcInfo?["poweredOffByAGC"] == 1
            )
        }
        return nil
    }

    /// 统计字典里的数值多为 CFNumber(偶有以其它数值型回报),统一走 NSNumber;
    /// 解不出 = nil,交给核心包的占位语义,不崩不伪造。
    private static func doubleValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

// MARK: - GPU 传感器 provider(p2-sensors/02,ADR-0004)

/// GPU 传感器:短档 `.every(seconds: 5)`(弹窗/主窗口 GPU 页可见时才读,
/// 门控挡住 IORegistry 调用;不可见交付 lastGood 不白屏——nettop 同款形状)。
/// 历史档(不可见 30s)随 p2-sensors/08 历史接线再上,本票先不空转。
final class GpuSensorProvider: SensorProvider {
    typealias Reading = GpuReading

    let cadence: SensorCadence = .every(seconds: 5)

    private let source: any GpuSource
    private let gate = SensorVisibilityGate()
    private let slot = SensorLastGoodBox<GpuReading>()

    var lastGood: GpuReading? {
        slot.current
    }

    init(source: any GpuSource = LiveGpuSource()) {
        self.source = source
    }

    /// 可见性切换(弹窗在场 ∨ 主窗口 GPU 页在场,GpuFeature 折算下发)。
    func setVisible(_ visible: Bool) {
        _ = gate.setVisible(visible)
    }

    func snapshot() async -> GpuReading? {
        guard gate.isVisible else { return nil }
        return await historySnapshot()
    }

    /// 历史档读(p2-sensors/08):不看可见性闸(30s 恒采喂库),lastGood 同槽。
    func historySnapshot() async -> GpuReading? {
        guard let raw = source.read() else { return nil }
        let reading = GpuReading.make(from: raw)
        slot.store(reading)
        return reading
    }
}
