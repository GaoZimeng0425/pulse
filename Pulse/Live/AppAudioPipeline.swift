import AudioToolbox
import CoreAudio
import Foundation
import os
import PulseCore

// MARK: - 每 app 音频管线(app-volume/01)

//
// Adapted from lishuangqiang/mixbar ProcessTap.swift (MIT), which builds on
// pantafive/fader (MIT). See THIRD_PARTY_NOTICES.md. 机制:一个 app(组)一条
// 私有进程 tap(mutedWhenTapped:读即掐原声、停读自动恢复——Pulse 崩溃/退出,
// 该 app 声音自动回原始路由,最坏情况是"控制失效"而非"没声音")+ 一个私有
// 聚合设备(真实输出为子设备 + tap 为子 tap),IOProc 里乘增益重播。不装驱动、
// 不改默认输出设备,别的 app 声音不经过这里。

struct AppAudioPipelineError: LocalizedError {
    let operation: String
    let code: OSStatus
    var errorDescription: String? {
        "\(operation)失败(\(AppAudioCA.describe(code)))。请检查系统音频录制权限后重试。"
    }
}

/// 实时回调与 UI 之间的非阻塞增益交换:UI 侧写目标值,音频线程 trylock 读,
/// 拿不到锁就用上一帧的值——实时回调绝不等待 UI 锁。
private final class AppAudioGainState: @unchecked Sendable {
    private let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
    private var target: Float
    private var callbacks: UInt64 = 0
    private var hasAudioSignal = false

    init(_ gain: Float) {
        target = gain
        lock.initialize(to: os_unfair_lock_s())
    }

    func set(_ gain: Float) {
        os_unfair_lock_lock(lock)
        target = max(0, min(Float(AppVolumeCurve.maximum), gain))
        os_unfair_lock_unlock(lock)
    }

    func read(or previous: Float) -> Float {
        guard os_unfair_lock_trylock(lock) else { return previous }
        let value = target
        os_unfair_lock_unlock(lock)
        return value
    }

    /// 音频线程上报(render 计数 + 有无信号;拿不到锁就丢这帧统计,不等待)。
    func tick(sawSignal: Bool) {
        guard os_unfair_lock_trylock(lock) else { return }
        callbacks &+= 1
        if sawSignal {
            hasAudioSignal = true
        }
        os_unfair_lock_unlock(lock)
    }

    func statistics() -> (callbacks: UInt64, hasAudioSignal: Bool) {
        os_unfair_lock_lock(lock)
        let values = (callbacks, hasAudioSignal)
        os_unfair_lock_unlock(lock)
        return values
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// 一个 app(进程组)的声音接管管线:私有 tap + 私有聚合设备 + 增益渲染。
/// 销毁 tap 即恢复该 app 原始声音(mixbar 同款;`stop()` 幂等,deinit 兜底)。
final class AppAudioPipeline: @unchecked Sendable {
    let processIDs: [AudioObjectID]
    let outputID: AudioObjectID
    let outputUID: String
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let gainState: AppAudioGainState
    private var currentGain: Float
    private var lastTarget: Float
    /// 每采样一步的增益斜坡系数(25ms 到达目标,拖滑块不跳变)。
    private var ramp: Float = 0.001
    /// duplex 硬件(带麦克风通道的设备)会把麦克风缓冲排在 tap 之前:tap 流的索引。
    private var inputOffset = 0
    private(set) var sampleRate: Double = 0
    private(set) var started = false
    /// 超 100% 增益会把响料推出满刻度;逐采样钳会把峰削成爆音,所以用峰值限制器
    /// 整帧压低一点,安静料吃满增益。上限 ≈ −0.5 dBFS,160ms 指数释放。
    /// 本期 UI 只开 0–100%,限制器随引擎保留(0–200% 后续票的免费件)。
    private static let limiterCeiling: Float = 0.944
    private var limiterEnvelope: Float = 0
    private var limiterRelease: Float = 1

    init(processIDs: [AudioObjectID], outputID: AudioObjectID, outputUID: String, gain: Float) {
        self.processIDs = processIDs.sorted()
        self.outputID = outputID
        self.outputUID = outputUID
        gainState = AppAudioGainState(gain)
        currentGain = gain
        lastTarget = gain
    }

    func setGain(_ gain: Float) {
        gainState.set(gain)
    }

    var hasAudioSignal: Bool {
        gainState.statistics().hasAudioSignal
    }

    /// 只在音频线程渲染时前进;播放中计数停走 = 聚合停了而 tap 还在掐原声
    /// (自愈看门狗的判据,feature 层消费)。
    var renderCallbacks: UInt64 {
        gainState.statistics().callbacks
    }

    var isAlive: Bool {
        started && aggregateID != 0
            && AppAudioCA.scalar(aggregateID, AppAudioCA.address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) != 0
    }

    func start() throws {
        do { try construct() } catch { stop()
            throw error
        }
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr {
            throw AppAudioPipelineError(operation: action, code: status)
        }
    }

    private func construct() throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tap.uuid = UUID()
        tap.name = "Pulse 每应用音量"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "获取应用音频")
        guard tapID != 0 else { throw AppAudioPipelineError(operation: "获取应用音频", code: -1) }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pulse App Volume",
            kAudioAggregateDeviceUIDKey: "pulse.app-volume.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID), "连接音频输出")
        let outFormat = AppAudioCA.read(
            aggregateID,
            AppAudioCA.address(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput),
            AudioStreamBasicDescription()
        )
        try check(outFormat.0, "读取输出格式")
        let format = outFormat.1
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
            throw AppAudioPipelineError(operation: "当前输出设备的音频格式不受支持", code: kAudioDeviceUnsupportedFormatError)
        }
        let tapFormat = AppAudioCA.read(
            tapID,
            AppAudioCA.address(kAudioTapPropertyFormat),
            AudioStreamBasicDescription()
        )
        try check(tapFormat.0, "读取应用音频格式")
        guard tapFormat.1.mFormatID == kAudioFormatLinearPCM,
              tapFormat.1.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.1.mBitsPerChannel == 32,
              tapFormat.1.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            throw AppAudioPipelineError(operation: "当前应用的音频格式不受支持", code: kAudioDeviceUnsupportedFormatError)
        }
        sampleRate = format.mSampleRate
        ramp = 1 - exp(-1 / (Float(sampleRate) * 0.025))
        limiterRelease = Float(exp(-1000 / (max(sampleRate, 8000) * 160)))
        inputOffset = max(0, bufferCount(aggregateID, scope: kAudioObjectPropertyScopeInput) - 1)
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProc,
                aggregateID,
                nil
            ) { [unowned(unsafe) self] _, input, _, output, _ in
                render(input, output)
            },
            "创建音频处理"
        )
        try check(AudioDeviceStart(aggregateID, ioProc), "启动音频处理")
        started = true
    }

    func stop() {
        if aggregateID != 0 {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProc = nil
        aggregateID = 0
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = 0
        started = false
    }

    deinit { stop() }

    private func bufferCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AppAudioCA.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return Int(memory.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    /// 音频实时线程纪律:无分配、无日志、无等待、无 Objective-C。立体声 tap →
    /// 交错或平面硬件缓冲;蓝牙 HFP 单声道按帧安全下混;多余输出声道置零。
    private func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard inputOffset < inputs.count else { return }
        let source = inputs[inputOffset]
        guard let sourceData = source.mData, source.mNumberChannels > 0 else { return }
        let samples = sourceData.assumingMemoryBound(to: Float.self)
        let inChannels = Int(source.mNumberChannels)
        let inFrames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / inChannels
        guard inFrames > 0 else { return }
        var outChannels = 0
        for buffer in outputs {
            outChannels += Int(buffer.mNumberChannels)
        }
        guard outChannels > 0 else { return }
        let target = gainState.read(or: lastTarget)
        lastTarget = target
        // 只在 boost(>100%)时限制;unity 以下增益本身就把信号压在 ceilings 内。
        let limiting = target > 1.0001
        let ceiling = Self.limiterCeiling
        let release = limiterRelease
        var gain = currentGain
        var envelope = limiterEnvelope
        var sawSignal = false
        for frame in 0 ..< inFrames {
            gain += (target - gain) * ramp
            let left = samples[frame * inChannels]
            let right = inChannels > 1 ? samples[frame * inChannels + 1] : left
            if abs(left) > 0.000001 || abs(right) > 0.000001 {
                sawSignal = true
            }

            let scaledLeft = left * gain
            let scaledRight = right * gain
            var mono = (left + right) * 0.5 * gain
            // 整帧一个增益,保立体声像:瞬时 attack(不放过峰)+ 指数 release
            // (电平恢复不抽泵)。
            let framePeak = outChannels == 1 ? abs(mono) : max(abs(scaledLeft), abs(scaledRight))
            envelope = framePeak > envelope ? framePeak : framePeak + (envelope - framePeak) * release
            let limitGain: Float = (limiting && envelope > ceiling) ? ceiling / envelope : 1
            let outLeft = scaledLeft * limitGain
            let outRight = scaledRight * limitGain
            mono *= limitGain

            var channelOffset = 0
            for buffer in outputs {
                let channels = Int(buffer.mNumberChannels)
                defer { channelOffset += channels }
                guard channels > 0, let data = buffer.mData,
                      frame < Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels else { continue }
                let destination = data.assumingMemoryBound(to: Float.self)
                for channel in 0 ..< channels {
                    let globalChannel = channelOffset + channel
                    let sample: Float = if outChannels == 1 {
                        mono
                    } else if globalChannel == 0 {
                        outLeft
                    } else if globalChannel == 1 {
                        outRight
                    } else {
                        0
                    }
                    destination[frame * channels + channel] = sample
                }
            }
        }
        limiterEnvelope = envelope
        currentGain = abs(gain - target) < 0.000001 ? target : gain
        gainState.tick(sawSignal: sawSignal)
    }
}
