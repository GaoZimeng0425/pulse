import PulseCore
import SwiftUI

// MARK: - 总览指标卡(工单 P0.6-05,参考文档 §2.2 / OG 左图)

// 内容模型(MetricCardModel 及各卡 builder)在 MetricCardModel.swift;本文件只做排版。

/// 指标卡:full = 总览模块卡网格(徽章 + 名称 + chevron / 34pt 大数字 / 三列小统计 /
/// 36pt 高 44 柱 strip 走势——五张卡同形态,CPU 不特殊化(用户拍板 2026-10-20));
/// compact = 弹窗双列小卡(名称 / 大数字 + 一句补充 / 36pt 走势,与 full 同组件)。
/// 整卡可点,跳到对应指标 tab(Vitals `data-goto`)。
struct MetricCardView: View {
    enum Style {
        case full
        case compact
    }

    let model: MetricCardModel
    var style: Style = .full
    let onOpen: () -> Void

    /// 总览卡三列小统计(§2.2)。
    private static let overviewStatCount = 3

    var body: some View {
        Button(action: onOpen) {
            Group {
                switch style {
                case .full: fullBody
                case .compact: compactBody
                }
            }
            .cardShell(compact: style == .compact, padded: false)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开\(model.title)详情")
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: model.symbolName, title: model.title, tint: model.tint) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    FigureText(value: model.figureValue, unit: model.figureUnit, size: FigureSize.overview)
                    Spacer(minLength: 8)
                    if let chip = model.chip {
                        MetricChipView(chip: chip)
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.stats.prefix(Self.overviewStatCount)) { stat in
                    StatValue(label: stat.label, value: stat.value, dot: stat.dot)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            trendChart
        }
        .padding(16)
    }

    /// 底部走势(full / compact 共用同一组件,用户拍板 2026-10-17:弹窗与主窗口
    /// 同一指标必须同观感):五张卡一律 44 柱 strip(2026-10-20 撤 CPU 面积线特例)。
    private var trendChart: some View {
        StripChartView(values: model.trend, tint: model.tint, domainMax: model.domainMax)
            .frame(height: 36)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardSubHeader(symbolName: model.symbolName, title: model.title, tint: model.tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                FigureText(value: model.figureValue, unit: model.figureUnit, size: FigureSize.overviewCompact)
                Spacer(minLength: 4)
                Text(model.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 底部走势与 full 同一组件(用户拍板 2026-10-17)。
            trendChart
        }
        .padding(12)
    }
}

/// 大数字的字号令牌(DESIGN.md §Typography figure-*):每处大数字只许取这里的档位。
enum FigureSize {
    /// `{typography.figure-main}`:指标 tab 主卡。
    static let main: CGFloat = 44
    /// `{typography.figure-main-compact}`:弹窗主卡。
    static let mainCompact: CGFloat = 30
    /// `{typography.figure-stat}`:智能体页每日消耗数字卡(agent-tab/05)。
    static let stat: CGFloat = 28
    /// `{typography.figure-card}`:清理总览模块大卡(p6-cleaner/03)。
    static let card: CGFloat = 24
    /// `{typography.figure-overview}`:总览卡。
    static let overview: CGFloat = 34
    /// `{typography.figure-overview-compact}`:弹窗总览卡。
    static let overviewCompact: CGFloat = 22
    /// `{typography.figure-ring}`:环心数字。
    static let ring: CGFloat = 19
    /// `{typography.figure-ring-compact}`:弹窗环心数字。
    static let ringCompact: CGFloat = 16
}

/// 大数字(§1.2 figure):圆体加粗 + tabular + 负字距,单位约半号、基线对齐。
/// 字号只取 FigureSize 令牌。
struct FigureText: View {
    let value: String
    let unit: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.08) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .kerning(-size * 0.02)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// 图标徽章(§1.3 `.badge`):22×22,tint 16% 底,圆角 7。
struct MetricBadge: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 8))
    }
}

/// 指标卡状态 chip:统一 `ChipView` 的薄封装(ui-unify/01 五种手写 chip 归一;
/// 全尺寸 = regular,compact = inline 小号)。
struct MetricChipView: View {
    let chip: MetricCardChip
    var compact = false

    var body: some View {
        ChipView(
            text: chip.title,
            tint: chip.tint,
            profile: compact ? .inline : .regular,
            systemImage: chip.systemImage
        )
    }
}

/// 分区标题(主窗口 "此刻" / "当前最忙",SHOT1 `Worth a Look` 同款)。
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("指标卡") {
    let host = HostInfo(chipName: "Apple M4 Pro", coreCount: 12, physicalMemoryBytes: 51_539_607_552)
    let trend: [Double] = (0 ..< 44).map { Double(($0 * 7) % 40 + 10) }
    let memory = MemoryBreakdown(
        totalBytes: 51_539_607_552, appBytes: 21_000_000_000, wiredBytes: 6_000_000_000,
        compressedBytes: 9_000_000_000, cachedBytes: 8_000_000_000, pressure: .normal
    )
    let cpu = MetricCardModel.cpu(
        breakdown: CPULoadBreakdown(total: 27, user: 19, system: 8),
        load: 27,
        statistics: SeriesStatistics(count: 10, average: 36, peak: 71, minimum: 4),
        trend: trend
    )
    let mem = MetricCardModel.memory(memory, trend: [], host: host)
    return VStack(spacing: 16) {
        HStack(spacing: 16) {
            MetricCardView(model: cpu) {}
            MetricCardView(model: mem) {}
        }
        HStack(spacing: 8) {
            MetricCardView(model: cpu, style: .compact) {}
            MetricCardView(model: mem, style: .compact) {}
        }
        .frame(width: 330)
    }
    .padding(24)
    .frame(width: 720)
    .background(Surface.window)
}
