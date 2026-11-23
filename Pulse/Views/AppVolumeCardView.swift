import AppKit
import PulseCore
import SwiftUI

// MARK: - 每应用音量卡(app-volume/01)

//
// 数据形状(曲线/归并/载荷)在 PulseCore AppVolumeModel(纯逻辑,单测覆盖);
// 接管编排(reconcile/看门狗)在 AppVolumeFeature;本文件只做 SwiftUI 外观。
// 行 = CardEntityRow 变体:真 app 图标 + 名称 + 滑块(RowMetrics.meterWidth 定宽,
// 与读数行 meter 同一节奏)+ 百分比 + 静音钮。100% 不接管 = 原声直通(mixbar 语义)。

/// 混音卡:外设页声音卡之下,正在出声/在跑的音频应用一行一滑块。
struct AppVolumeCardView: View {
    let feature: AppVolumeFeature
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "slider.horizontal.3",
                title: "每应用音量",
                tint: Metric.sound.accentColor,
                note: "100% = 原声直通"
            )
            if !feature.hasOutputDevice {
                CardEmptyState(title: "暂无输出设备")
            } else if feature.entries.isEmpty {
                CardEmptyState(
                    title: "等待应用播放声音",
                    detail: "出声的应用会出现在这里;首次拖动滑块会请求一次系统音频捕获授权"
                )
            } else {
                VStack(spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                    ForEach(feature.entries) { entry in
                        AppVolumeRowView(
                            entry: entry,
                            icon: feature.icons[entry.id],
                            compact: isCompact,
                            onVolume: { feature.setVolume($0, for: entry.id) },
                            onToggleMute: { feature.toggleMute(for: entry.id) }
                        )
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }
}

/// 一行:app 图标 + 名称/副文 + 音量滑块 + 百分比 + 静音钮。
private struct AppVolumeRowView: View {
    let entry: AppVolumeEntry
    let icon: NSImage?
    let compact: Bool
    let onVolume: (Double) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        CardEntityRow(
            systemImage: "app.dashed",
            image: icon,
            tint: entry.isMuted ? Surface.inactive : Metric.sound.accentColor,
            name: entry.name,
            sub: sub,
            compact: compact
        ) {
            HStack(spacing: RowMetrics.spacing(compact: compact)) {
                Slider(value: volume, in: 0 ... 1)
                    .tint(Metric.sound.accentColor)
                    .frame(width: RowMetrics.meterWidth(compact: compact))
                    .help(helpText)
                muteButton
                CardRowValue(
                    text: "\(Int((entry.volume * 100).rounded()))%",
                    minWidth: CardRowWidth.percentValue,
                    style: .primary,
                    fontSize: RowMetrics.valueFontSize(compact: compact),
                    weight: .semibold
                )
            }
        }
    }

    private var volume: Binding<Double> {
        Binding(
            get: { entry.volume },
            set: { onVolume($0) }
        )
    }

    private var sub: String? {
        if entry.error != nil {
            return "接管失败 · 重拖滑块重试"
        }
        if entry.isMuted {
            return "静音"
        }
        if entry.isControlled {
            return "接管中"
        }
        return entry.isPlaying ? "出声中" : nil
    }

    private var helpText: String {
        // 完整错误只在悬停给(行的副文保持一句短话);正常态给语义提示。
        if let error = entry.error {
            return error
        }
        return "拖动即接管该应用的音量;滑回 100% 恢复原始路由"
    }

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: IconSize.inline, weight: .medium))
                .frame(
                    width: RowMetrics.spacing(compact: compact) * 2,
                    height: RowMetrics.spacing(compact: compact) * 2
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(entry.isMuted ? Metric.sound.accentColor : Surface.inactive)
        .help(entry.isMuted ? "取消静音" : "静音该应用")
    }
}

#Preview("有应用") {
    let feature = AppVolumeFeature.inert()
    AppVolumeCardView(feature: feature)
        .padding()
        .frame(width: 420)
}
