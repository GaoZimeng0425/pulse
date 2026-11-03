import Foundation
import Observation
import PulseCore

/// 告警规则配置的持久层与唯一事实来源(工单 P1-07):UserDefaults 存
/// [kind: {开关, 阈值}] JSON;持续时长/冷却期/方向随种类预设定型,不进设置。
/// 逐条开关与阈值改动即时生效(存储是 @Observable,引擎每轮喂食取快照,
/// 变化由引擎检测)并即刻落盘。读写经注入 defaults 隔离(ProjectRootsStore
/// 同款):单测注入独立 suite。
@Observable
@MainActor
final class AlertSettingsStore {
    /// UserDefaults 键:JSON 字典 {kindRawValue: {isEnabled, threshold}}。
    /// 键名即持久化契约,勿改(改了会丢用户配置)。
    static let storageKey = "alertRuleConfigs"
    /// NemoNotch toast 投递开关的键(键名即持久化契约,勿改)。
    static let toastDeliveryStorageKey = "alertNemoNotchToastEnabled"
    /// 系统通知投递开关的键(键名即持久化契约,勿改)。
    static let systemDeliveryStorageKey = "alertSystemNotificationEnabled"

    /// 当前配置(缺省 = 预设阈值 + 全关)。授权状态不在这里记:以系统三态为准
    /// (AlertCenter 现查),本地"请求过"标记曾与系统现状脱节、误判拒绝
    /// (2026-10-19),已撤。
    private(set) var configs: [AlertKind: AlertRuleConfig]
    /// NemoNotch toast 投递开关(默认开:规则本身默认全关,开规则才是主闸门;
    /// NemoNotch 未运行时发送器静默跳过,开着无副作用)。
    private(set) var toastDeliveryEnabled: Bool
    /// 系统通知(UNUserNotification 横幅)投递开关。**未显式设置时取 toast 开关
    /// 的反**(2026-11-03 用户拍板:开 NemoNotch 卡就不发系统通知——一条告警弹
    /// 横幅+卡两路是噪音,根源是 toast 上线时做成了叠加出口);显式设置后独立。
    private(set) var systemDeliveryEnabled: Bool

    private let persist: ([AlertKind: AlertRuleConfig]) -> Void
    private let persistToastDelivery: (Bool) -> Void
    private let persistSystemDelivery: (Bool) -> Void

    /// 任一规则开着(授权时序:有规则开着而系统还没问过时才请求授权)。
    var isAnyEnabled: Bool {
        configs.values.contains(where: \.isEnabled)
    }

    /// 注入读写闭包的构造(测试 / 预览)。
    init(
        load: () -> [AlertKind: AlertRuleConfig],
        persist: @escaping ([AlertKind: AlertRuleConfig]) -> Void,
        loadToastDelivery: () -> Bool = { true },
        persistToastDelivery: @escaping (Bool) -> Void = { _ in },
        loadSystemDelivery: () -> Bool? = { nil },
        persistSystemDelivery: @escaping (Bool) -> Void = { _ in }
    ) {
        configs = Self.mergingPresets(load())
        let toastEnabled = loadToastDelivery()
        toastDeliveryEnabled = toastEnabled
        // nil = 未显式设置:默认与 toast 互斥(开卡不横幅;不开卡保持老的横幅出口)。
        // 局部值参与派生:@Observable 访问器在完全初始化前读兄弟属性会报
        // used-before-initialized。
        systemDeliveryEnabled = loadSystemDelivery() ?? !toastEnabled
        self.persist = persist
        self.persistToastDelivery = persistToastDelivery
        self.persistSystemDelivery = persistSystemDelivery
    }

    /// 生产构造:UserDefaults(标准库);测试注入独立 suite。
    convenience init(defaults: UserDefaults = .standard) {
        // 已撤的"授权请求过"标记(2026-10-19)留在用户偏好里的孤儿键,顺手清掉。
        defaults.removeObject(forKey: "alertAuthorizationRequested")
        self.init(
            load: { Self.decode(defaults.data(forKey: Self.storageKey)) },
            persist: { configs in
                defaults.set(Self.encode(configs), forKey: Self.storageKey)
            },
            loadToastDelivery: {
                defaults.object(forKey: Self.toastDeliveryStorageKey) as? Bool ?? true
            },
            persistToastDelivery: { enabled in
                defaults.set(enabled, forKey: Self.toastDeliveryStorageKey)
            },
            loadSystemDelivery: {
                defaults.object(forKey: Self.systemDeliveryStorageKey) as? Bool
            },
            persistSystemDelivery: { enabled in
                defaults.set(enabled, forKey: Self.systemDeliveryStorageKey)
            }
        )
    }

    // MARK: - 读写

    /// 单规则配置(未配置过的种类回落预设:阈值 = 预设,开关 = 关)。
    func config(for kind: AlertKind) -> AlertRuleConfig {
        configs[kind] ?? AlertRuleConfig(isEnabled: false, threshold: kind.preset.threshold)
    }

    /// 开关某规则(设置页 Toggle;改动即落盘)。
    func setEnabled(_ enabled: Bool, for kind: AlertKind) {
        var config = config(for: kind)
        config.isEnabled = enabled
        configs[kind] = config
        persist(configs)
    }

    /// 改阈值(设置页输入框;改动即落盘即生效)。非正数拒绝(除零/无意义防线)。
    func setThreshold(_ threshold: Double, for kind: AlertKind) {
        guard threshold > 0, threshold.isFinite else { return }
        var config = config(for: kind)
        config.threshold = threshold
        configs[kind] = config
        persist(configs)
    }

    /// 开关 NemoNotch toast 投递(设置页 Toggle;改动即落盘)。
    func setToastDeliveryEnabled(_ enabled: Bool) {
        toastDeliveryEnabled = enabled
        persistToastDelivery(enabled)
    }

    /// 开关系统通知投递(设置页 Toggle;显式写入即落盘,独立于 toast 开关)。
    func setSystemDeliveryEnabled(_ enabled: Bool) {
        systemDeliveryEnabled = enabled
        persistSystemDelivery(enabled)
    }

    /// 引擎每轮喂食取的策略快照(用户配置 × 种类预设)。
    var evaluationSettings: AlertEvaluationSettings {
        AlertEvaluationSettings.make(from: configs)
    }

    // MARK: - 编解码(纯函数,坏数据防御在此)

    /// 载荷 → 配置表:未知 kind 忽略、缺项/解码失败回落预设。
    static func mergingPresets(_ loaded: [AlertKind: AlertRuleConfig]) -> [AlertKind: AlertRuleConfig] {
        var merged = loaded
        for kind in AlertKind.allCases where merged[kind] == nil {
            merged[kind] = AlertRuleConfig(isEnabled: false, threshold: kind.preset.threshold)
        }
        return merged
    }

    static func encode(_ configs: [AlertKind: AlertRuleConfig]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = configs.reduce(into: [String: AlertRuleConfig]()) { $0[$1.key.rawValue] = $1.value }
        return try? encoder.encode(raw)
    }

    static func decode(_ data: Data?) -> [AlertKind: AlertRuleConfig] {
        guard let data, let raw = try? JSONDecoder().decode([String: AlertRuleConfig].self, from: data) else {
            return [:]
        }
        return raw.reduce(into: [AlertKind: AlertRuleConfig]()) { result, entry in
            guard let kind = AlertKind(rawValue: entry.key) else { return } // 未知键忽略
            result[kind] = entry.value
        }
    }
}
