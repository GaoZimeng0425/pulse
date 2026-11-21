import CoreAudio
import Foundation

// MARK: - CoreAudio 属性读取辅助(app-volume/01)

//
// Adapted from lishuangqiang/mixbar (MIT), which adapted it from burghr/MacMixer
// (MIT). See THIRD_PARTY_NOTICES.md. 只搬引擎用到的子集:定标量/数组/CFString
// 读取、OSStatus 转可读错误码、默认输出设备身份。

enum AppAudioCA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let mainElement = kAudioObjectPropertyElementMain

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = mainElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// 读定长标量属性,失败回 fallback(T 须为 trivial CoreAudio 类型)。
    static func scalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ fallback: T) -> T {
        let (status, value) = read(obj, addr, fallback)
        return status == noErr ? value : fallback
    }

    /// 读定长标量并带回 OSStatus(调用方要区分「读失败」与「真值」时用)。
    static func read<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> (OSStatus, T) {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return (status, value)
    }

    /// OSStatus 转可读错误码,例如 "'who?' (2003332927)"。
    static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        let code = printable ? "'\(String(decoding: bytes, as: UTF8.self))' " : ""
        return "\(code)(\(status))"
    }

    /// 读变长属性为 trivially-copyable T 数组。
    static func array<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        var a = addr
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { raw.deallocate() }
        var sz = size
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, raw) == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: min(count, Int(sz) / MemoryLayout<T>.stride)))
    }

    static func cfString(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }

    // MARK: 设备身份(引擎聚合用)

    /// 系统默认输出设备;无音频子系统/无设备 = nil。
    static func defaultOutputDevice() -> AudioObjectID? {
        let id = scalar(
            systemObject,
            address(kAudioHardwarePropertyDefaultOutputDevice),
            AudioObjectID(kAudioObjectUnknown)
        )
        return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
    }

    static func deviceUID(_ id: AudioObjectID) -> String? {
        cfString(id, address(kAudioDevicePropertyDeviceUID))
    }
}
