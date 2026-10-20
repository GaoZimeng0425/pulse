import Foundation
import Observation

/// 历史功能模块(工单 p1-history/03、04、06 的历史管线,ADR-0003 功能模块):@Observable 薄壳 +
/// 纯值内核 HistoryFeed(AlertCenter + AlertEngine 同款样板)。经 SystemMonitor
/// 注册表组装:每轮 onRound 折一笔落库入参;磁盘吞吐读数经 diskThroughputDelivered
/// 钩子送达;视图直读本模块的 `networkTotals` 与 `series`。
///
/// - 串行写入(arch-review-2026-10-18 乙7):start 建一条 AsyncStream + 唯一的长寿消费者;每轮
///   入参按轮次顺序入流,消费者逐笔 await 落库、再读回累计发布——落库严格按轮次
///   顺序生效(此前每轮一个 fire-and-forget Task,先后无保证;分钟缓冲会丢弃迟到
///   的旧分钟样本,连同其网络/磁盘增量)。流不设上限:丢笔即丢增量。
/// - 回灌先于首笔落库:消费者先读回库中出生登记,经宿主接口 MonitorHost.restoreBirths
///   即时叠加进主干,再开始消费——引擎的"已持久化"集合先预热。
/// - 引擎缺席(库打开失败,03 的降级路径)→ 不起写入者、不发布、查询 nil,实时页
///   不受影响。
/// 串行顺序经 HistoryFeatureTests(真 SQLite 内存库 + 注入时钟)钉住;其余逻辑在
/// 内核 HistoryFeed(HistoryFeedTests)。
@Observable
@MainActor
final class HistoryFeature: MonitorFeature {
    /// 网络 Today/7 天累计(工单 p1-history/06):每笔落库之后读回;库缺席 / 查询失败 / 首笔
    /// 落库前为 nil → 累计列占位。
    private(set) var networkTotals: NetworkTotalsReading?

    private let engine: HistoryEngine?
    private let clock: @Sendable () -> Date
    @ObservationIgnored private var feed = HistoryFeed()
    /// 串行写入者的入口(start 之后、stop 之前非 nil)。
    @ObservationIgnored private var writer: AsyncStream<HistoryIngest>.Continuation?
    @ObservationIgnored private var started = false

    /// `clock` = 每轮落库的采样时刻(MainActor 上现取,顺序即轮次顺序);单测注入。
    init(engine: HistoryEngine?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.clock = clock
    }

    // MARK: - MonitorFeature

    /// 起串行写入者(幂等;引擎缺席不起):先回灌,再按入流顺序逐笔落库 + 读回累计。
    /// 消费者跑在 MainActor 上,落库与累计查询各 await 一次引擎 actor;weak self:
    /// 模块释放后只剩挂起的消费者,stop 收流即退出。
    func start(_ host: MonitorHost) {
        guard !started, let engine else { return }
        started = true
        let (ingests, continuation) = AsyncStream.makeStream(of: HistoryIngest.self)
        writer = continuation
        Task { [weak self] in
            let restored = await engine.importLineage()
            host.restoreBirths(restored)
            for await round in ingests {
                await engine.ingest(round)
                let totals = await engine.networkTotals(now: round.at)
                self?.networkTotals = totals
            }
        }
    }

    /// 本轮落库:内核折出入参(带走磁盘账本),入串行写入流。写入者未起(引擎
    /// 缺席 / 尚未 start / 已 stop)则整轮跳过,账本不动。
    func onRound(_ context: RoundContext) {
        guard let writer else { return }
        writer.yield(feed.takeIngest(from: context, at: clock()))
    }

    // MARK: - 输入与查询

    /// 磁盘吞吐读数(每份交付都送达,含重投的上次好值):恰好一次记账由内核负责
    /// ——driver 重投的同一读数不再记。引擎缺席不记账。
    func diskThroughputDelivered(_ reading: DiskThroughputReading) {
        guard engine != nil else { return }
        feed.recordDiskThroughput(reading)
    }

    /// 历史页查询(工单 p1-history/04):SQL 全在引擎 actor 上执行(后台队列不掉帧,spec User
    /// Story 10);引擎缺席 → nil,页面按"暂无数据"占位,不打断页面。
    func series(
        metric: HistoryMetricKey,
        range: HistoryRange,
        now: Date = Date()
    ) async -> HistorySeries? {
        guard let engine else { return nil }
        return await engine.series(metric: metric, range: range, now: now)
    }

    /// 收流(单测收尾 / SystemMonitor.stop):已入流的入参照常落完,写入者随后退出;
    /// 此后的轮次不再入流。不可重启(与 SystemMonitor.stop 同口径)。
    func stop() {
        writer?.finish()
        writer = nil
    }
}
