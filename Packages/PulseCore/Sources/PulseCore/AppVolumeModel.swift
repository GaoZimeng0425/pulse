import Foundation

// MARK: - 每应用音量纯逻辑(app-volume/01;ADR-0004 测试缝)

//
// 分层:HAL 枚举 / tap 管线全在 app target(CoreAudio tap 头文件 ObjC-only,
// PulseCore 进不了);本文件只放可以脱离 CoreAudio 测试的纯逻辑——滑块↔增益
// 曲线、设置持久化载荷、枚举快照×已存设置→展示条目的归并。

/// 滑块位(0…1)与 100% 以上增益位的换算曲线。响度是对数刻度:滑块位直接当
/// 增益用会把可听范围挤在最下面五分之一(50% 只降 6dB,听感几乎没变小)。100%
/// 以下把滑块位平方(50% ≈ −12dB、25% ≈ −24dB),100% 保持原声(=1,不接管),
/// 100% 以上线性(2 = +6dB,UI 本期只开 0…100,引擎保留)。
/// 直搬 lishuangqiang/mixbar VolumeCurve(MIT;见仓库 THIRD_PARTY_NOTICES.md)。
public enum AppVolumeCurve {
    /// 曲线支持的增益上限(200%);滑块 UI 本期封顶 1。
    public static let maximum: Double = 2

    /// 滑块位 → 增益。
    public static func gain(for volume: Double) -> Float {
        guard volume.isFinite else { return 1 }
        let level = max(0, min(maximum, volume))
        return Float(level < 1 ? level * level : level)
    }
}

// MARK: - 设置载荷

/// 每应用音量/静音的持久化载荷与纯操作。键 = 应用身份(bundleID,兜底
/// "pid:<pid>");值域滑块位 0…1(UI 口径),增益折算走 `AppVolumeCurve`。
/// 编解码坏数据防御在此(AlertSettingsStore 编解码同款纪律)。
public struct AppVolumeSettings: Equatable, Sendable {
    public var volumes: [String: Double]
    public var mutes: Set<String>

    public init(volumes: [String: Double] = [:], mutes: Set<String> = []) {
        self.volumes = volumes
        self.mutes = mutes
    }

    /// 应用音量(滑块位);未配置 = 1(原声直通,不接管)。
    public func volume(for key: String) -> Double {
        guard let raw = volumes[key], raw.isFinite else { return 1 }
        return min(max(raw, 0), 1)
    }

    public func isMuted(_ key: String) -> Bool {
        mutes.contains(key)
    }

    /// 改音量:拖动滑块即取消静音(动滑块 = 要听,听在新位置)。非有限值拒绝。
    public func withVolume(_ volume: Double, for key: String) -> AppVolumeSettings {
        guard volume.isFinite else { return self }
        var next = self
        next.volumes[key] = min(max(volume, 0), 1)
        if volume > 0 {
            next.mutes.remove(key)
        }
        return next
    }

    public func withMute(_ muted: Bool, for key: String) -> AppVolumeSettings {
        var next = self
        if muted {
            next.mutes.insert(key)
        } else {
            next.mutes.remove(key)
        }
        return next
    }
}

public extension AppVolumeSettings {
    /// 载荷 → 设置:解码失败 / 缺项回落空设置;音量越界值钳回 0…1,坏键原样保留
    /// (pid: 键在 app 未重启期间仍有效,丢弃等于丢用户设置)。
    static func decode(_ data: Data?) -> AppVolumeSettings {
        struct Payload: Decodable {
            var volumes: [String: Double]?
            var mutes: [String]?
        }
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return AppVolumeSettings()
        }
        let volumes = (payload.volumes ?? [:]).reduce(into: [String: Double]()) { result, entry in
            guard entry.value.isFinite else { return }
            result[entry.key] = min(max(entry.value, 0), 1)
        }
        return AppVolumeSettings(volumes: volumes, mutes: Set(payload.mutes ?? []))
    }

    /// 设置 → 载荷(sortedKeys:同内容同字节,存储层可 diff)。
    func encode() -> Data? {
        struct Payload: Encodable {
            var volumes: [String: Double]
            var mutes: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Payload(volumes: volumes, mutes: mutes.sorted()))
    }
}

// MARK: - 枚举快照(Live 交回的原始载荷)

/// 一个音频客户端(HAL process object;字段口径 = 公开属性 PID / BundleID /
/// IsRunningOutput 的原样透传,OS 调用在 Live 层)。
public struct AppVolumeClient: Equatable, Sendable {
    /// HAL 进程对象的 AudioObjectID(tap 挂它,不是 unix pid)。
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let isPlaying: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, isPlaying: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isPlaying = isPlaying
    }
}

// MARK: - 展示条目与归并

/// 混音卡一行(纯数据;app 图标是 AppKit 物,住 feature 层不进核心包)。
/// `processIDs` 是 HAL 进程对象 ID 列表(沿用 mixbar 命名,升序)。
/// `bundleID` = **宿主 app** 的 bundle(图标/身份用)——浏览器 helper 归并到
/// 宿主行后,图标要查宿主的,不是 helper 自己的。
public struct AppVolumeEntry: Equatable, Identifiable, Sendable {
    /// 应用身份:bundleID,兜底 "pid:<pid>"(无 bundle 的音频进程)。
    public let id: String
    public let bundleID: String?
    public let name: String
    public var processIDs: [UInt32]
    /// 滑块位 0…1(UI 口径);1 = 原声直通。
    public var volume: Double
    public var isMuted: Bool
    public var isPlaying: Bool
    /// 当前是否处于接管中(tap+增益管线在跑)。
    public var isControlled: Bool
    public var error: String?

    public init(
        id: String,
        bundleID: String?,
        name: String,
        processIDs: [UInt32] = [],
        volume: Double = 1,
        isMuted: Bool = false,
        isPlaying: Bool = false,
        isControlled: Bool = false,
        error: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.processIDs = processIDs
        self.volume = volume
        self.isMuted = isMuted
        self.isPlaying = isPlaying
        self.isControlled = isControlled
        self.error = error
    }

    /// 期望增益:静音 = 0;否则曲线折算。=1 即原声直通(不需要管线)。
    public var desiredGain: Float {
        isMuted ? 0 : AppVolumeCurve.gain(for: volume)
    }
}

/// 已归因的客户端(归属哪个 app、显示名):归因本身要 NSWorkspace,住 Live 层;
/// 归并是纯逻辑,在此。
public struct AttributedVolumeClient: Sendable {
    public let client: AppVolumeClient
    /// 宿主应用身份键(AppVolumeEntry.id 同口径)。
    public let appKey: String
    public let appName: String
    /// 宿主 app 的 bundleID(条目身份/图标用;pid 行 = nil)。刻意独立于
    /// `client.bundleID`:浏览器 helper 归因到宿主后,身份跟宿主走。
    public let appBundleID: String?

    public init(client: AppVolumeClient, appKey: String, appName: String, appBundleID: String?) {
        self.client = client
        self.appKey = appKey
        self.appName = appName
        self.appBundleID = appBundleID
    }
}

public enum AppVolumeGrouping {
    /// 归因后的客户端 × 已存设置 → 展示条目(按名称本地化排序)。同 app 多个
    /// 音频客户端(浏览器 helper、多进程)合并为一行:processIDs 并集升序、
    /// isPlaying 任一真即真。展示态(isControlled/error)不在这里产生——那是
    /// 管线 reconcile 的产物。
    public static func entries(
        from attributed: [AttributedVolumeClient],
        settings: AppVolumeSettings
    ) -> [AppVolumeEntry] {
        var grouped: [String: AppVolumeEntry] = [:]
        for item in attributed {
            let key = item.appKey
            if var entry = grouped[key] {
                entry.processIDs.append(item.client.objectID)
                entry.isPlaying = entry.isPlaying || item.client.isPlaying
                grouped[key] = entry
            } else {
                grouped[key] = AppVolumeEntry(
                    id: key,
                    bundleID: item.appBundleID,
                    name: item.appName,
                    processIDs: [item.client.objectID],
                    volume: settings.volume(for: key),
                    isMuted: settings.isMuted(key),
                    isPlaying: item.client.isPlaying
                )
            }
        }
        return grouped.values.map { entry in
            var entry = entry
            entry.processIDs.sort()
            return entry
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 引擎缝(端口;HAL 对象 id 即 CoreAudio 的 AudioObjectID = UInt32,Live 实现在 app target)

/// 一轮全量扫描的产物:输出设备身份(换设备 = 管线整批重建的判据)+ 已归因的
/// 音频客户端列表(原始客户端内嵌在归因条目里,不重复搭乘)。
public struct AppVolumeScan: Sendable {
    public let outputID: UInt32
    public let outputUID: String
    public let attributed: [AttributedVolumeClient]

    public init(outputID: UInt32, outputUID: String, attributed: [AttributedVolumeClient]) {
        self.outputID = outputID
        self.outputUID = outputUID
        self.attributed = attributed
    }
}

/// 引擎缝:产品运行期唯一真实现 = LiveAppVolumeEngine(CoreAudio tap/属性读);
/// 测试 / 预览注入假引擎(InertSources),绝不碰 HAL——tap 在 hosted 测试宿主里
/// 会触发 TCC 弹窗且有挂死前科(test-hang-cure),引擎一律不进自动化。
public protocol AppVolumeEngineProtocol: Sendable {
    /// 全量扫描:HAL 快照在后台线程读(≈12ms,几十次 HAL 往返,不占主线程),
    /// 宿主归因回主线程(NSWorkspace)。nil = 无音频子系统 / 无输出设备。
    func scan() async -> AppVolumeScan?
    /// 建一条接管管线(start/增益/停止由 feature 侧驱动)。
    func makePipeline(
        processIDs: [UInt32],
        outputID: UInt32,
        outputUID: String,
        gain: Float
    ) -> AppAudioPipelineProtocol
}

public protocol AppAudioPipelineProtocol: AnyObject, Sendable {
    var processIDs: [UInt32] { get }
    var outputID: UInt32 { get }
    /// 只在音频线程渲染时前进;停走 = 聚合停了而 tap 还在掐原声(看门狗判据)。
    var renderCallbacks: UInt64 { get }
    var hasAudioSignal: Bool { get }
    var isAlive: Bool { get }
    func setGain(_ gain: Float)
    func start() throws
    func stop()
}
