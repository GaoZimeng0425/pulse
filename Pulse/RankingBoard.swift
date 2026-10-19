import Foundation
import Darwin

// MARK: - 模块排行纯值内核(RankingsFeature 的值核)

/// 模块排行纯值内核(工单 01 三张榜:能耗影响 / 读写最多 / 每进程流量):持有最新一轮
/// 的组与三份最新每 pid 读数,经 ModuleRankingAggregator 出按组聚合的排行行。
/// AlertCenter + AlertEngine 同款样板:值类型、无副作用、无时钟,由 RankingsFeature
/// (MainActor 薄壳)持有;单测见 RankingBoardTests。
///
/// 两只钟在这里对齐:读数各走各的窗(能耗 5s / 磁盘 30s 住心跳,网络 nettop 5s 自有
/// 节拍),而 pid → 组永远取**最新一轮**的组——行与组同轮出,不在视图里现场拼凑。
struct RankingBoard: Sendable {
    /// 最新一轮的全部组(主干同轮产出):每轮整份换新。
    private var groups: [ProcessGroup] = []
    /// 能耗影响最近一窗(每 pid 差分):满窗轮整份替换。
    private var energyImpacts: [pid_t: ProcessEnergyImpact] = [:]
    /// 磁盘每进程最近一窗(每 pid 读写速率):满窗轮整份替换。
    private var diskRates: [pid_t: ProcessDiskRates] = [:]
    /// 网络每进程最近一次交付(nettop 每 pid 上下行速率):有读数即整份替换。
    private var networkRates: [pid_t: ProcessNetworkRates] = [:]

    /// 一轮心跳落地:组每轮换新;能耗 / 磁盘只在本轮满窗时整份替换(空字典 = 本窗无
    /// 活跃进程,同样替换),nil = 本轮该窗未满,保留上一窗——但照常按新组重归属。
    mutating func recordRound(groups: [ProcessGroup], rankings: ProcessRankingRound) {
        self.groups = groups
        if let impacts = rankings.energyImpacts {
            energyImpacts = impacts
        }
        if let rates = rankings.diskRates {
            diskRates = rates
        }
    }

    /// nettop 交付(与心跳不同步,落在两轮之间):有读数整份替换;nil = 从未有过好值
    /// (driver 的 `snapshot() ?? lastGood` 交付口径),保留上次。行按最新一轮的组出。
    mutating func recordNetworkRates(_ rates: [pid_t: ProcessNetworkRates]?) {
        if let rates {
            networkRates = rates
        }
    }

    /// 电池页·能耗影响行。
    var energyRows: [ModuleRankingRow] {
        ModuleRankingAggregator.energyRows(impacts: energyImpacts, groups: groups)
    }

    /// 磁盘页·读写最多行。
    var diskRows: [ModuleRankingRow] {
        ModuleRankingAggregator.diskRows(rates: diskRates, groups: groups)
    }

    /// 网络页·每进程流量行。
    var networkRows: [ModuleRankingRow] {
        ModuleRankingAggregator.networkRows(rates: networkRates, groups: groups)
    }
}
