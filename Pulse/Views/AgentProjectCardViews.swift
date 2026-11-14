import PulseCore
import SwiftUI

// MARK: - 项目大卡族(agent-tab/07 重设计;自 AgentUsageViews.swift 拆出)

//
// 07 重设计(2026-11-14 用户实报「项目卡有点丑」):06 版五层四条分隔线 +
// 两条独立分段条 + 满屏 micro 灰字,信息平铺无主次。终态 = 三段式:
// 头(状态图标 + 名 + 在跑 chip / 占比)+ 主数值 → 五格读数 → 构成两行
// (模型 / 来源,标签列对齐)→ 唯一一条分隔线 → 带图标的元信息尾行。

/// 项目展开/收起末行:排行截断末行(`RankingOverflowRow`)同款视觉配方
/// (11 medium secondary + chevron + 悬停 primary 5% 圆角 8),文案按项目口径
/// (「另 N 个项目」/「只看前 10 个」)。
struct AgentProjectOverflowRow: View {
    let isExpanded: Bool
    let hiddenCount: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isHovering ? Color.primary.opacity(0.05) : Color.clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isExpanded ? "收起,只看前 10 个项目" : "展开全部项目")
    }

    private var label: String {
        isExpanded ? "收起,只看前 10 个" : "显示全部(另 \(hiddenCount) 个项目)"
    }
}

// MARK: - 项目卡响应式网格(agent-tab/06 三度修正)

/// 项目大卡响应式网格:列数 = 容器实宽容纳的最多列(单卡保底 520,上限 3),
/// 逐行 HStack——**行内等高**、末行不满自动满宽;容器多窄都单列 100%(不走
/// GridItem minimum,规避 flexible 硬下限在窄容器溢出裁剪的前案)。
struct AgentProjectCardGrid: View {
    /// 单卡保底宽(低于此宁可少一列——呼吸感是 06 追补的实报教训)。
    private static let minimumCardWidth: CGFloat = 520
    private static let spacing: CGFloat = 12
    private static let maximumColumns = 3

    let projects: [AgentProjectSummary]
    let windowDays: Int

    /// 初值 1:窄窗/弹窗首帧即正确,宽度变化后纠正。
    @State private var columnCount = 1

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row) { project in
                        AgentProjectCardView(project: project, windowDays: windowDays)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .onGeometryChange(for: Int.self) { proxy in
            let perColumn = Self.minimumCardWidth + Self.spacing
            return min(Self.maximumColumns, max(1, Int((proxy.size.width + Self.spacing) / perColumn)))
        } action: { newValue in
            if newValue != columnCount {
                columnCount = newValue
            }
        }
    }

    /// 按列数分行(不足列的末行自动满宽——HStack 内卡 maxWidth ∞)。
    private var rows: [[AgentProjectSummary]] {
        guard columnCount > 1 else { return projects.map { [$0] } }
        return stride(from: 0, to: projects.count, by: columnCount).map {
            Array(projects[$0 ..< min($0 + columnCount, projects.count)])
        }
    }
}

// MARK: - 项目大卡

/// 项目一张宽卡(cardHigh 底、圆角 10、内距 16;段间 16、段内 8)。
struct AgentProjectCardView: View {
    let project: AgentProjectSummary
    let windowDays: Int

    /// 构成行标签列宽 = `{layout.row-label-short}` 36(两汉字「模型 / 来源」)。
    private static let compositionLabelWidth: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                header
                valueRow
            }
            bucketsRow
            compositionBlock
            Divider().padding(.horizontal, -16)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: 段 1:头 + 主数值

    /// 状态图标(在跑 / 今天 = 页 accent,静了 = inactive)+ 名 + 在跑 chip;右占比。
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? agentsAccent : Surface.inactive)
            Text(project.project)
                .font(.system(size: 14.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if project.liveSessions > 0 {
                ChipView(
                    text: "在跑 \(project.liveSessions)",
                    tint: Surface.positive,
                    profile: .inline,
                    help: "会话快照里该项目正在运行的会话数"
                )
            }
            Spacer(minLength: 8)
            Text("占 \(percentText(project.share))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var isActive: Bool {
        project.liveSessions > 0 || project.idleDays == 0
    }

    /// 主数值(figure-card 24)+ 环比。
    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let figure = agentTokenFigure(project.total)
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.card)
            AgentDeltaText(label: nil, delta: project.delta)
        }
    }

    // MARK: 段 2:五格读数(tokscale 对齐)

    /// 倍率 = 缓存读 ÷ 净(输入+输出),衡量缓存吃掉多少重复读取。
    private var bucketsRow: some View {
        HStack(alignment: .top, spacing: 16) {
            bucket("Input", agentTokenText(project.inputTokens))
            bucket("Output", agentTokenText(project.outputTokens))
            bucket("Cache R", agentTokenText(project.cacheReadTokens))
            bucket("Cache W", agentTokenText(project.cacheWriteTokens))
            bucket("Cache×", project.cacheMultiplier.map { String(format: "%.1fx", $0) } ?? "—")
        }
    }

    private func bucket(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 段 3:构成(模型 / 来源两行,标签列对齐)

    private var compositionBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !project.models.isEmpty {
                compositionRow(
                    label: "模型",
                    entries: project.models.enumerated().map { index, model in
                        (
                            name: AgentUsageWindow.modelDisplayName(model.name),
                            share: model.share,
                            tint: AgentModelTint.tint(at: index)
                        )
                    }
                )
            }
            compositionRow(
                label: "来源",
                entries: [
                    (name: "Claude", share: project.claudeShare, tint: AgentModelTint.harness(.claude)),
                    (name: "ZCode", share: 1 - project.claudeShare, tint: AgentModelTint.harness(.zcode)),
                ]
            )
        }
    }

    /// 一行构成:左标签列 + 右(分段条 → 色点图例)。份额为 0 的项不进图例。
    private func compositionRow(
        label: String,
        entries: [(name: String, share: Double, tint: Color)]
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Self.compositionLabelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                AgentSegmentedBar(segments: entries.map { (fraction: $0.share, tint: $0.tint) })
                    .padding(.top, 5) // 条中线对齐标签 11pt 文字中线
                HStack(spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        if entry.share > 0 {
                            legendItem(entry.name, entry.share, entry.tint)
                        }
                    }
                }
            }
        }
    }

    private func legendItem(_ name: String, _ share: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(percentText(share))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
    }

    // MARK: 段 4:元信息尾行

    /// 活跃天数 · 现存会话数 · 请求数(图标引导,不再三段灰字挤一行);右侧活跃态。
    private var footer: some View {
        HStack(spacing: 16) {
            metaItem("calendar", "活跃 \(project.activeDays)/\(windowDays) 天")
            metaItem("bubble.left.and.bubble.right", "\(project.sessions) 个会话")
            metaItem("arrow.up.arrow.down", "\(agentCountText(project.requests)) 次请求")
            Spacer(minLength: 8)
            idleText
        }
    }

    private func metaItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 在跑已在头部 chip 上;尾行只说日粒度活跃态(今天 / 静了 N 天)。
    private var idleText: some View {
        Text(project.idleDays == 0 ? "今天活跃" : "静了 \(project.idleDays) 天")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }

    private func percentText(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}

// MARK: - 分段条(SwiftUI 原语,agent-tab/05)

/// 占比分段条(高 6 圆角 3,轨道 = 三级墨 14%);段宽按 fraction、>0 才画,
/// 段间留 2pt 缝(07:相邻段同明度时不再糊成一条)。
struct AgentSegmentedBar: View {
    let segments: [(fraction: Double, tint: Color)]

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.fraction > 0 }
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.tint)
                        // 微段保底 2pt 可见(与清理构成条 inuse 段同思路)。
                        .frame(width: max((proxy.size.width - gaps) * segment.fraction, 2))
                }
            }
        }
        .frame(height: 6)
        .background(Surface.inkTertiary.opacity(0.14), in: .rect(cornerRadius: 3))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}
