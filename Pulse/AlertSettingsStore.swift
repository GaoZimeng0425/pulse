import Foundation
import Observation

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
    /// 授权已请求标记键(跨启动:确保系统通知授权"首次开启才请求"只发生一次)。
    static let authorizationRequestedKey = "alertAuthorizationRequested"

    /// 当前配置(缺省 = 预设阈值 + 全关;首次开启任一规则才请求通知授权)。
    private(set) var configs: [AlertKind: AlertRuleConfig]

    private let persist: ([AlertKind: AlertRuleConfig]) -> Void
    private let persistAuthorizationFlag: (Bool) -> Void

    /// 任一规则开着(授权时序:从假到真的迁移点请求授权)。
    var isAnyEnabled: Bool {
        configs.values.contains(where: \.isEnabled)
    }

    var hasRequestedAuthorization: Bool {
        authorizationRequested
    }

    private var authorizationRequested: Bool

    /// 注入读写闭包的构造(测试 / 预览)。
    init(
        load: () -> [AlertKind: AlertRuleConfig],
        persist: @escaping ([AlertKind: AlertRuleConfig]) -> Void,
        loadAuthorizationFlag: () -> Bool,
        persistAuthorizationFlag: @escaping (Bool) -> Void
    ) {
        self.configs = Self.mergingPresets(load())
        self.persist = persist
        self.authorizationRequested = loadAuthorizationFlag()
        self.persistAuthorizationFlag = persistAuthorizationFlag
    }

    /// 生产构造:UserDefaults(标准库);测试注入独立 suite。
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            load: { Self.decode(defaults.data(forKey: Self.storageKey)) },
            persist: { configs in
                defaults.set(Self.encode(configs), forKey: Self.storageKey)
            },
            loadAuthorizationFlag: { defaults.bool(forKey: Self.authorizationRequestedKey) },
            persistAuthorizationFlag: { defaults.set($0, forKey: Self.authorizationRequestedKey) }
        )
    }

    // MARK: - 读写

    /// 单规则配置(未配置过的种类回落预设:阈值 = 预设,开关 = 关)。
    func config(for kind: AlertKind) -> AlertRuleConfig {
        configs[kind] ?? AlertRuleConfig(isEnabled: false, threshold: kind.preset.threshold)
    }

    /// 开关某规则(设置页 Toggle;改动即落盘)。
    func setEnabled(_ enabled: Bool, for kind: AlertKind) {
        var config = self.config(for: kind)
        config.isEnabled = enabled
        configs[kind] = config
        persist(configs)
    }

    /// 改阈值(设置页输入框;改动即落盘即生效)。非正数拒绝(除零/无意义防线)。
    func setThreshold(_ threshold: Double, for kind: AlertKind) {
        guard threshold > 0, threshold.isFinite else { return }
        var config = self.config(for: kind)
        config.threshold = threshold
        configs[kind] = config
        persist(configs)
    }

    /// 标记授权已请求过(跨启动只此一次)。
    func markAuthorizationRequested() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        persistAuthorizationFlag(true)
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
        guard let data else { return [:] }
        guard let raw = try? JSONDecoder().decode([String: AlertRuleConfig].self, from: data) else {
            return [:]
        }
        return raw.reduce(into: [AlertKind: AlertRuleConfig]()) { result, entry in
            guard let kind = AlertKind(rawValue: entry.key) else { return } // 未知键忽略
            result[kind] = entry.value
        }
    }
}
