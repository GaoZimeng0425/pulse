import PulseCore
import SwiftUI

// MARK: - 外设页声音卡(p2-sensors/05)

// 数据形状(标量折算/钳位)在核心层 SoundModel(纯逻辑,单测覆盖);本文件
// 只做 SwiftUI 外观——纯展示卡(设备/音量/静音),弹窗(紧凑)与主窗口共用,
// 走预览 + 手动验收。控制交互刻意不做(spec 拍板:声音为非重点家族)。

/// 声音卡:默认输出设备 + 音量 meter + 静音态;无设备(读失败/无音频)安静占位。
/// 静音时音量值保留显示(mute 是独立属性,解除静音不用重学位置)。
struct SoundCardView: View {
    let reading: SoundReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "speaker.wave.2.fill",
                title: "声音",
                tint: Metric.sound.accentColor,
                note: note
            )
            if let reading, let name = reading.deviceName, !name.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    volumeRow(reading)
                }
            } else {
                CardEmptyState(title: "暂无输出设备")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private var note: String? {
        guard let reading else { return nil }
        if reading.isMuted == true {
            return "静音"
        }
        return reading.volumePercent.map { "\(Int($0.rounded()))%" }
    }

    private func volumeRow(_ reading: SoundReading) -> some View {
        HStack(spacing: 8) {
            Image(systemName: reading.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(reading.isMuted == true ? .secondary : Metric.sound.accentColor)
            if let percent = reading.volumePercent {
                MeterBar(
                    fraction: min(max(percent / 100, 0), 1),
                    tint: Metric.sound.accentColor
                )
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            } else {
                Text("设备不控音量")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
