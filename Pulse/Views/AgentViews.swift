import PulseCore
import SwiftUI

// MARK: - 智能体页:页面骨架与页级零件(agent-tab/06)

//
// 页面骨架:子药丸条 + 当前子页,两块在 `MetricTabStack` 组装(主窗口与弹窗同一份,
// 弹窗走紧凑档)。两个子页——
// · 消耗(`AgentUsagePaneView`):数字卡排 → 走势 | 日历 → 项目榜单;
// · 会话(`ClaudeSessionsCardView` / `ZCodeSessionsCardView`):Claude Code 与 ZCode
//   各一张卡,卡身每个会话一块。
// 本文件只放页级零件:页强调色、token 读数转发、日期小工具、子页枚举、子药丸条。

/// 智能体页强调色(DESIGN.md `{colors.accent-agents}`;tab 条的着色同出这个令牌)。
/// 智能体页各卡(AgentViews / AgentUsageViews)共用。
let agentsAccent = Surface.agentsAccent

/// token 读数短型(556k / 6.9M / 1.9B;唯一出处 PulseCore `AgentTokenFormat`)。
/// 智能体页会话行、消耗子页、图表轴与浮层共用。
func agentTokenText(_ tokens: Int) -> String {
    AgentTokenFormat.short(tokens)
}

/// 同格式拆两段给 `FigureText`(数值整号 + 单位半号):2.4B → ("2.4", "B")。
func agentTokenFigure(_ tokens: Int) -> (value: String, unit: String) {
    AgentTokenFormat.figure(tokens)
}

/// 计数的短型:486 / 1.2k(请求数;agent-tab/05)。
func agentCountText(_ count: Int) -> String {
    if count >= 1000 {
        let tenths = Int((Double(count) / 100).rounded())
        return "\(tenths / 10).\(tenths % 10)k"
    }
    return "\(count)"
}

/// 账本日键 "yyyy-MM-dd" → Date(走 Calendar 分量,免 DateFormatter 线程坑;
/// agent-tab/06f 日期轴与悬停读数用)。
func agentDate(_ day: String) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    return Calendar.current.date(from: components)
}

/// 日期短型 "MM-DD"(轴刻度与悬停浮层;不随区域漂移,手拼)。
func agentShortDate(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.month, .day], from: date)
    return String(format: "%02d-%02d", components.month ?? 0, components.day ?? 0)
}

/// 智能体页的两个子页;选中态存在 `DashboardModel.agentSubTab`(切 tab 不丢),
/// 默认落消耗。
enum AgentSubTab: Hashable {
    /// 消耗(token 账:数字卡 / 走势 / 日历 / 项目)。
    case usage
    /// 会话(现在在跑什么:两家会话卡)。
    case sessions

    var title: String {
        switch self {
        case .usage: "消耗"
        case .sessions: "会话"
        }
    }

    static let all: [AgentSubTab] = [.usage, .sessions]
}

/// 智能体页子药丸条:清理页子页条同款(`PillTabBar` comfortable 档 + 页强调色 +
/// 玻璃外裹)。`isGlassContainer` 默认 false,漏传就没有玻璃外裹,和清理页子页条两个样。
struct AgentSubTabBar: View {
    @Binding var selection: AgentSubTab

    var body: some View {
        PillTabBar(AgentSubTab.all, selection: $selection, isGlassContainer: true, size: .comfortable) { tab in
            PillTabItem(title: tab.title, symbol: nil, tint: agentsAccent)
        }
    }
}
