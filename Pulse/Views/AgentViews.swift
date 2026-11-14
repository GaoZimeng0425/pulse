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

/// 智能体页子 tab(agent-tab/06,用户拍板三页;状态在 DashboardModel)。
enum AgentSubTab: Hashable {
    /// 消耗(token 账:数字卡排 / 日历图+走势 / 项目宽卡)。
    case usage
    /// 会话(现在在跑什么:两家会话卡)。
    case sessions
    /// 开发服务(dev server)。
    case servers

    var title: String {
        switch self {
        case .usage: "消耗"
        case .sessions: "会话"
        case .servers: "开发服务"
        }
    }

    static let all: [AgentSubTab] = [.usage, .sessions, .servers]
}

/// 智能体页子药丸条(清理页子页条同款 `PillTabBar` comfortable 档 + 页指标色 +
/// 玻璃外裹;08 补 `isGlassContainer`——06 漏传,与清理页子页条外观不一致)。
struct AgentSubTabBar: View {
    @Binding var selection: AgentSubTab

    var body: some View {
        PillTabBar(AgentSubTab.all, selection: $selection, isGlassContainer: true, size: .comfortable) { tab in
            PillTabItem(title: tab.title, symbol: nil, tint: agentsAccent)
        }
    }
}
