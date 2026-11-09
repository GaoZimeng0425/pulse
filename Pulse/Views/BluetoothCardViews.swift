import AppKit
import PulseCore
import SwiftUI

// MARK: - 外设页蓝牙卡(p2-sensors/06;行样式 ui-unify 追改 2026-11-09)

// 三源合并(地址规整/三级匹配/歧义即弃/缓存 1→100)与设备类型识别(CoD 主类 +
// BLE HID usage 回退)在核心层 BluetoothModel(纯逻辑,单测覆盖);本文件只做
// SwiftUI 外观——设备实体行(CardEntityRow:类型图标 + 名称 + RSSI 副文 + 电量
// meter),弹窗(紧凑)与主窗口共用,走预览 + 手动验收。

/// 蓝牙设备卡:每台一行,已连接置顶;图标亮 = 已连接、灰 = 未连接(代替旧状态圆点)。
/// 电量读不到整块留空(未知值安静原则,DESIGN.md「卡内行两形态边界」);RSSI 有读数
/// 进名称副文。无设备/蓝牙栈不可用安静占位;开闸后首轮在途显示「正在读取」
/// (ui-unify 追改:此前空窗误显示「不可用」,用户实报"连三台一台不显示")。
/// 授权型能力(权限原则):未开启 / 未授权 / 被拒三态各给一句话 + 一个 `.link`
/// 动作——开启与授权按钮就是系统弹窗出现的那一刻,被拒只给系统设置入口、绝不自动重试。
struct BluetoothDevicesCardView: View {
    let reading: BluetoothReading?
    /// 开关 × 授权折叠的四态(BluetoothFeature.accessState),视图只认它。
    var accessState: BluetoothAccessState = .ready
    var isCompact = false
    /// 开闸后首轮快照在途(BluetoothFeature.isAwaitingRead):画「正在读取」而非空态。
    var isAwaitingRead = false
    /// 用户动作出口:开启(卡片按钮)/ 重新授权(重装换签名后)。
    var onEnable: () -> Void = {}
    var onAuthorize: () -> Void = {}

    /// 弹窗紧凑档行数上限(超出补「…共 N 台」尾行,与容器卡 / 快照卡同款;
    /// 主窗口不截)。
    private static let compactLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "antenna.radiowaves.left.and.right",
                title: "蓝牙",
                tint: Metric.bluetooth.accentColor,
                note: accessState == .ready ? note : nil
            )
            switch accessState {
            case .disabled:
                CardEmptyState(
                    title: "蓝牙监控未开启",
                    detail: "开启后读取已配对设备的连接状态与电量;首次会请求一次蓝牙权限,只在你点击时弹出",
                    actionTitle: "开启蓝牙监控",
                    action: onEnable
                )
            case .needsAuthorization:
                CardEmptyState(
                    title: "需要蓝牙权限",
                    detail: "系统尚未确认(应用更新后会重新询问);授权框只在你点击时弹出",
                    actionTitle: "授权蓝牙",
                    action: onAuthorize
                )
            case .denied:
                CardEmptyState(
                    title: "蓝牙权限已拒绝",
                    detail: "在 系统设置 › 隐私与安全性 › 蓝牙 里允许 Pulse,回到这里自动恢复;Pulse 不会反复请求",
                    actionTitle: "打开系统设置",
                    action: openBluetoothPrivacySettings
                )
            case .ready:
                devicesContent
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var devicesContent: some View {
        if let devices = reading?.devices, !devices.isEmpty {
            VStack(spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                ForEach(devices.prefix(isCompact ? Self.compactLimit : devices.count)) { device in
                    row(device)
                }
                if isCompact, devices.count > Self.compactLimit {
                    overflowLine(devices.count)
                }
            }
        } else if isAwaitingRead {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else {
            CardEmptyState(title: "蓝牙不可用或无设备")
        }
    }

    private var note: String? {
        guard let devices = reading?.devices, !devices.isEmpty else { return nil }
        let connected = devices.filter(\.isConnected).count
        return "\(devices.count) 台设备 · \(connected) 台已连接"
    }

    /// 隐私面板深链(NemoNotch PermissionPane 实证的 anchor:Privacy_Bluetooth)。
    private func openBluetoothPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func overflowLine(_ total: Int) -> some View {
        Text("…共 \(total) 台")
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private func row(_ device: BluetoothDeviceRow) -> some View {
        let connected = device.isConnected
        return CardEntityRow(
            systemImage: Self.symbol(for: device.kind),
            tint: connected ? Metric.bluetooth.accentColor : Surface.inactive,
            name: device.name,
            sub: subText(device, connected: connected),
            compact: isCompact
        ) {
            if let percent = device.batteryPercent {
                MeterBar(
                    fraction: min(max(Double(percent) / 100, 0), 1),
                    tint: Metric.bluetooth.accentColor
                )
                .frame(width: RowMetrics.meterWidth(compact: isCompact))
                CardRowValue(
                    text: "\(percent)%",
                    minWidth: CardRowWidth.percentValue,
                    style: .primary,
                    fontSize: RowMetrics.valueFontSize(compact: isCompact),
                    weight: .semibold
                )
            }
        }
        .accessibilityLabel(
            "\(device.name),\(connected ? "已连接" : "未连接")\(device.batteryPercent.map { ",电量 \($0)%" } ?? "")"
        )
    }

    /// RSSI 有效(负 dBm)进副文;未连接且无 RSSI 时给「未连接」二字补状态(图标
    /// 已灰,文字兜个底)。已连接无 RSSI = 不写(未知值安静原则)。
    private func subText(_ device: BluetoothDeviceRow, connected: Bool) -> String? {
        if let rssi = device.rssi {
            return "\(rssi) dBm"
        }
        return connected ? nil : "未连接"
    }

    /// 类型 → 图标(DESIGN.md 实体行;unknown = 通用蓝牙图标,不硬猜)。
    private static func symbol(for kind: BluetoothDeviceKind) -> String {
        switch kind {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "hand.tap"
        case .audio: "headphones"
        case .phone: "phone"
        case .gamepad: "gamecontroller"
        case .unknown: "antenna.radiowaves.left.and.right"
        }
    }
}

#Preview("蓝牙卡 · 两档") {
    let reading = BluetoothReading(
        devices: [
            BluetoothDeviceRow(
                name: "Hack59-2", address: "ca-d2-10-9d-83-1e", isConnected: true,
                batteryPercent: nil, rssi: nil, kind: .keyboard
            ),
            BluetoothDeviceRow(
                name: "REDMI 头戴降噪耳机", address: "00-13-d6-5e-90-ba", isConnected: true,
                batteryPercent: 63, rssi: -26, kind: .audio
            ),
            BluetoothDeviceRow(
                name: "子蒙’s Magic Trackpad", address: "d4-57-63-5d-bf-6b", isConnected: true,
                batteryPercent: 48, rssi: nil, kind: .trackpad
            ),
            BluetoothDeviceRow(
                name: "Xiaomi Pad 9 Pro Max", address: "08-b3-39-48-01-a6", isConnected: false,
                rssi: nil, kind: .phone
            ),
        ]
    )
    return VStack(spacing: 16) {
        BluetoothDevicesCardView(reading: reading, isCompact: false)
        BluetoothDevicesCardView(reading: reading, isCompact: true)
            .frame(width: 336)
    }
    .padding()
    .background(Surface.window)
}

#Preview("蓝牙卡 · 等待/空态") {
    VStack(spacing: 16) {
        BluetoothDevicesCardView(reading: nil, isAwaitingRead: true)
        BluetoothDevicesCardView(reading: nil)
    }
    .padding()
    .background(Surface.window)
}
