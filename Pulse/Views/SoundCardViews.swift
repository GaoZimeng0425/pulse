import PulseCore
import SwiftUI

// MARK: - 外设页声音卡(p2-sensors/05;行样式 ui-unify 追改 2026-11-09)

// 数据形状(标量折算/钳位)在核心层 SoundModel(纯逻辑,单测覆盖);本文件
// 只做 SwiftUI 外观——纯展示卡(设备/音量/静音),弹窗(紧凑)与主窗口共用,
// 走预览 + 手动验收。控制交互刻意不做(spec 拍板:声音为非重点家族)。

/// 声音卡:默认输出设备一行实体行(CardEntityRow:喇叭图标 + 设备名 + 音量 meter),
/// 与同页蓝牙设备行同一语言;meter 定宽(RowMetrics),不再随主窗口宽度拉满。
/// 静音时音量值保留显示(mute 是独立属性,解除静音不用重学位置),图标换斜杠喇叭
/// 并转灰;无设备(读失败/无音频)安静占位。
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
                deviceRow(reading, name: name)
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

    private func deviceRow(_ reading: SoundReading, name: String) -> some View {
        let muted = reading.isMuted == true
        return CardEntityRow(
            systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            tint: muted ? Surface.inactive : Metric.sound.accentColor,
            name: name,
            sub: muted ? "默认输出 · 静音" : "默认输出",
            compact: isCompact
        ) {
            if let percent = reading.volumePercent {
                MeterBar(
                    fraction: min(max(percent / 100, 0), 1),
                    tint: muted ? Surface.inactive : Metric.sound.accentColor
                )
                .frame(width: RowMetrics.meterWidth(compact: isCompact))
                CardRowValue(
                    text: "\(Int(percent.rounded()))%",
                    minWidth: CardRowWidth.percentValue,
                    style: .primary,
                    fontSize: RowMetrics.valueFontSize(compact: isCompact),
                    weight: .semibold
                )
            } else {
                Text("设备不控音量")
                    .font(.system(size: RowMetrics.subFontSize(compact: isCompact)))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
