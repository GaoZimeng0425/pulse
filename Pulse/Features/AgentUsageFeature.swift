import Foundation
import Observation
import PulseCore

/// 每日 token 账本功能模块(agent-tab/02;Claude 增量化 agent-tab/12;
/// ADR-0003 MonitorFeature):薄壳 + 纯值内核 AgentUsageScan。双档刷新
/// (用户拍板 2026-11-12):
/// - **定时档**:每轮心跳检查,按 `AgentUsageScan.defaultRefreshInterval`
///   (5 分钟)后台增量扫描(检查点后 Claude 只读改动文件的新增字节,Σ 全部
///   检查点落账——历史天随 compact 自愈,agent-tab/02 的「只写今天」护栏由
///   完整 Σ 口径取代);ZCode 只拉今天。
/// - **全量档**:`requestFullRescan()` 手动触发(UI「重新扫描」);首轮心跳
///   库空时自动跑一次(补齐上线前历史),库有数据则走定时档。ZCode 全表 +
///   stats-cache 回填缺天。
/// IO 全在后台线程;账本行进 `rows`(图表直读)。历史库缺席 → 功能安静禁用。
@Observable
@MainActor
final class AgentUsageFeature: MonitorFeature {
    /// 账本全表(按天升序);空 = 还没扫过或确实没有数据。
    private(set) var rows: [AgentDailyUsageRow] = []
    /// 项目轨全表(agent-tab/04):UI 按窗口聚合出项目排行。
    private(set) var projectRows: [AgentProjectUsageRow] = []
    /// 模型轨全表(agent-tab/05):项目榜单明细里模型分段条按窗口聚合。
    private(set) var modelRows: [AgentModelUsageRow] = []
    /// 项目现存会话数(agent-tab/06;全量档/引导时现数,不落库)。
    private(set) var sessionCounts: [String: Int] = [:]
    /// 全量扫描进行中(UI 转圈与禁用重入)。
    private(set) var isScanning = false

    @ObservationIgnored private let reader: any AgentUsageReading
    @ObservationIgnored private let store: AgentUsageStore?
    @ObservationIgnored private let checkpoints: AgentCheckpointStore?
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var didBootstrap = false

    init(
        reader: any AgentUsageReading,
        store: AgentUsageStore?,
        checkpoints: AgentCheckpointStore? = nil
    ) {
        self.reader = reader
        self.store = store
        self.checkpoints = checkpoints
    }

    /// 每轮心跳:首轮引导(库空自动全量)+ 定时档增量刷新。IO 不占心跳线程。
    func onRound(_ context: RoundContext) {
        guard store != nil, checkpoints != nil else { return }
        let now = context.takenAt

        if !didBootstrap {
            didBootstrap = true
            lastRefreshAt = now
            bootstrapInBackground()
            return
        }
        guard let previousRefresh = lastRefreshAt,
              now.timeIntervalSince(previousRefresh) >= AgentUsageScan.defaultRefreshInterval
        else { return }
        lastRefreshAt = now
        refreshInBackground(now: now, scope: .today)
    }

    /// 手动「重新扫描」(UI 按钮):ZCode 全表 + Claude 增量 + stats-cache
    /// 回填缺天(首轮升级后检查点为空,自动退化为一次全量,之后永久增量)。
    func requestFullRescan() {
        guard let store, let checkpoints, !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) { [reader, store, checkpoints, weak self] in
            let scan = AgentUsageScan()
            _ = scan.scan(
                reader: reader,
                checkpoints: checkpoints,
                ledger: store,
                now: .now,
                scope: .full
            )
            await Self.reload(reader: reader, store: store, feature: self, countSessions: true)
        }
    }

    /// 首轮引导:库空 → 全量(一次性补齐可回填历史);有数据 → 定时档。
    private func bootstrapInBackground() {
        guard let store, let checkpoints else { return }
        isScanning = true
        Task.detached(priority: .utility) { [reader, store, checkpoints, weak self] in
            let scan = AgentUsageScan()
            let empty = (try? store.hasAnyRow()) != true
                && (try? checkpoints.loadCheckpoints())?.isEmpty != false
            _ = scan.scan(
                reader: reader,
                checkpoints: checkpoints,
                ledger: store,
                now: .now,
                scope: empty ? .full : .today
            )
            await Self.reload(reader: reader, store: store, feature: self, countSessions: true)
        }
    }

    /// 定时档:后台增量扫描并读回全表。IO/落库失败保持上次 rows(下轮再试)。
    private func refreshInBackground(now: Date, scope: AgentScanScope) {
        guard let store, let checkpoints else { return }
        Task.detached(priority: .utility) { [reader, store, checkpoints, weak self] in
            let scan = AgentUsageScan()
            _ = scan.scan(
                reader: reader,
                checkpoints: checkpoints,
                ledger: store,
                now: now,
                scope: scope
            )
            // 定时档不现数会话(agentSessionCounts 有 db GROUP BY,重 IO;
            // agent-tab/06 的老规矩,只在全量档/引导时机数)。
            await Self.reload(reader: reader, store: store, feature: self, countSessions: false)
        }
    }

    /// 后台读回三表;`countSessions` 时现数会话(全量档/引导时机——
    /// agentSessionCounts 有 db GROUP BY,定时档不放大这个 IO)。
    private static func reload(
        reader: any AgentUsageReading,
        store: AgentUsageStore,
        feature: AgentUsageFeature?,
        countSessions: Bool
    ) async {
        let result = (try? store.rows()) ?? []
        let projects = (try? store.projectRows()) ?? []
        let models = (try? store.modelRows()) ?? []
        let sessions = countSessions
            ? Self.countSessions(reader: reader, knownProjects: Set(projects.map(\.project)))
            : nil
        await MainActor.run {
            feature?.rows = result
            feature?.projectRows = projects
            feature?.modelRows = models
            if let sessions {
                feature?.sessionCounts = sessions
            }
            feature?.isScanning = false
        }
    }

    /// 会话数现数(纯函数,脱离 MainActor 在后台线程执行)。
    /// knownProjects = 账本项目名(slug 末词归并用)。
    private nonisolated static func countSessions(
        reader: any AgentUsageReading,
        knownProjects: Set<String>
    ) -> [String: Int] {
        let raw = reader.agentSessionCounts()
        return AgentUsageWindow.sessionCounts(
            claude: raw.claude,
            zcode: raw.zcode,
            knownProjects: knownProjects
        )
    }
}
