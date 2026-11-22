import Foundation
import PulseCore

// MARK: - 能耗指数 → 排行行折算(battery-energy/01)

//
// 用户拍板口径:「耗了多少电、占多少百分比」——主值 = 占全机合计的百分比,
// 副文带能耗指数原值(与活动监视器同口径的无量纲指数,macOS 不给普通 app
// 每进程瓦特,指数是苹果自家的替代口径)。两张卡(耗电排行·全部应用 /
// AI 助手)同源折算,消灭「同一页三种语言」。
// 纯值函数,合成夹具单测钉死(PulseTests);数据源 EnergyImpactFeature 60s 档。

enum EnergyImpactTable {
    /// 占比主值文案:一位小数;大于 0 但不足 0.05% 显示「<0.1%」
    /// (诚实下界,不出 0.0% 的假精度)。
    static func percentText(_ impact: Double, total: Double) -> String {
        guard total > 0 else { return "—" }
        let percent = impact / total * 100
        if percent > 0, percent < 0.05 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", percent)
    }

    /// 指数副文文案:<100 一位小数,≥100 取整(AgentEnergyTable.format 同口径)。
    static func indexText(_ impact: Double) -> String {
        impact >= 100 ? String(format: "%.0f", impact) : String(format: "%.1f", impact)
    }

    /// 「耗电排行 · 全部应用」行:top 已按指数降序;合计 ≤ 0 交空数组
    /// (调用方走「等待读数」空态,不出全零假行)。
    static func allAppsRows(
        _ top: [EnergyImpactReading.Row],
        totalImpact: Double
    ) -> [ModuleRankingRow] {
        guard totalImpact > 0 else { return [] }
        let leader = top.first?.impact ?? 0
        return top.map { row in
            ModuleRankingRow(
                id: "ei:\(row.name)",
                name: row.name,
                primary: row.impact / totalImpact,
                primaryText: percentText(row.impact, total: totalImpact),
                subtitle: "指数 \(indexText(row.impact))",
                meterFraction: MeterNormalization.fraction(row.impact, leader: leader)
            )
        }
    }

    /// 「耗电排行 · AI 助手」行:占比主值 + 进程数与指数副文。
    static func agentRows(
        _ agents: [AgentEnergyEntry],
        totalImpact: Double
    ) -> [ModuleRankingRow] {
        guard totalImpact > 0 else { return [] }
        let leader = agents.map(\.impact).max() ?? 0
        return agents.map { entry in
            ModuleRankingRow(
                id: "agent:\(entry.agent)",
                name: entry.agent,
                primary: entry.impact / totalImpact,
                primaryText: percentText(entry.impact, total: totalImpact),
                subtitle: "\(entry.processCount) 个进程 · 指数 \(indexText(entry.impact))",
                meterFraction: MeterNormalization.fraction(entry.impact, leader: leader)
            )
        }
    }
}
