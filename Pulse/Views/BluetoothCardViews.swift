import AppKit
import PulseCore
import SwiftUI

// MARK: - 外设页蓝牙卡(p2-sensors/06)

// 三源合并(地址规整/三级匹配/歧义即弃/缓存 1→100)在核心层 BluetoothModel
// (纯逻辑,单测覆盖);本文件只做 SwiftUI 外观——设备表行(名称/连接态/电量/
// 信号),弹窗(紧凑)与主窗口共用,走预览 + 手动验收。

/// 蓝牙设备卡:每台一行(名称 + 连接点 + 电量 meter + RSSI),已连接置顶;
/// 无设备/蓝牙栈不可用安静占位。授权型能力(权限原则):未开启 / 未授权 / 被拒
/// 三态各给一句话 + 一个 `.link` 动作——开启与授权按钮就是系统弹窗出现的那一刻,
/// 被拒只给系统设置入口、绝不自动重试。
struct BluetoothDevicesCardView: View {
    let reading: BluetoothReading?
    /// 开关 × 授权折叠的四态(BluetoothFeature.accessState),视图只认它。
    var accessState: BluetoothAccessState = .ready
    var isCompact = false
    /// 用户动作出口:开启(卡片按钮)/ 重新授权(重装换签名后)。
    var onEnable: () -> Void = {}
    var onAuthorize: () -> Void = {}

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
                if let devices = reading?.devices, !devices.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(devices.prefix(isCompact ? 6 : devices.count)) { device in
                            row(device)
                        }
                    }
                } else {
                    CardEmptyState(title: "蓝牙不可用或无设备")
                }
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
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

    private func row(_ device: BluetoothDeviceRow) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(device.isConnected ? Metric.bluetooth.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(device.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let percent = device.batteryPercent {
                MeterBar(
                    fraction: min(max(Double(percent) / 100, 0), 1),
                    tint: Metric.bluetooth.accentColor
                )
                .frame(width: isCompact ? 44 : 64)
                Text("\(percent)%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            } else {
                Text("电量未知")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(rssiText(device.rssi))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    private func rssiText(_ rssi: Int?) -> String {
        guard let rssi else { return "—" }
        return "\(rssi) dBm"
    }
}
