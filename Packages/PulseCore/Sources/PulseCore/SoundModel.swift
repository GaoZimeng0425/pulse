import Foundation

// MARK: - 声音传感器(p2-sensors/05,ADR-0004 SensorProvider 接缝)

/// 声音原始读数(Live 交回的原始载荷,属性读取在 Live、折算在核心包):
/// CoreAudio 默认输出设备的名称 + 主声道音量标量 + 静音位。声音是非重点家族
/// (spec 拍板:纯展示层,不做控制交互、不做每 App 层)——载荷刻意最小。
public struct SoundRawReading: Equatable, Sendable {
    /// 默认输出设备名(kAudioObjectPropertyName),无输出设备 = nil。
    public var deviceName: String?
    /// 主声道音量标量(kAudioDevicePropertyVolumeScalar,0–1);设备不控音量
    /// (部分 USB/聚合设备)= nil。
    public var volumeScalar: Float?
    /// 静音位(kAudioDevicePropertyMute,1 = 静音);不可读 = nil。
    public var isMuted: Bool?

    public init(
        deviceName: String? = nil,
        volumeScalar: Float? = nil,
        isMuted: Bool? = nil
    ) {
        self.deviceName = deviceName
        self.volumeScalar = volumeScalar
        self.isMuted = isMuted
    }
}

/// 声音读数(折算后):音量标量折百分数并钳 0…100(个别驱动回报越界,防御口径
/// 与 GPU 利用率钳位同族);名称透传。静音与音量是独立属性(静音时音量值保留,
/// UI 据此显示"静音 + 当前音量",解除静音不用重学位置)。
public struct SoundReading: Equatable, Sendable {
    public let deviceName: String?
    /// 0–100 的整数百分位;nil = 设备不控音量(占位显示)。
    public let volumePercent: Double?
    public let isMuted: Bool?

    /// 原始读数 → 展示读数:标量 × 100 钳 0…100,nil 穿透;静音位透传。
    public static func make(from raw: SoundRawReading) -> SoundReading {
        SoundReading(
            deviceName: raw.deviceName,
            volumePercent: raw.volumeScalar.map { min(max(Double($0) * 100, 0), 100) },
            isMuted: raw.isMuted
        )
    }
}

// MARK: - 声音源协议(编译期测试接缝,ADR-0003 澄清条款同款)

/// 声音源(ADR-0004 接缝):产品运行期唯一真实现 = app 的 Live 适配器
/// (CoreAudio 属性读取),测试注入假源;缝上全部纯逻辑(本文件的折算)。
public protocol SoundSource: Sendable {
    /// 读一次;nil = 读失败(无音频子系统 / 默认设备缺席)。
    func read() -> SoundRawReading?
}
