import Foundation
import PulseCore

// MARK: - AI 助手能耗聚合(p3-root-mcp/04):内置识别表 + 纯值聚合

/// v1 内置口径(票面拍板:内置表,用户可配留后):进程名 → 助手显示名。
/// 匹配大小写不敏感;exact 档防误伤——Apple 系统的 CursorUIViewService /
/// UserEventAgent / ContextStoreAgent 不是助手,不许被前缀扫进去。
/// 表外进程不进卡:卡只答「哪个 AI 助手在耗电」,全进程视角归既有排行与历史页。
enum AgentEnergyTable {
    struct Entry: Sendable, Equatable {
        enum Match: Sendable {
            case prefix
            case exact
        }

        let pattern: String
        let match: Match
        let agent: String
    }

    static let entries: [Entry] = [
        Entry(pattern: "zcode", match: .prefix, agent: "ZCode"),
        Entry(pattern: "zap-", match: .prefix, agent: "zap"),
        Entry(pattern: "claude", match: .prefix, agent: "Claude"),
        Entry(pattern: "ollama", match: .prefix, agent: "Ollama"),
        Entry(pattern: "cursor", match: .exact, agent: "Cursor"),
        Entry(pattern: "cursor helper", match: .prefix, agent: "Cursor"),
        Entry(pattern: "raycast", match: .prefix, agent: "Raycast"),
        Entry(pattern: "com.raycast.", match: .prefix, agent: "Raycast"),
        Entry(pattern: "codex", match: .prefix, agent: "Codex"),
        Entry(pattern: "gemini", match: .prefix, agent: "Gemini"),
        Entry(pattern: "copilot", match: .prefix, agent: "GitHub Copilot"),
    ]

    /// 进程名 → 助手显示名(表外 nil)。首个命中条目胜。
    static func agent(for processName: String) -> String? {
        let lowered = processName.lowercased()
        return entries.first { entry in
            switch entry.match {
            case .prefix: lowered.hasPrefix(entry.pattern)
            case .exact: lowered == entry.pattern
            }
        }?.agent
    }

    /// 同名聚合后的(name, impact)表 → 助手聚合行(impact 降序)。
    /// processCount = 命中该助手的**不同进程名**个数(同名多 pid 已先行聚合)。
    static func group(_ nameImpacts: [(name: String, impact: Double)]) -> [AgentEnergyEntry] {
        var impact: [String: Double] = [:]
        var count: [String: Int] = [:]
        for (name, value) in nameImpacts {
            guard let agent = agent(for: name) else { continue }
            impact[agent, default: 0] += value
            count[agent, default: 0] += 1
        }
        return impact
            .map { AgentEnergyEntry(agent: $0.key, impact: $0.value, processCount: count[$0.key] ?? 0) }
            .sorted { $0.impact > $1.impact }
    }

    /// 助手聚合行 → 模块排行卡行(共用卡渲染;meter 按榜首归一,既有口径)。
    /// 能耗量纲 = powermetrics Energy Impact(千级,票 03 记档),非活动监视器 0-100 口径。
    static func rankingRows(_ agents: [AgentEnergyEntry]) -> [ModuleRankingRow] {
        let leader = agents.map(\.impact).max() ?? 0
        return agents.map { entry in
            ModuleRankingRow(
                id: "agent:\(entry.agent)",
                name: entry.agent,
                primary: entry.impact,
                primaryText: format(entry.impact),
                subtitle: "\(entry.processCount) 个进程",
                meterFraction: MeterNormalization.fraction(entry.impact, leader: leader)
            )
        }
    }

    /// 主值文案:<100 一位小数,≥100 取整(千级量纲下小数无意义)。
    static func format(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

/// 助手聚合行(纯值):助手名 + 能耗合计 + 命中的进程名数。
struct AgentEnergyEntry: Sendable, Equatable, Identifiable {
    let agent: String
    let impact: Double
    let processCount: Int

    var id: String {
        agent
    }
}
