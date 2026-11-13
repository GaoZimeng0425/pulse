import Foundation
import Observation
import PulseCore

/// 每日 token 账本功能模块(agent-tab/02;ADR-0003 MonitorFeature):薄壳 +
/// 纯值内核 AgentUsageCatalog。双档刷新(用户拍板 2026-11-12):
/// - **定时档**:每轮心跳检查,按 `AgentUsageCatalog.defaultRefreshInterval`
///   (5 分钟)后台重算「今天」(跨午夜偏差用户明示接受);
/// - **全量档**:`requestFullRescan()` 手动触发(UI「重新扫描」);首轮心跳
///   库空时自动跑一次(补齐上线前历史),库有数据则只拉今天。
/// IO 全在后台线程;账本行进 `rows`(图表直读)。历史库缺席 → 功能安静禁用。
@Observable
@MainActor
final class AgentUsageFeature: MonitorFeature {
    /// 账本全表(按天升序);空 = 还没扫过或确实没有数据。
    private(set) var rows: [AgentDailyUsageRow] = []
    /// 项目轨全表(agent-tab/04):UI 按窗口聚合出项目排行。
    private(set) var projectRows: [AgentProjectUsageRow] = []
    /// 模型轨全表(agent-tab/05):项目卡模型分段条按窗口聚合。
    private(set) var modelRows: [AgentModelUsageRow] = []
    /// 项目现存会话数(agent-tab/06;全量档/引导时现数,不落库)。
    private(set) var sessionCounts: [String: Int] = [:]
    /// 全量扫描进行中(UI 转圈与禁用重入)。
    private(set) var isScanning = false

    @ObservationIgnored private let reader: any AgentUsageReading
    @ObservationIgnored private let store: AgentUsageStore?
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var didBootstrap = false

    init(reader: any AgentUsageReading, store: AgentUsageStore?) {
        self.reader = reader
        self.store = store
    }

    /// 每轮心跳:首轮引导(库空自动全量)+ 定时档「今天」刷新。IO 不占心跳线程。
    func onRound(_ context: RoundContext) {
        guard store != nil else { return }
        let now = context.takenAt

        if !didBootstrap {
            didBootstrap = true
            lastRefreshAt = now
            bootstrapInBackground()
            return
        }
        guard let previousRefresh = lastRefreshAt,
              now.timeIntervalSince(previousRefresh) >= AgentUsageCatalog.defaultRefreshInterval
        else { return }
        lastRefreshAt = now
        refreshTodayInBackground(now: now)
    }

    /// 手动「重新扫描」(UI 按钮):全源重扫 + stats-cache 回填缺天。
    func requestFullRescan() {
        guard store != nil, !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) { [reader, store] in
            var catalog = AgentUsageCatalog()
            let result = catalog.fullRescan(reader: reader, store: store!, now: .now)
            let projects = (try? store!.projectRows()) ?? []
            let models = (try? store!.modelRows()) ?? []
            let knownProjects = Set(((try? store!.projectRows()) ?? []).map(\.project))
            let sessions = Self.countSessions(reader: reader, knownProjects: knownProjects)
            await MainActor.run { [weak self] in
                self?.rows = result
                self?.projectRows = projects
                self?.modelRows = models
                self?.sessionCounts = sessions
                self?.isScanning = false
            }
        }
    }

    /// 首轮引导:库空 → 全量(一次性补齐可回填历史);有数据 → 只拉今天 + 读全表。
    private func bootstrapInBackground() {
        guard let store else { return }
        isScanning = true
        Task.detached(priority: .utility) { [reader, store] in
            var catalog = AgentUsageCatalog()
            if (try? store.hasAnyRow()) != true {
                _ = catalog.fullRescan(reader: reader, store: store, now: .now)
            } else {
                _ = catalog.refreshToday(reader: reader, store: store, now: .now)
            }
            let result = (try? store.rows()) ?? []
            let projects = (try? store.projectRows()) ?? []
            let models = (try? store.modelRows()) ?? []
            let knownProjects = Set(((try? store.projectRows()) ?? []).map(\.project))
            let sessions = Self.countSessions(reader: reader, knownProjects: knownProjects)
            await MainActor.run { [weak self] in
                self?.rows = result
                self?.projectRows = projects
                self?.modelRows = models
                self?.sessionCounts = sessions
                self?.isScanning = false
            }
        }
    }

    /// 会话数现数(全量档/引导时机;定时档不放大这个 IO)。纯函数,脱离
    /// MainActor 在后台线程执行。knownProjects = 账本项目名(slug 末词归并用)。
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

    /// 定时档:后台重算今天并读回全表。IO/聚合失败保持上次 rows(下轮再试)。
    private func refreshTodayInBackground(now: Date) {
        guard let store else { return }
        Task.detached(priority: .utility) { [reader, store] in
            var catalog = AgentUsageCatalog()
            guard let fresh = catalog.refreshToday(reader: reader, store: store, now: now)
            else { return }
            let projects = (try? store.projectRows()) ?? []
            let models = (try? store.modelRows()) ?? []
            await MainActor.run { [weak self] in
                self?.rows = fresh
                self?.projectRows = projects
                self?.modelRows = models
            }
        }
    }
}
