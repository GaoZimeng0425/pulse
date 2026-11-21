import Foundation
import Observation
import PulseCore

/// 每应用音量/静音的持久层与唯一事实来源(app-volume/01;AlertSettingsStore 同款
/// 纪律):UserDefaults 存 JSON 载荷,读写经注入闭包隔离,单测注入独立 suite。
/// 键名即持久化契约,勿改(改了会丢用户设置)。载荷编解码是 PulseCore 纯函数
/// (`AppVolumeSettings.decode/encode`),坏数据防御在核心包单测覆盖。
@Observable
@MainActor
final class AppVolumeSettingsStore {
    /// UserDefaults 键:JSON {volumes: {appKey: 0…1}, mutes: [appKey]}。
    static let storageKey = "appVolumeSettings"

    private(set) var settings: AppVolumeSettings
    private let persist: (AppVolumeSettings) -> Void

    /// 注入构造(测试 / 预览)。
    init(load: () -> AppVolumeSettings, persist: @escaping (AppVolumeSettings) -> Void) {
        settings = load()
        self.persist = persist
    }

    /// 生产构造:UserDefaults(标准库);测试注入独立 suite。
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            load: { AppVolumeSettings.decode(defaults.data(forKey: Self.storageKey)) },
            persist: { settings in
                if let data = settings.encode() {
                    defaults.set(data, forKey: Self.storageKey)
                }
            }
        )
    }

    /// 改某行音量(滑块拖动;拖动即取消静音,`AppVolumeSettings.withVolume` 语义)。
    func setVolume(_ volume: Double, for key: String) {
        settings = settings.withVolume(volume, for: key)
        persist(settings)
    }

    /// 切换某行静音。
    func toggleMute(for key: String) {
        settings = settings.withMute(!settings.isMuted(key), for: key)
        persist(settings)
    }
}
