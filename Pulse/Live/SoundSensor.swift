import CoreAudio
import Foundation
import PulseCore

// MARK: - Live 声音源(p2-sensors/05)

/// Darwin 薄适配器:CoreAudio 三连——系统默认输出设备(kAudioHardwareProperty
/// DefaultOutputDevice)+ 设备名(kAudioObjectPropertyName)+ 主声道音量标量与
/// 静音位(kAudioDevicePropertyVolumeScalar / Mute,输出域)。主声道(element 0)
/// 缺席时按声道 1、2 顺读(部分 USB/聚合设备只有分声道);OS 调用都在这里,
/// 折算(标量→百分数、钳位)在 PulseCore `SoundReading.make`(ADR-0004 测试缝)。
struct LiveSoundSource: SoundSource {
    func read() -> SoundRawReading? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return SoundRawReading(
            deviceName: Self.deviceName(device),
            volumeScalar: Self.volumeScalar(device),
            isMuted: Self.muteState(device)
        )
    }

    /// 系统默认输出设备;无音频子系统/无设备 = nil。
    static func defaultOutputDevice() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) ==
            kAudioHardwareNoError else {
            return nil
        }
        return device
    }

    /// 设备名(CFString);读失败 = nil(占位显示,不崩)。
    static func deviceName(_ device: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == kAudioHardwareNoError else {
            return nil
        }
        return name as String
    }

    /// 主声道音量标量;主声道缺席按声道 1、2 顺读,全缺 = nil(设备不控音量)。
    static func volumeScalar(_ device: AudioDeviceID) -> Float? {
        for element in [AudioObjectPropertyElement(0), 1, 2] {
            if let value = scalar(
                device,
                selector: kAudioDevicePropertyVolumeScalar,
                element: element,
                as: Float32.self
            ) {
                return value
            }
        }
        return nil
    }

    /// 静音位(UInt32,1 = 静音);不可读 = nil。
    static func muteState(_ device: AudioDeviceID) -> Bool? {
        for element in [AudioObjectPropertyElement(0), 1, 2] {
            if let value = scalar(device, selector: kAudioDevicePropertyMute, element: element, as: UInt32.self) {
                return value != 0
            }
        }
        return nil
    }

    /// 单属性单声道读一把;HasProperty 先问(不支持音量的声道直接跳过,
    /// 不产生错误日志噪声)。
    private static func scalar<T>(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        as type: T.Type
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { buffer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == kAudioHardwareNoError else {
            return nil
        }
        return buffer.load(as: T.self)
    }
}

// MARK: - CoreAudio 属性变更事件(事件驱动档的 OS 边界)

/// 属性监听的 C 回调桥(顶层非捕获闭包,可转 @convention(c));context =
/// passRetained 的盒子指针,与 IOPSWakeupStream 同款纪律。
private let soundListenerProc: AudioObjectPropertyListenerProc = { objectID, count, addresses, context in
    guard let context else { return kAudioHardwareNoError }
    let box = Unmanaged<CoreAudioWakeupStream.Box>.fromOpaque(context).takeUnretainedValue()
    box.propertyChanged(objectID: objectID, addressCount: count, addresses: addresses)
    return kAudioHardwareNoError
}

/// CoreAudio 属性监听 → 唤醒流:系统对象盯默认设备切换,当前默认设备盯
/// 音量/静音变更——变化才唤醒读数,**不轮询**(IOPSWakeupStream 同款形状,
/// spec 故事 27:插拔耳机、改音量即时反映)。默认设备切换时对新设备换挂
/// 属性监听。构造即先发一个首唤醒——首帧就有数;流被丢弃/取消时摘除全部
/// 监听,不泄漏。
enum CoreAudioWakeupStream {
    /// 桥接 C 回调上下文:@unchecked Sendable 盒子持有 continuation、自身
    /// opaque 指针与监听登记;属性回调在 CoreAudio 自有线程到达,内部状态
    /// 用锁护(Swift 6 Sendable 边界)。
    final class Box: @unchecked Sendable {
        private let continuation: AsyncStream<Void>.Continuation
        /// 监听器增删专用串行队列:CoreAudio 惯例禁止在属性回调线程内同步
        /// 增删监听(默认设备切换时可死锁,2026-10-23 审计③)——回调里只投递
        /// 换挂请求到本队列,增删全部在此执行。
        private let listenerQueue = DispatchQueue(label: "pulse.sound-listener")
        private let lock = NSLock()
        /// 当前挂着设备级监听的设备(默认设备切换时换挂;nil = 未挂)。
        private var listenedDevice: AudioDeviceID?
        private var systemListened = false
        /// 已收尾标记:迟到的换挂请求见到即弃,不在 teardown 后重挂(泄漏)。
        private var tornDown = false

        init(continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        /// 自身 opaque 指针(add/remove 监听时作 client context;对象地址在
        /// 生命周期内恒定,与 make 的 passRetained / teardown 的 release 配平)。
        private var opaque: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        /// 挂系统对象 + 当前默认设备两级监听(make 里调用一次;增删走监听队列)。
        func start() {
            listenerQueue.async { [self] in
                installListeners()
            }
        }

        /// 监听队列上执行:系统级 + 当前默认设备两级监听。
        private func installListeners() {
            lock.lock()
            defer { lock.unlock() }
            guard !tornDown else { return }
            var systemAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &systemAddress) {
                AudioObjectAddPropertyListener(
                    AudioObjectID(kAudioObjectSystemObject),
                    &systemAddress,
                    soundListenerProc,
                    opaque
                )
                systemListened = true
            }
            relistenDeviceLocked()
        }

        /// 属性回调(HAL 自有线程):默认设备变化 → **异步**投递换挂请求到监听
        /// 队列(回调内同步增删是死锁风险,审计③);任何变化 → 唤醒读一轮。
        func propertyChanged(
            objectID: AudioObjectID,
            addressCount: UInt32,
            addresses: UnsafePointer<AudioObjectPropertyAddress>?
        ) {
            guard let addresses else { return }
            for index in 0 ..< Int(addressCount) {
                let address = addresses[index]
                if objectID == AudioObjectID(kAudioObjectSystemObject),
                   address.mSelector == kAudioHardwarePropertyDefaultOutputDevice {
                    listenerQueue.async { [self] in
                        relistenDevice()
                    }
                }
                continuation.yield()
            }
        }

        /// 摘除全部监听并配平 retain(流终止时调用一次)。先置 tornDown 挡住
        /// 在途换挂请求,再同步清空监听队列(teardown 不在 HAL 回调线程上,
        /// sync 安全)。
        func teardown() {
            lock.lock()
            tornDown = true
            lock.unlock()
            listenerQueue.sync { [self] in
                removeAllListeners()
            }
            Unmanaged.passUnretained(self).release()
        }

        /// 监听队列上执行:摘除两级监听。
        private func removeAllListeners() {
            lock.lock()
            defer { lock.unlock() }
            if let device = listenedDevice {
                removeDeviceListeners(from: device)
                listenedDevice = nil
            }
            if systemListened {
                var systemAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListener(
                    AudioObjectID(kAudioObjectSystemObject),
                    &systemAddress,
                    soundListenerProc,
                    opaque
                )
                systemListened = false
            }
        }

        /// 监听队列上执行:对当前默认设备挂音量/静音监听(先摘旧设备;设备
        /// 缺席安静跳过,下次默认设备变化再补挂)。
        private func relistenDevice() {
            lock.lock()
            defer { lock.unlock() }
            guard !tornDown else { return }
            relistenDeviceLocked()
        }

        private func relistenDeviceLocked() {
            if let old = listenedDevice {
                removeDeviceListeners(from: old)
                listenedDevice = nil
            }
            guard let device = LiveSoundSource.defaultOutputDevice() else { return }
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for element in [AudioObjectPropertyElement(0), 1, 2] {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector,
                        mScope: kAudioDevicePropertyScopeOutput,
                        mElement: element
                    )
                    guard AudioObjectHasProperty(device, &address) else { continue }
                    AudioObjectAddPropertyListener(device, &address, soundListenerProc, opaque)
                }
            }
            listenedDevice = device
        }

        private func removeDeviceListeners(from device: AudioDeviceID) {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for element in [AudioObjectPropertyElement(0), 1, 2] {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector,
                        mScope: kAudioDevicePropertyScopeOutput,
                        mElement: element
                    )
                    AudioObjectRemovePropertyListener(device, &address, soundListenerProc, opaque)
                }
            }
        }
    }

    static func make() -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.yield() // 首唤醒:启动即读一轮
            let box = Box(continuation: continuation)
            _ = Unmanaged.passRetained(box) // 与 teardown 的 release 配平
            box.start()
            continuation.onTermination = { _ in
                box.teardown()
            }
        }
    }
}

// MARK: - 声音传感器 provider(p2-sensors/05,ADR-0004)

/// 声音传感器:**事件驱动**(`.onEvent`,CoreAudio 属性变更通知,零轮询——
/// spec 节奏矩阵);读数 = 原始读数经纯逻辑折叠(标量→百分数、钳位)。
/// 读失败保留 lastGood(ADR-0004)。事件便宜且稀少(改音量/插拔才有),不设
/// 可见性闸——关两窗也不多花一分钱(采样只在事件到达时发生)。
final class SoundSensorProvider: SensorProvider {
    typealias Reading = SoundReading

    let cadence: SensorCadence = .onEvent

    private let source: any SoundSource
    private let makeWakeups: @Sendable () -> AsyncStream<Void>?
    private let slot = SensorLastGoodBox<SoundReading>()

    var lastGood: SoundReading? {
        slot.current
    }

    init(
        source: any SoundSource = LiveSoundSource(),
        wakeups: @escaping @Sendable () -> AsyncStream<Void>? = { CoreAudioWakeupStream.make() }
    ) {
        self.source = source
        makeWakeups = wakeups
    }

    func snapshot() async -> SoundReading? {
        guard let raw = source.read() else { return nil }
        let reading = SoundReading.make(from: raw)
        slot.store(reading)
        return reading
    }

    func wakeups() -> AsyncStream<Void>? {
        makeWakeups()
    }
}
