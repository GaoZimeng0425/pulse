import Foundation
import Observation
import PulseCore

/// 蓝牙卡的呈现态:用户开关 × 系统授权折叠成四态,视图只认它(纯派生,单测钉死)。
enum BluetoothAccessState: Equatable, Sendable {
    /// 用户未开启(默认):卡片给「开启」按钮,全链路不碰蓝牙 API。
    case disabled
    /// 已开启但系统未问过(首次 / 重装换 cdhash 后 TCC 视为陌生 app):等用户点
    /// 「授权」,启动路径绝不自动弹。
    case needsAuthorization
    /// 系统已拒(或受限):只提示去系统设置,绝不自动重试。
    case denied
    /// 已开启且已授权:正常采集与展示。
    case ready
}

/// 蓝牙功能模块(工单 p2-sensors/06;ADR-0003 MonitorFeature):三源电量合并
/// 传感器(ADR-0004,可见 30s 档 + 可见性门控,不可见完全停)经 sensorDrivers
/// 登记;外设 tab 蓝牙区与弹窗蓝牙紧凑组直读 `reading`。读失败交付上次好值。
///
/// 权限原则(用户明示;CODING_STANDARDS「权限 / TCC 纪律」;2026-10-24 纠偏——
/// 此前闸只看可见性,点开菜单栏弹窗就碰 IOBluetooth,每次重装都弹权限框):
/// 授权型能力**默认关 + 惰性启动**,设置开关 / 卡片按钮是唯一触发源,系统弹窗只
/// 出现在用户动作那一刻;启动路径与可见性切换只做**静默**授权读取,绝不碰会弹窗
/// 的 API;被拒只渲染提示,绝不自动重试。采集闸 = 可见 ∧ 已开启 ∧ 已授权。
@Observable
@MainActor
final class BluetoothFeature: MonitorFeature {
    /// UserDefaults 键:用户开关(Bool,默认关)。键名即持久化契约,勿改。
    static let enabledStorageKey = "settings.bluetoothEnabled"

    /// 最近一次交付,LastGood 语义;nil = 从未读到(蓝牙栈不可用)→ 占位。
    private(set) var reading: BluetoothReading?
    /// 用户开关(持久)。
    private(set) var isEnabled: Bool
    /// 最近一次静默读到的系统授权态。
    private(set) var authorization: BluetoothAuthorization

    private let provider: BluetoothSensorProvider
    private let access: any BluetoothAccessControl
    private let persistEnabled: (Bool) -> Void
    /// 最近一次可见性折算(弹窗 ∨ 外设页)。
    private var isVisible = false

    /// 注入构造(测试 / 预览):开关读写闭包 + 授权控制(AlertSettingsStore 同款注入口)。
    init(
        source: any BluetoothSource,
        access: any BluetoothAccessControl,
        loadEnabled: () -> Bool,
        persistEnabled: @escaping (Bool) -> Void
    ) {
        provider = BluetoothSensorProvider(source: source)
        self.access = access
        self.persistEnabled = persistEnabled
        isEnabled = loadEnabled()
        // 启动路径只静默读:重装后开关仍开而授权未决,也只是等用户点,不弹。
        authorization = access.authorization()
    }

    /// 生产构造:Live 授权控制 + UserDefaults 持久。
    convenience init(source: any BluetoothSource, defaults: UserDefaults = .standard) {
        self.init(
            source: source,
            access: LiveBluetoothAccessControl(),
            loadEnabled: { defaults.bool(forKey: Self.enabledStorageKey) },
            persistEnabled: { defaults.set($0, forKey: Self.enabledStorageKey) }
        )
    }

    /// 卡片呈现态:开关优先于授权态(没开 = 一切免谈)。
    var accessState: BluetoothAccessState {
        guard isEnabled else { return .disabled }
        switch authorization {
        case .allowed: return .ready
        case .notDetermined: return .needsAuthorization
        case .denied, .restricted: return .denied
        }
    }

    /// 是否正在采集(闸开);诊断与单测读。
    var isCollecting: Bool {
        provider.isCollecting
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            // 带新鲜度:stale 重投跳过(读失败保显示 = 字段已持旧值,审计④)。
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    guard case let .fresh(reading) = delivery else { return }
                    self.reading = reading
                }
            },
        ]
    }

    /// 可见性输入:弹窗 ∨ 外设页(p2-sensors/05 立的 peripheralsPage 旗标在此消费;与
    /// GPU/传感器/排行闸分旗,ADR-0006 语义不混)。进场顺带静默刷新授权(用户可能
    /// 刚在系统设置里改过),不请求。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        isVisible = visibility.popover || visibility.peripheralsPage
        refreshAuthorization()
    }

    /// 用户开关(设置页 Toggle / 卡片「开启」按钮):开 = 用户动作那一刻,授权未决
    /// 即请求——这是系统弹窗出现的两处入口之一;关 = 立即停采,不再碰蓝牙。
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        persistEnabled(enabled)
        refreshAuthorization()
        if enabled, authorization == .notDetermined {
            requestAuthorization()
        }
    }

    /// 用户点「授权」(已开启但未决,典型是重装换签名后):显式请求,系统答复后回读
    /// 并按结果开闸 / 转被拒态。被拒态下无效——系统不会再弹,只能去系统设置。
    func requestAuthorization() {
        guard isEnabled, authorization == .notDetermined else { return }
        access.requestAccess { [weak self] in
            Task { @MainActor in
                self?.refreshAuthorization()
            }
        }
    }

    /// 静默回读授权态并重算闸(回前台 / 进场 / 请求回调都走这里)。
    func refreshAuthorization() {
        authorization = access.authorization()
        applyGate()
    }

    /// 闸 = 可见 ∧ 已开启 ∧ 已授权;关闸时 provider 一个源都不碰。
    private func applyGate() {
        provider.setVisible(isVisible && accessState == .ready)
    }
}
