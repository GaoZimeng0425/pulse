import Foundation
import Observation
import PulseCore

/// AI 助手会话功能模块(智能体 tab,agent-tab/01;ADR-0003 MonitorFeature):薄壳 +
/// 纯值内核 AgentSessionCatalog(注册表 / jsonl 尾读 / 用量快照 / ZCode metadata 的
/// 解析与节流,单测见 PulseCoreTests.AgentSessionModelTests)。每轮心跳推进:文件读
/// 按 catalog 内部节流(≥5s 一轮),节流轮只按 pid 存活过滤缓存并重算时长;实例
/// 退出 ≤1 轮内下榜。智能体 tab 卡片直读 `snapshot`。
///
/// git 状态(agent-git-status/01)是旁挂读数,不走 catalog:会话工作目录 → 分支 +
/// 未提交,`gitStatuses` 查表给会话卡。三道闸:智能体页可见才采(分支/脏是慢变
/// 读数)、节流双档(cwd 集变化 5s / 稳态 15s——探针 30ms/仓,16 仓上限一轮
/// ≈0.5s,15s 档省主足迹)、子进程批跑在 utility 任务不上主线程(单飞标志互斥)。
@Observable
@MainActor
final class AgentSessionFeature: MonitorFeature {
    /// 本轮聚合:Claude 实例行 / 订阅用量 / ZCode 会话行;无会话为空集。
    private(set) var snapshot: AgentSnapshot = .empty
    /// 会话工作目录 → git 状态(分支 + 未提交);会话卡按 cwd / workspaceRoot 直查。
    /// 只含最近一轮采到读数的目录,非 git 仓库与超上限的 cwd 缺位(UI 安静不画)。
    private(set) var gitStatuses: [String: SessionGitStatus] = [:]

    /// git 节流双档:cwd 集合变化(新会话上榜)提前到 5s,稳态 15s。
    private static let gitChangedInterval: TimeInterval = 5
    private static let gitSteadyInterval: TimeInterval = 15

    @ObservationIgnored private let reader: any AgentSessionReading
    @ObservationIgnored private let gitReader: (any SessionGitStatusReading)?
    @ObservationIgnored private var catalog = AgentSessionCatalog()
    @ObservationIgnored private var agentsVisible = false
    @ObservationIgnored private var lastGitKickAt: Date?
    @ObservationIgnored private var lastGitDirs: [String] = []
    @ObservationIgnored private var gitTaskInFlight = false

    init(reader: any AgentSessionReading, gitReader: (any SessionGitStatusReading)? = nil) {
        self.reader = reader
        self.gitReader = gitReader
    }

    /// 盘点时刻与快照同一时间轴(不另取钟)。
    func onRound(_ context: RoundContext) {
        let alivePids = Set(context.update.snapshot.processes.map(\.pid))
        let next = catalog.update(reader: reader, alivePids: alivePids, now: context.takenAt)
        if next != snapshot {
            snapshot = next
        }
        kickGitStatusesIfDue(now: context.takenAt)
    }

    func visibilityChanged(_ visibility: MonitorVisibility) {
        agentsVisible = visibility.popoverTab == .agents || visibility.mainWindowTab == .agents
    }

    /// 三道闸全过才采一批;读数下一轮自然上屏(detached + MainActor 回跳,
    /// AgentUsageFeature 同款)。
    private func kickGitStatusesIfDue(now: Date) {
        guard agentsVisible, let gitReader, !gitTaskInFlight else { return }
        let dirs = SessionGitStatusFinder.workingDirs(
            claude: snapshot.claudeSessions.map(\.cwd),
            zcode: snapshot.zcodeSessions.map(\.workspaceRoot)
        )
        guard !dirs.isEmpty else { return }
        let interval = dirs == lastGitDirs ? Self.gitSteadyInterval : Self.gitChangedInterval
        if let lastGitKickAt, now.timeIntervalSince(lastGitKickAt) < interval {
            return
        }
        lastGitKickAt = now
        lastGitDirs = dirs
        gitTaskInFlight = true
        Task.detached(priority: .utility) { [gitReader, dirs, weak self] in
            var results: [String: SessionGitStatus] = [:]
            for cwd in dirs {
                if let status = SessionGitStatusFinder.status(cwd: cwd, reader: gitReader) {
                    results[cwd] = status
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                gitStatuses = results
                gitTaskInFlight = false
            }
        }
    }
}
