import Foundation
import Observation
import PulseCore

/// 历史功能模块(工单 p1-history/03、04、06 的历史管线,ADR-0003 功能模块):@Observable 薄壳 +
/// 纯值内核 HistoryFeed(AlertCenter + AlertEngine 同款样板)。经 SystemMonitor
/// 注册表组装:每轮 onRound 折一笔落库入参;磁盘吞吐交付经磁盘模块的广播
/// (FeatureEvent.diskThroughput)送达;视图直读本模块的 `networkTotals` 与 `series`。
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
    /// 网络 Today/7 天累计(工单 p1-history/06):分钟行落库之后读回(累计只在那时变);库缺席 / 查询失败 / 首笔
    /// 落库前为 nil → 累计列占位。
    private(set) var networkTotals: NetworkTotalsReading?

    private let engine: HistoryEngine?
    private let clock: @Sendable () -> Date
    @ObservationIgnored private var feed = HistoryFeed()
    /// 串行写入流的一笔:轮次落库,或项目根对账(改根迁移组身份)——同一条流保证
    /// 对账与落库按发生次序生效。
    private enum HistoryWrite: Sendable {
        case ingest(HistoryIngest)
        case reconcileProjectRoots([String])
    }

    /// 串行写入者的入口(start 之后、stop 之前非 nil)。
    @ObservationIgnored private var writer: AsyncStream<HistoryWrite>.Continuation?
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
        let (writes, continuation) = AsyncStream.makeStream(of: HistoryWrite.self)
        writer = continuation
        Task { [weak self] in
            let restored = await engine.importLineage()
            host.restoreBirths(restored)
            for await write in writes {
                switch write {
                case let .ingest(round):
                    // 累计只在分钟行落库时才变(当前分钟还在内存缓冲):写了分钟行、尚无
                    // 读数、或落库失败(已发布的读数可能过时,如跨零点)才重查——弹窗 1s
                    // 节奏下每分钟一次而非每轮(乙7)。
                    let outcome = await engine.ingest(round)
                    guard outcome != .buffered || self?.networkTotals == nil else { continue }
                    let totals = await engine.networkTotals(now: round.at)
                    self?.networkTotals = totals
                case let .reconcileProjectRoots(roots):
                    await engine.reconcileProjectRoots(roots)
                }
            }
        }
    }

    /// 本轮落库:内核折出入参(带走磁盘账本),入串行写入流。写入者未起(引擎
    /// 缺席 / 尚未 start / 已 stop)则整轮跳过,账本不动。
    func onRound(_ context: RoundContext) {
        guard let writer else { return }
        writer.yield(.ingest(feed.takeIngest(from: context, at: clock())))
    }

    /// 项目根对账入串行写入流(排在此后的落库之前)。写入者未起则跳过——SystemMonitor
    /// 在模块 start 之后才派发初值。
    func projectRootsChanged(_ roots: [String]) {
        writer?.yield(.reconcileProjectRoots(roots))
    }

    // MARK: - 输入与查询

    /// 磁盘吞吐交付(磁盘模块广播,含标 stale 的重投):恰好一次记账由内核负责
    /// ——只记 fresh。引擎缺席不记账。
    func onEvent(_ event: FeatureEvent) {
        guard engine != nil else { return }
        switch event {
        case let .diskThroughput(delivery):
            feed.recordDiskThroughput(delivery)
        case let .gpuSample(delivery):
            // P2 传感器趋势量(08):三路 30s 历史档广播,fresh 才暂存(feed 内判);
            // 时刻走注入钟(仪表过期判定用,审计⑤)。
            feed.recordGpu(delivery, at: clock())
        case let .smcSample(delivery):
            feed.recordSmc(delivery, at: clock())
        case let .powerSample(delivery):
            feed.recordPower(delivery, at: clock())
        case .diskCapacity, .devServers:
            break
        }
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
