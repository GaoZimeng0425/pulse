import Foundation
import PulseCore

// Energy Model 订阅/采样路径移植自 stats(MIT)Modules/GPU/reader.swift:314-377
// (调研 docs/research/sensor-impl-comparison.md §2.5;探针④ 2026-10-22 实证
// macOS 26 的 CopyChannelsInGroup 返回 {QueryOpts, IOReportChannels} 响应字典,
// stats 本就按字典处理——整份响应字典原样传给 CreateSubscription,采样回包
// 再从 IOReportChannels 取通道数组)。IOReport 无 SDK 公开头,手工 @_silgen_name
// 声明 + 链 /usr/lib/libIOReport.dylib(探针④同款做法)。

// MARK: - IOReport C 接口(无公开头;符号在 libIOReport.tbd 全量在场)

@_silgen_name("IOReportCopyChannelsInGroup")
private func iorCopyChannelsInGroup(
    _ group: CFString,
    _ filter: CFString?,
    _ flags: UInt64,
    _ channelTag: UInt64,
    _ destination: UnsafeMutableRawPointer?
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSubscription")
private func iorCreateSubscription(
    _ allocator: CFAllocator?,
    _ channels: CFMutableDictionary,
    _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
    _ flags: UInt64,
    _ destination: UnsafeMutableRawPointer?
) -> OpaquePointer?

@_silgen_name("IOReportCreateSamples")
private func iorCreateSamples(
    _ subscription: OpaquePointer?,
    _ channels: CFMutableDictionary,
    _ destination: UnsafeMutableRawPointer?
) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetGroup")
private func iorChannelGroup(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetChannelName")
private func iorChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetUnitLabel")
private func iorChannelUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportSimpleGetIntegerValue")
private func iorSimpleIntegerValue(_ channel: CFDictionary, _ index: Int32) -> Int64

@_silgen_name("CFDictionaryCreateMutableCopy")
private func cfDictionaryCreateMutableCopy(
    _ allocator: CFAllocator?,
    _ capacity: CFIndex,
    _ theDict: CFDictionary
) -> Unmanaged<CFMutableDictionary>?

// MARK: - Live Energy Model 源

/// Darwin 薄适配器:持有 "Energy Model" 组的订阅(懒建一次,失败下轮重试),
/// 每次读 = 一次采样,交回**全部通道**的 (名, 单位标签, 整数读数) 原始载荷——
/// 通道名 → 域的映射与单位换算是纯逻辑,住核心包(PowerModel)。
/// @unchecked Sendable:订阅与通道字典不是 Sendable;调度由 SensorScheduler
/// 单 actor 串行驱动(净top provider 同款纪律),无并发访问。
final class LiveEnergyModelSource: PowerSource, @unchecked Sendable {
    private var channelList: CFMutableDictionary?
    private var subscription: OpaquePointer?

    func read() -> PowerRawReading? {
        ensureSubscription()
        guard let subscription, let channelList,
              let sample = iorCreateSamples(subscription, channelList, nil)?.takeRetainedValue(),
              let sampleDict = sample as? [String: Any],
              let channels = sampleDict["IOReportChannels"] as? NSArray
        else { return nil }

        var samples: [PowerChannelSample] = []
        for case let item as CFDictionary in channels {
            guard
                let group = iorChannelGroup(item)?.takeUnretainedValue() as String?,
                group == "Energy Model",
                let name = iorChannelName(item)?.takeUnretainedValue() as String?
            else { continue }
            let unit = iorChannelUnitLabel(item)?.takeUnretainedValue() as String? ?? ""
            samples.append(
                PowerChannelSample(name: name, unitLabel: unit, rawValue: Double(iorSimpleIntegerValue(item, 0)))
            )
        }
        guard !samples.isEmpty else { return nil }
        return PowerRawReading(channels: samples, takenAt: Date())
    }

    /// 懒建订阅(stats setupANE :314-325 同款):整份响应字典取可变副本,
    /// 原样传给 CreateSubscription;成功后缓存,失败保持 nil 下轮重试
    /// (开机早期组可能尚未就绪)。
    private func ensureSubscription() {
        guard subscription == nil,
              let responseDict = iorCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, nil)?
                  .takeRetainedValue(),
              let mutable = cfDictionaryCreateMutableCopy(nil, 0, responseDict)?.takeRetainedValue(),
              let dict = mutable as? [String: Any], dict["IOReportChannels"] != nil
        else { return }
        var subscribed: Unmanaged<CFMutableDictionary>?
        let sub = iorCreateSubscription(nil, mutable, &subscribed, 0, nil)
        subscribed?.release()
        guard let sub else { return }
        channelList = mutable
        subscription = sub
    }
}

// MARK: - 五路功率传感器 provider(p2-sensors/03,ADR-0004)

/// 五路功率传感器:短档 `.every(seconds: 5)`,与 GPU 同门控(弹窗 ∨ GPU 页,
/// PowerFeature 折算下发);差分(首读 0/断档丢首轮/负差钳 0)在核心包
/// PowerAccumulator。读失败交付 lastGood 不白屏。历史档随 08 票。
/// @unchecked Sendable:accumulator 与源的订阅状态由 stateLock 串行——
/// 5s UI 档与 30s 历史档两条 driver 的 tick 在调度 actor 外并发执行
/// (2026-10-23 审计②:此前"单 actor 串行"前提被双档打破)。
final class EnergyModelSensorProvider: SensorProvider, @unchecked Sendable {
    typealias Reading = PowerReading

    let cadence: SensorCadence = .every(seconds: 5)

    private let source: any PowerSource
    private let gate = SensorVisibilityGate()
    private let slot = SensorLastGoodBox<PowerReading>()
    private var accumulator = PowerAccumulator()
    /// 双档串行锁:护 accumulator 差分账本与源的懒建订阅。
    private let stateLock = NSLock()

    var lastGood: PowerReading? {
        slot.current
    }

    init(source: any PowerSource = LiveEnergyModelSource()) {
        self.source = source
    }

    /// 可见性切换(与 GPU 传感同闸:弹窗 ∨ GPU 页)。
    func setVisible(_ visible: Bool) {
        _ = gate.setVisible(visible)
    }

    func snapshot() async -> PowerReading? {
        guard gate.isVisible else { return nil }
        return await historySnapshot()
    }

    /// 历史档读(p2-sensors/08):不看可见性闸;差分账本与 UI 档共用
    /// (能量差分按实测时差,5s/30s 档位切换不断账)。
    func historySnapshot() async -> PowerReading? {
        guard let raw = source.read() else { return nil }
        return foldLocked(raw)
    }

    /// NSLock 禁用于 async 上下文(Swift 6)——锁段拆进同步方法。
    private func foldLocked(_ raw: PowerRawReading) -> PowerReading? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let reading = accumulator.record(raw)
        slot.store(reading)
        return reading
    }
}
