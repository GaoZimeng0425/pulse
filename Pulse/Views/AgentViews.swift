import PulseCore
import SwiftUI

// MARK: - 智能体 tab 卡片(agent-tab/01)

//
// 三张卡:用量限额(读数行)/ Claude Code 会话(实体行)/ ZCode 会话(实体行);
// dev server 卡从总览迁入本页(原样,见 DevServerViews)。全部组装 CardFamily 标准件,
// 行尺寸走 RowMetrics 两档。meter 与数值一律取本页指标色(蓝牙青,junk-ai 同源
// 的 AI 身份色)——「正常/偏高/紧张」的阈值变色集中在既有三处,本页不开第四处。

/// 智能体页指标色:蓝牙青(DESIGN.md junk-ai 先例;tab accent 同源)。
/// 智能体页各卡(AgentViews / AgentUsageViews)共用。
let agentsAccent = Metric.bluetooth.accentColor

/// token 合计的短型:556k / 1.2M(小数点手拼,不随区域漂移)。
/// 智能体页会话行与每日消耗摘要共用同一格式。
func agentTokenText(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
        let tenths = Int((Double(tokens) / 100_000).rounded())
        return "\(tenths / 10).\(tenths % 10)M"
    }
    if tokens >= 1000 {
        return "\(tokens / 1000)k"
    }
    return "\(tokens)"
}

/// 同格式拆两段给 `FigureText`(数值整号 + 单位半号):46M → ("46", "M")。
/// 每日消耗数字卡与项目大卡共用(agent-tab/05)。
func agentTokenFigure(_ tokens: Int) -> (value: String, unit: String) {
    let text = agentTokenText(tokens)
    if let unit = text.last, "kMB".contains(unit) {
        return (String(text.dropLast()), String(unit))
    }
    return (text, "")
}

/// 计数的短型:486 / 1.2k(请求数;agent-tab/05)。
func agentCountText(_ count: Int) -> String {
    if count >= 1000 {
        let tenths = Int((Double(count) / 100).rounded())
        return "\(tenths / 10).\(tenths % 10)k"
    }
    return "\(count)"
}

/// Claude 用量限额卡:5 小时窗 / 本周两条读数行(meter + 百分比)+ 窗口重置注记。
/// 快照是账户级(全部实例共享),单窗缺失如实少一行。
struct ClaudeUsageCardView: View {
    let usage: ClaudeUsageSnapshot?
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "speedometer", title: "Claude 用量", tint: agentsAccent)
            if let usage {
                VStack(alignment: .leading, spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                    if let fiveHour = usage.fiveHour {
                        windowRow("5 小时窗口", window: fiveHour)
                    }
                    if let sevenDay = usage.sevenDay {
                        windowRow("本周", window: sevenDay)
                    }
                    if let resetsIn = usage.fiveHour?.resetsAt.map(\.timeIntervalSinceNow),
                       resetsIn > 0 {
                        CardReadingRow(
                            label: "窗口重置",
                            meter: nil,
                            value: "\(PulseFormat.duration(seconds: resetsIn))后",
                            valueMinWidth: CardRowWidth.quantityValue,
                            valueStyle: .secondary,
                            compact: isCompact
                        )
                    }
                }
            } else {
                CardEmptyState(
                    title: "未读到用量快照",
                    detail: "Claude Code 写入用量快照后,这里显示 5 小时窗与本周的限额占用"
                )
            }
        }
        .cardShell(compact: isCompact)
    }

    private func windowRow(_ label: String, window: ClaudeUsageSnapshot.Window) -> some View {
        CardReadingRow(
            label: label,
            meter: (fraction: min(max(Double(window.usedPercentage) / 100, 0), 1), tint: agentsAccent),
            value: "\(window.usedPercentage)%",
            valueMinWidth: CardRowWidth.percentValue,
            valueStyle: .primary,
            compact: isCompact
        )
    }
}

/// Claude Code 会话卡:一实例一行——项目 / pid·时长·状态 / 上下文占用% / 子代理数。
/// 上下文口径:末条请求 input+cache_read(首建缓存期 input+creation)÷ 窗口上限
/// (200k/1M 二档,abtop 同款)。
struct ClaudeSessionsCardView: View {
    let sessions: [ClaudeAgentSessionStatus]
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "ant", title: "Claude Code", tint: agentsAccent) {
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if sessions.isEmpty {
                CardEmptyState(
                    title: "没有在跑的 Claude Code",
                    detail: "实例启动后,这里列出项目、上下文占用与子代理数"
                )
            } else {
                VStack(alignment: .leading, spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                    ForEach(sessions) { session in
                        row(session)
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 一行会话(实体行):蚂蚁图标 + 名字(会话自定义名优先,缺省项目名);
    /// 副文优先当前任务摘要(末条用户指令截断),缺省 pid·时长·状态;
    /// 上下文%与子代理数贴右。
    private func row(_ session: ClaudeAgentSessionStatus) -> some View {
        let valueSize = RowMetrics.valueFontSize(compact: isCompact)
        return CardEntityRow(
            systemImage: "ant",
            tint: agentsAccent,
            name: session.name ?? session.projectName,
            sub: session.taskSummary ?? rowSub(session),
            compact: isCompact
        ) {
            Text(contextText(session))
                .font(.system(size: valueSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if session.subagentCount > 0 {
                Text("子代理 \(session.subagentCount)")
                    .font(.system(size: valueSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 副文:pid · 运行时长 · 状态(各自缺失即省略,不占位)。
    private func rowSub(_ session: ClaudeAgentSessionStatus) -> String? {
        var parts = ["pid \(session.pid)"]
        if let ageSeconds = session.ageSeconds {
            parts.append(PulseFormat.duration(seconds: ageSeconds))
        }
        if let statusLabel = session.statusLabel {
            parts.append(statusLabel)
        }
        return parts.joined(separator: " · ")
    }

    /// 上下文占用百分比;读数缺失写「—」(表格的诚实单元格,不是状态提示)。
    private func contextText(_ session: ClaudeAgentSessionStatus) -> String {
        guard let fraction = session.contextFraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

/// ZCode 会话卡:一会话一行——工作区 / 更新时间 / 活跃子代理占比 / token 合计。
/// 只看近一天有更新的会话;活跃 = 状态非终态(completed 等)。
struct ZCodeSessionsCardView: View {
    let sessions: [ZCodeSessionStatus]
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "chevron.left.forwardslash.chevron.right", title: "ZCode", tint: agentsAccent)
            if sessions.isEmpty {
                CardEmptyState(
                    title: "ZCode 近一天没有会话",
                    detail: "子代理开始干活时,这里列出工作区与运行状态"
                )
            } else {
                VStack(alignment: .leading, spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                    ForEach(sessions) { session in
                        row(session)
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 一行会话(实体行):代码图标 + 工作区名;更新于 N 前副文;活跃占比与 token 贴右。
    private func row(_ session: ZCodeSessionStatus) -> some View {
        let valueSize = RowMetrics.valueFontSize(compact: isCompact)
        return CardEntityRow(
            systemImage: "chevron.left.forwardslash.chevron.right",
            tint: session.activeAgents > 0 ? agentsAccent : Surface.inactive,
            name: session.workspaceName ?? shortSessionID(session.sessionId),
            sub: session.updatedAgoSeconds.map { "更新于 \(PulseFormat.duration(seconds: $0))前" },
            compact: isCompact
        ) {
            Text("\(session.activeAgents)/\(session.totalAgents)")
                .font(.system(size: valueSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let tokens = session.totalTokens {
                Text(agentTokenText(tokens))
                    .font(.system(size: valueSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "sess_<uuid>" → 前 8 位(工作区名缺失时的兜底行名)。
    private func shortSessionID(_ sessionId: String) -> String {
        String(sessionId.dropFirst("sess_".count).prefix(8))
    }
}

#Preview("智能体三卡") {
    let usage = ClaudeUsageSnapshot(
        fiveHour: .init(usedPercentage: 17, resetsAt: Date().addingTimeInterval(9780)),
        sevenDay: .init(usedPercentage: 54, resetsAt: nil)
    )
    let claudeSessions = [
        ClaudeAgentSessionStatus(
            pid: 65825, sessionId: "b175530f", projectName: "octok-client",
            cwd: "/Users/x/octok-client", status: "shell", ageSeconds: 13540,
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
            sessionId: "sess_3667bf67", workspaceName: "pulse", activeAgents: 2,
            totalAgents: 5, totalTokens: 1_812_400, updatedAgoSeconds: 42
        ),
        ZCodeSessionStatus(
            sessionId: "sess_717b5fec", workspaceName: "octok-client", activeAgents: 0,
            totalAgents: 2, totalTokens: nil, updatedAgoSeconds: 3600
        ),
    ]
    return VStack(spacing: 16) {
        ClaudeUsageCardView(usage: usage)
        ClaudeUsageCardView(usage: nil)
        ClaudeSessionsCardView(sessions: claudeSessions)
        ZCodeSessionsCardView(sessions: zcodeSessions)
        ZCodeSessionsCardView(sessions: [])
    }
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
