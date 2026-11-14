import PulseCore
import SwiftUI

// MARK: - 会话子页两卡(agent-tab/08 重设计;自 AgentViews.swift 拆出)

//
// 08 重设计(2026-11-14 用户实报「会话 tab 不好看;右侧 23% 看不懂;ZCode 的
// 6/10 6.9M 看不懂」):06 版沿用实体行,右侧两个裸数字没有标签也没有单位。
// 终态 = 每个会话一张 lift 小块(cardHigh 底、圆角 10、内距 12),左「是谁、
// 在干什么」(图标 + 名 + 状态 chip / 任务摘要 / 元信息)、右**带标签的读数块**
// (标签 → 读数 → meter → 注脚):Claude =「上下文 48%」+ 480k / 1M;ZCode =
// 「子代理 2 / 5 在跑」+ 累计 token。读数一律自带口径,不再裸数字。

/// 会话块右侧读数块:标签(micro tertiary)+ 读数(值 semibold)→ meter → 注脚。
private struct AgentSessionMetric: View {
    let label: String
    let value: String
    /// nil = 不画 meter(读数缺失时)。
    let fraction: Double?
    let caption: String?
    let compact: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: RowMetrics.valueFontSize(compact: compact), weight: .semibold))
                    .monospacedDigit()
            }
            if let fraction {
                MeterBar(fraction: fraction, tint: agentsAccent)
                    .frame(width: RowMetrics.meterWidth(compact: compact))
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// 会话 lift 小块骨架:左图标 + 三行文字(名行 / 摘要 / 元信息),右读数块。
private struct AgentSessionTile<Badge: View, Metric: View>: View {
    let systemImage: String
    let tint: Color
    let name: String
    let summary: String?
    let meta: String?
    let compact: Bool
    @ViewBuilder var badge: () -> Badge
    @ViewBuilder var metric: () -> Metric

    var body: some View {
        HStack(alignment: .top, spacing: RowMetrics.spacing(compact: compact)) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 13 : 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: RowMetrics.iconSize(compact: compact))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: RowMetrics.nameFontSize(compact: compact), weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    badge()
                }
                if let summary {
                    Text(summary)
                        .font(.system(size: RowMetrics.subFontSize(compact: compact)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let meta {
                    Text(meta)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            metric()
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// 卡头右侧计数:「2 个实例」。
private struct AgentSessionCount: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

// MARK: - Claude Code

/// Claude Code 会话卡:一实例一块——名 + 状态 / 任务摘要 / 模型·运行时长·子代理·pid;
/// 右「上下文 N%」+ meter + 「已用 / 窗口上限」。上下文口径:末条请求
/// input+cache_read(首建缓存期 input+creation)÷ 窗口上限(200k/1M 二档,abtop 同款)。
struct ClaudeSessionsCardView: View {
    let sessions: [ClaudeAgentSessionStatus]
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "ant", title: "Claude Code", tint: agentsAccent) {
                if !sessions.isEmpty {
                    AgentSessionCount(text: "\(sessions.count) 个实例")
                }
            }
            if sessions.isEmpty {
                CardEmptyState(
                    title: "没有在跑的 Claude Code",
                    detail: "实例启动后,这里列出项目、当前任务与上下文占用"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions) { session in
                        tile(session)
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    private func tile(_ session: ClaudeAgentSessionStatus) -> some View {
        AgentSessionTile(
            systemImage: "ant",
            tint: agentsAccent,
            name: session.name ?? session.projectName,
            summary: session.taskSummary,
            meta: meta(session),
            compact: isCompact
        ) {
            if let label = session.statusLabel {
                ChipView(
                    text: label,
                    tint: session.status?.lowercased() == "busy" ? agentsAccent : Surface.inkTertiary,
                    profile: .inline
                )
            }
        } metric: {
            AgentSessionMetric(
                label: "上下文",
                value: session.contextFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                fraction: session.contextFraction,
                caption: contextCaption(session),
                compact: isCompact
            )
            .help("当前会话已占用的上下文窗口(末条请求的输入 + 缓存读 ÷ 窗口上限)")
        }
    }

    /// 元信息:模型 · 运行时长 · 子代理 N · pid(缺失项省略,不占位)。
    private func meta(_ session: ClaudeAgentSessionStatus) -> String {
        var parts: [String] = []
        if let model = session.model {
            parts.append(AgentUsageWindow.modelDisplayName(model))
        }
        if let ageSeconds = session.ageSeconds {
            parts.append("运行 \(PulseFormat.duration(seconds: ageSeconds))")
        }
        if session.subagentCount > 0 {
            parts.append("子代理 \(session.subagentCount)")
        }
        parts.append("pid \(session.pid)")
        return parts.joined(separator: " · ")
    }

    /// 注脚「480k / 1M」;读数缺失(新会话未发首条)如实说明。
    private func contextCaption(_ session: ClaudeAgentSessionStatus) -> String {
        guard let used = session.contextTokens, let limit = session.contextLimit else {
            return "尚无请求"
        }
        // 窗口上限是整档(200k / 1M),去掉「1.0M」的尾零。
        let limitText = agentTokenText(limit).replacingOccurrences(of: ".0", with: "")
        return "\(agentTokenText(used)) / \(limitText)"
    }
}

// MARK: - ZCode

/// ZCode 会话卡:一会话一块——工作区 + 在跑/空闲 / 更新于 N 前 · 会话短 id;
/// 右「子代理 在跑 / 总数」+ meter + 「累计 N tokens」。只看近一天有更新的会话;
/// 在跑 = 状态非终态(completed 等)。
struct ZCodeSessionsCardView: View {
    let sessions: [ZCodeSessionStatus]
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "chevron.left.forwardslash.chevron.right", title: "ZCode", tint: agentsAccent) {
                if !sessions.isEmpty {
                    AgentSessionCount(text: "近一天 \(sessions.count) 个会话")
                }
            }
            if sessions.isEmpty {
                CardEmptyState(
                    title: "ZCode 近一天没有会话",
                    detail: "子代理开始干活时,这里列出工作区与运行状态"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions) { session in
                        tile(session)
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    private func tile(_ session: ZCodeSessionStatus) -> some View {
        let running = session.activeAgents > 0
        return AgentSessionTile(
            systemImage: "chevron.left.forwardslash.chevron.right",
            tint: running ? agentsAccent : Surface.inactive,
            name: session.workspaceName ?? shortSessionID(session.sessionId),
            summary: session.updatedAgoSeconds.map { "更新于 \(PulseFormat.duration(seconds: $0))前" },
            meta: "会话 \(shortSessionID(session.sessionId))",
            compact: isCompact
        ) {
            ChipView(
                text: running ? "在跑" : "空闲",
                tint: running ? agentsAccent : Surface.inkTertiary,
                profile: .inline
            )
        } metric: {
            AgentSessionMetric(
                label: "子代理在跑",
                value: "\(session.activeAgents) / \(session.totalAgents)",
                fraction: session.totalAgents > 0
                    ? Double(session.activeAgents) / Double(session.totalAgents)
                    : nil,
                caption: session.totalTokens.map { "累计 \(agentTokenText($0)) tokens" },
                compact: isCompact
            )
            .help("在跑的子代理数 / 本会话全部子代理数;注脚为本会话全部子代理的 token 合计")
        }
    }

    /// "sess_<uuid>" → 前 8 位。
    private func shortSessionID(_ sessionId: String) -> String {
        String(sessionId.dropFirst("sess_".count).prefix(8))
    }
}

#Preview("会话子页") {
    let claudeSessions = [
        ClaudeAgentSessionStatus(
            pid: 65825, sessionId: "b175530f", projectName: "octok-client",
            cwd: "/Users/x/octok-client", status: "busy", ageSeconds: 13540,
            model: "claude-opus-5-5", contextTokens: 480_499, contextLimit: 1_000_000,
            subagentCount: 3
        ),
        ClaudeAgentSessionStatus(
            pid: 21510, sessionId: "8f0d21aa", projectName: "pulse",
            cwd: "/Users/x/pulse", status: "idle", ageSeconds: 7200,
            model: nil, contextTokens: nil, contextLimit: nil, subagentCount: 0
        ),
    ]
    let zcodeSessions = [
        ZCodeSessionStatus(
            sessionId: "sess_3667bf67", workspaceName: "pulse", activeAgents: 6,
            totalAgents: 10, totalTokens: 6_900_000, updatedAgoSeconds: 42
        ),
        ZCodeSessionStatus(
            sessionId: "sess_717b5fec", workspaceName: "octok-client", activeAgents: 0,
            totalAgents: 2, totalTokens: nil, updatedAgoSeconds: 3600
        ),
    ]
    return VStack(spacing: 16) {
        ClaudeSessionsCardView(sessions: claudeSessions)
        ZCodeSessionsCardView(sessions: zcodeSessions)
    }
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
