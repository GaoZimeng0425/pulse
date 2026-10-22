import PulseCore
import SwiftUI

// MARK: - 外设页蓝牙卡(p2-sensors/06)

// 三源合并(地址规整/三级匹配/歧义即弃/缓存 1→100)在核心层 BluetoothModel
// (纯逻辑,单测覆盖);本文件只做 SwiftUI 外观——设备表行(名称/连接态/电量/
// 信号),弹窗(紧凑)与主窗口共用,走预览 + 手动验收。

/// 蓝牙设备卡:每台一行(名称 + 连接点 + 电量 meter + RSSI),已连接置顶;
/// 无设备/蓝牙栈不可用安静占位。
struct BluetoothDevicesCardView: View {
    let reading: BluetoothReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "antenna.radiowaves.left.and.right",
                title: "蓝牙",
                tint: Metric.bluetooth.accentColor,
                note: note
            )
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
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private var note: String? {
        guard let devices = reading?.devices, !devices.isEmpty else { return nil }
        let connected = devices.filter(\.isConnected).count
        return "\(devices.count) 台设备 · \(connected) 台已连接"
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
