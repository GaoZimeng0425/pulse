import Foundation

// MARK: - 告警规则引擎(工单 P1-07,纯逻辑)
//
// 五元组(spec Implementation Decisions「告警」):匹配器 × 指标 × 阈值 ×
// 持续时长 × 冷却期。状态机全纯:观察序列 + 注入时刻 → 事件流,单测见
// AlertEngineTests;发送与 UI 不在这里(通知走薄封装,spec 六缝之通知发送)。
//
// 迟滞(GLOSSARY):进入需连续 `minimumConsecutiveEnter` 次越阈(有持续时长
// 要求的规则还要跨越该时长),退出需连续 `exitConsecutive` 次低于阈值∓20%——
// 阈值附近抖动的读数落进迟滞带,两侧计数都清零,不会连环轰炸。

/// 告警规则种类(五条预设,spec)。
enum AlertKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 系统 CPU 负载 >70% 持续 5 分钟(每核 tick 口径,同菜单栏数字)。
    case systemLoad
    /// 组 CPU >300% 持续 10 分钟(多核满载的组;逐组独立判定)。
    case groupCPU
    /// 新组(上轮不在场的重生 incarnation)出生窗内内存 >2GB。
    case newGroupMemory
    /// 磁盘可用(Finder「可用」口径)<20GB。
    case diskAvailable
    /// dev server 闲置 >24h(工单 08:数据源 = dev server finder 闲置环)。
    case devServerIdle

    var id: String { rawValue }

    /// 固定预设(用户可改的只有开关与阈值;持续时长/冷却期随种类定型)。
    var preset: AlertKindPreset {
        switch self {
        case .systemLoad:
            AlertKindPreset(threshold: 70, direction: .above, sustain: 300, cooldown: 600)
        case .groupCPU:
            AlertKindPreset(threshold: 300, direction: .above, sustain: 600, cooldown: 600)
        case .newGroupMemory:
            AlertKindPreset(threshold: 2 * 1_073_741_824, direction: .above, sustain: nil, cooldown: 600)
        case .diskAvailable:
            AlertKindPreset(threshold: 20 * 1_073_741_824, direction: .below, sustain: nil, cooldown: 600)
        case .devServerIdle:
            // 阈值 = 闲置秒数(默认 24h);设置页以小时编辑(AlertSettingsView)。
            AlertKindPreset(threshold: 24 * 3600, direction: .above, sustain: nil, cooldown: 600)
        }
    }

    /// 设置页/通知里的人读名。
    var title: String {
        switch self {
        case .systemLoad: "系统负载"
        case .groupCPU: "组 CPU"
        case .newGroupMemory: "新组内存"
        case .diskAvailable: "磁盘可用"
        case .devServerIdle: "dev server 闲置"
        }
    }

    /// 数据源是否已接线(设置页只展示已接线的)。五条已全部接线:dev server
    /// 闲置的喂食随工单 08 落地(dev server finder 每轮盘点)。
    var isDataSourceWired: Bool { true }

    /// 点通知直达的视图(spec:系统负载→总览、组 CPU→CPU 页、磁盘→磁盘页;
    /// 新组内存同构延伸落内存页)。
    var route: AlertRoute {
        switch self {
        case .systemLoad, .devServerIdle: .overview
        case .groupCPU: .cpu
        case .newGroupMemory: .memory
        case .diskAvailable: .disk
        }
    }
}

/// 越阈方向:above = 读数高于阈值告警(负载/CPU/内存);below = 低于阈值告警(磁盘剩余)。
enum AlertDirection: Sendable {
    case above
    case below
}

/// 一种类固定不变的预设项(阈值初值/方向/持续时长/冷却期)。
struct AlertKindPreset: Sendable {
    /// 阈值,种类原生单位(百分比规则的 %、字节规则的字节、闲置规则的秒)。
    let threshold: Double
    let direction: AlertDirection
    /// 持续时长要求(秒);nil = 无时长要求,仅看最少连续次数。
    let sustain: TimeInterval?
    /// 冷却期(秒):距上次实际发出不足冷却期,不重复发。
    let cooldown: TimeInterval
}

/// 单规则的用户可调配置(设置页逐条开关 + 阈值;即时生效并持久)。
struct AlertRuleConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var threshold: Double
}

/// 引擎一次评估所见的全部策略:用户配置(开关/阈值)叠种类预设(持续/冷却/方向)。
/// 每轮喂食时整表传入,引擎按表变化检测"设置变更"——变更即时生效(解除既有
/// 告警并重置计数,见 record)。
struct AlertEvaluationSettings: Equatable, Sendable {
    fileprivate var policies: [AlertKind: AlertRulePolicy] = [:]

    subscript(kind: AlertKind) -> AlertRulePolicy? {
        get { policies[kind] }
        set { policies[kind] = newValue }
    }

    /// 用户配置 × 预设 合成引擎策略表(设置存储的出口)。
    static func make(from configs: [AlertKind: AlertRuleConfig]) -> AlertEvaluationSettings {
        var settings = AlertEvaluationSettings()
        for kind in AlertKind.allCases {
            guard let config = configs[kind] else { continue }
            settings[kind] = AlertRulePolicy(
                isEnabled: config.isEnabled,
                threshold: config.threshold,
                sustain: kind.preset.sustain,
                cooldown: kind.preset.cooldown,
                direction: kind.preset.direction
            )
        }
        return settings
    }
}

/// 引擎眼里一条规则的可执行策略。
struct AlertRulePolicy: Equatable, Sendable {
    var isEnabled: Bool
    var threshold: Double
    var sustain: TimeInterval?
    var cooldown: TimeInterval
    var direction: AlertDirection

    init(
        isEnabled: Bool,
        threshold: Double,
        sustain: TimeInterval?,
        cooldown: TimeInterval,
        direction: AlertDirection = .above
    ) {
        self.isEnabled = isEnabled
        self.threshold = threshold
        self.sustain = sustain
        self.cooldown = cooldown
        self.direction = direction
    }
}

// MARK: - 喂食与事件

/// 组级喂食行(SystemMonitor 每轮从管线读出;name 供通知文案)。
struct AlertGroupSnapshot: Sendable {
    let id: GroupIdentity
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

/// dev server 喂食行(dev server finder 工单 08 每轮产出;闲置秒数已由
/// 闲置环判定,nil 的未闲置 server 不喂——不伪造读数)。
struct AlertDevServerSnapshot: Sendable {
    let pid: pid_t
    let name: String
    let idleSeconds: TimeInterval
}

/// 引擎喂食:采样轮(系统负载 + 全部组)、磁盘容量读数或 dev server 盘点,
/// 各自按其到达节奏推进。
enum AlertFeed: Sendable {
    case sampling(systemCPULoad: Double, groups: [AlertGroupSnapshot])
    case disk(availableBytes: Int64)
    case devServers([AlertDevServerSnapshot])
}

/// 一次实际发出的告警(fired 事件的载荷):通知与设置页"触发中"都消费它。
struct AlertOccurrence: Equatable, Hashable, Sendable {
    let kind: AlertKind
    /// 主体键:系统级规则为固定字面量,组规则为组 stableKey(含于 AlertEngine.subjectKey)。
    let subjectKey: String
    /// 主体人读名(组名;系统级为 nil)。
    let subjectName: String?
    /// 触发时刻的读数(种类原生单位)。
    let value: Double
    let firedAt: Date
}

/// 引擎输出事件:发出或解除。解除也成事件(日志"告警触发/恢复" + 应用内列表清行)。
enum AlertEvent: Equatable, Sendable {
    case fired(AlertOccurrence)
    case resolved(kind: AlertKind, subjectKey: String)
}

// MARK: - 路由(纯映射,单测钉死)

/// 点通知直达的落点(popover 无法程序化打开,深链一律落主窗口,spec 既定)。
enum AlertRoute: String, Sendable {
    case overview
    case cpu
    case memory
    case disk

    var tab: MetricTab {
        switch self {
        case .overview: .overview
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        }
    }
}

// MARK: - 状态机

/// 告警规则引擎(纯值类型):`record(喂食, 时刻, 策略表)` 推进状态、返回事件流。
/// 全部时刻由调用方注入,单测用合成时间轴(与 Sampler/SamplingScheduler 同款纪律)。
struct AlertEngine: Sendable {
    /// 进入所需最少连续越阈次数(spec:3)。
    static let minimumConsecutiveEnter = 3
    /// 退出所需连续安全次数(spec:6);安全 = 低于阈值−20%(above)/高于阈值+20%(below)。
    static let exitConsecutive = 6
    /// 迟滞量 = 阈值 × 0.2。
    static let hysteresisFraction = 0.2
    /// 新组出生窗:仅一组 incarnation 的前 `newGroupWindow` 个观察可计入
    /// newGroupMemory 规则的进入计数(窗过即解除候选资格——老组的内存增长
    /// 是正常使用,不再算"新组")。取值 = 进入次数,使"出生即超阈且稳住
    /// 三轮"恰好能走完进入路径。
    static let newGroupWindow = minimumConsecutiveEnter

    /// 系统级规则的主体键(负载/磁盘各一,永不消失)。
    private static let systemSubject = "system"
    private static let diskSubject = "disk"

    /// 单主体状态(主体 = 规则种类 × 对象键)。
    private struct SubjectState {
        var streakBreach = 0
        var streakSafe = 0
        /// 本轮连续越阈的起点(持续时长由此起算)。
        var firstBreachAt: Date?
        var phase: Phase = .idle
        /// 上次实际发出的时刻(冷却期锚点)。
        var lastFiredAt: Date?
        /// 组主体的观察序龄(出生=0,每喂一轮 +1);系统/磁盘主体不用。
        var age = 0

        enum Phase: Equatable {
            case idle
            case firing
        }
    }

    private struct SubjectRef: Hashable, Sendable {
        let kind: AlertKind
        let subjectKey: String
    }

    private var subjects: [SubjectRef: SubjectState] = [:]
    /// 是否已喂过采样轮(首轮只立基线:在场组一律按"非新组"处理,同吞吐差分
    /// 首读置零惯例——app 启动时已在跑的组不算刚出生)。
    private var hasSeededGroups = false
    /// 上次应用的策略表(变化检测 = 设置变更即时生效)。
    private var lastAppliedSettings: AlertEvaluationSettings?

    /// 推进一轮:返回本轮产生的事件(发出/解除,顺序确定)。
    mutating func record(
        _ feed: AlertFeed,
        now: Date,
        settings: AlertEvaluationSettings
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        // 设置变更(开关/阈值):立即解除全部在发告警并清计数——改动即时生效,
        // 旧的连续序列不能拿新阈值续算。冷却锚点(lastFiredAt)与新组序龄(age)
        // 保留:防轰炸语义与新组判定不因设置抖动而重置。
        if let last = lastAppliedSettings, last != settings {
            events += resolveAll()
            for (ref, var state) in subjects {
                state.streakBreach = 0
                state.streakSafe = 0
                state.firstBreachAt = nil
                state.phase = .idle
                subjects[ref] = state
            }
        }
        lastAppliedSettings = settings

        switch feed {
        case .sampling(let systemCPULoad, let groups):
            events += ingestGroups(groups, now: now, settings: settings)
            if let policy = settings[.systemLoad], policy.isEnabled {
                events += evaluate(
                    kind: .systemLoad, subjectKey: Self.systemSubject, subjectName: nil,
                    value: systemCPULoad, policy: policy, now: now,
                    ageWindow: nil
                )
            }
        case .disk(let availableBytes):
            if let policy = settings[.diskAvailable], policy.isEnabled {
                events += evaluate(
                    kind: .diskAvailable, subjectKey: Self.diskSubject, subjectName: nil,
                    value: Double(availableBytes), policy: policy, now: now,
                    ageWindow: nil
                )
            }
        case .devServers(let servers):
            events += ingestDevServers(servers, now: now, settings: settings)
        }
        return events
    }

    // MARK: dev server 喂食(工单 08):消失解除 / 闲置超阈评估

    /// dev server 主体的规范键(pid 唯一;进程退出即解除,pid 复用天然新主体)。
    static func devServerSubjectKey(pid: pid_t) -> String {
        "devserver|\(pid)"
    }

    private mutating func ingestDevServers(
        _ servers: [AlertDevServerSnapshot], now: Date, settings: AlertEvaluationSettings
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let presentKeys = Set(servers.map { Self.devServerSubjectKey(pid: $0.pid) })
        events += resolveVanished { ref in
            ref.kind == .devServerIdle && !presentKeys.contains(ref.subjectKey)
        }
        guard let policy = settings[.devServerIdle], policy.isEnabled else { return events }
        for server in servers {
            events += evaluate(
                kind: .devServerIdle,
                subjectKey: Self.devServerSubjectKey(pid: server.pid),
                subjectName: server.name,
                value: server.idleSeconds,
                policy: policy, now: now,
                ageWindow: nil
            )
        }
        return events
    }

    // MARK: 组喂食:新组判定 / 消失解除 / 组级规则评估

    private mutating func ingestGroups(
        _ groups: [AlertGroupSnapshot], now: Date, settings: AlertEvaluationSettings
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let presentKeys = Set(groups.map { Self.subjectKey(of: $0.id) })
        // 首轮喂食只立基线:在场组的新组资格直接钉在窗外(age = 窗口值),
        // app 启动时已在跑的组不算刚出生。
        let firstFeed = !hasSeededGroups
        hasSeededGroups = true

        // 组消失与 dev server 消失同一处置(共享 resolveVanished);重生即
        // 新 incarnation 从头计数。
        let resolvedGroups = resolveVanished { ref in
            Self.isGroupScoped(ref.kind) && !presentKeys.contains(ref.subjectKey)
        }
        events += resolvedGroups

        for group in groups {
            let key = Self.subjectKey(of: group.id)
            if firstFeed {
                subjects[SubjectRef(kind: .newGroupMemory, subjectKey: key), default: SubjectState()]
                    .age = Self.newGroupWindow
            }
            if let policy = settings[.groupCPU], policy.isEnabled {
                events += evaluate(
                    kind: .groupCPU, subjectKey: key, subjectName: group.name,
                    value: group.cpuPercent, policy: policy, now: now,
                    ageWindow: nil
                )
            }
            if let policy = settings[.newGroupMemory], policy.isEnabled {
                events += evaluate(
                    kind: .newGroupMemory, subjectKey: key, subjectName: group.name,
                    value: Double(group.memoryBytes), policy: policy, now: now,
                    ageWindow: Self.newGroupWindow
                )
            }
            // 序龄推进:评估用"本轮之前的观察数"(新出生=0),评估完 +1。
            for kind in [AlertKind.groupCPU, .newGroupMemory] {
                let ref = SubjectRef(kind: kind, subjectKey: key)
                subjects[ref, default: SubjectState()].age += 1
            }
        }
        return events
    }

    /// 消失主体处置(dev server 与组两处同构的共享出口):本轮不在场
    /// (谓词为真)的主体,firing 立即解除成事件,状态清空(候选态安静丢弃,
    /// 重生即新 incarnation 从头计数)。先收集后删——字典不可边遍历边变。
    private mutating func resolveVanished(
        where isVanished: (SubjectRef) -> Bool
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let gone = subjects.filter { ref, _ in isVanished(ref) }
        for (ref, state) in gone {
            if state.phase == .firing {
                events.append(.resolved(kind: ref.kind, subjectKey: ref.subjectKey))
            }
            subjects.removeValue(forKey: ref)
        }
        return events
    }

    /// static:消失谓词闭包里引用它不捕获 self(值类型互斥检查要求)。
    private static func isGroupScoped(_ kind: AlertKind) -> Bool {
        kind == .groupCPU || kind == .newGroupMemory
    }

    /// 组主体的规范键(stableKey 逐字节复现 P0 前缀约定)。
    static func subjectKey(of id: GroupIdentity) -> String {
        id.stableKey
    }

    // MARK: 单主体状态机推进

    /// 评估一个(规则, 主体, 读数)。ageWindow 非 nil 时仅当主体序龄 < 窗口才
    /// 计入进入 streak(newGroupMemory 的出生窗:窗过即解除候选资格——老组的
    /// 内存增长是正常使用,不再算"新组");nil = 无资格门(系统/组 CPU/磁盘)。
    private mutating func evaluate(
        kind: AlertKind,
        subjectKey: String,
        subjectName: String?,
        value: Double,
        policy: AlertRulePolicy,
        now: Date,
        ageWindow: Int?
    ) -> [AlertEvent] {
        let ref = SubjectRef(kind: kind, subjectKey: subjectKey)
        var state = subjects[ref] ?? SubjectState()
        var events: [AlertEvent] = []

        let breach: Bool
        let safe: Bool
        switch policy.direction {
        case .above:
            breach = value > policy.threshold
            safe = value < policy.threshold * (1 - Self.hysteresisFraction)
        case .below:
            breach = value < policy.threshold
            safe = value > policy.threshold * (1 + Self.hysteresisFraction)
        }

        if breach {
            // 带内(safe == false 且非 breach)两侧都不计;越阈侧推进进入、清退出。
            let countsTowardEnter = ageWindow.map { state.age < $0 } ?? true
            if countsTowardEnter {
                if state.streakBreach == 0 { state.firstBreachAt = now }
                state.streakBreach += 1
            } else {
                state.streakBreach = 0
                state.firstBreachAt = nil
            }
            state.streakSafe = 0
        } else if safe {
            state.streakSafe += 1
            state.streakBreach = 0
            state.firstBreachAt = nil
        } else {
            // 迟滞带内:两侧计数都清零——抖动读数不推进任何方向(防轰炸核心)。
            state.streakBreach = 0
            state.firstBreachAt = nil
            state.streakSafe = 0
        }

        // 退出:在发 + 连续 6 次安全侧。
        if state.phase == .firing, state.streakSafe >= Self.exitConsecutive {
            state.phase = .idle
            state.streakBreach = 0
            state.streakSafe = 0
            state.firstBreachAt = nil
            events.append(.resolved(kind: kind, subjectKey: subjectKey))
        }

        // 进入:未在发 + 连续 ≥3 次越阈 + 持续时长满足 + 冷却期已过。
        if state.phase == .idle,
           state.streakBreach >= Self.minimumConsecutiveEnter,
           sustainedEnough(state: state, now: now, policy: policy),
           cooledDown(state: state, now: now, policy: policy) {
            state.phase = .firing
            state.streakSafe = 0
            state.lastFiredAt = now
            events.append(.fired(AlertOccurrence(
                kind: kind,
                subjectKey: subjectKey,
                subjectName: subjectName,
                value: value,
                firedAt: now
            )))
        }

        subjects[ref] = state
        return events
    }

    /// 持续时长:首越阈至今 ≥ sustain(nil = 不限,仅看连续次数)。
    private func sustainedEnough(state: SubjectState, now: Date, policy: AlertRulePolicy) -> Bool {
        guard let sustain = policy.sustain, let first = state.firstBreachAt else { return true }
        return now.timeIntervalSince(first) >= sustain
    }

    /// 冷却期:距上次实际发出 ≥ cooldown(从未发过 = 放行)。
    private func cooledDown(state: SubjectState, now: Date, policy: AlertRulePolicy) -> Bool {
        guard let last = state.lastFiredAt else { return true }
        return now.timeIntervalSince(last) >= policy.cooldown
    }

    /// 全量解除(设置变更用):在发的发 resolved,其余安静。
    private mutating func resolveAll() -> [AlertEvent] {
        subjects.compactMap { ref, state in
            state.phase == .firing ? .resolved(kind: ref.kind, subjectKey: ref.subjectKey) : nil
        }
    }
}
