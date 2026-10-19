import GRDB
import XCTest
@testable import Pulse

/// 历史功能模块薄壳(HistoryFeature):真 SQLite 内存库(绝不开生产库)+ 注入时钟。
/// 钉住壳的接线:start 把库中出生登记交给回灌出口;逐轮落库经单一串行写入者、严格
/// 按轮次顺序生效,累计在每笔落库之后读回发布;引擎缺席整体降级;SystemMonitor
/// 登记了它,每轮心跳真的流到库里。
@MainActor
final class HistoryFeatureTests: XCTestCase {
    /// 对齐到分钟边界的基准时刻。
    private let minute0 = HistoryWindows.minuteStart(of: Date(timeIntervalSince1970: 1_789_000_000))
    /// 固定时区(当地日界确定性,累计查询以当地零点为日界)。
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    // MARK: - 测试替身

    /// 跨并发域的步进时钟:每取一次数前进到下一个预设时刻。
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date]

        init(_ times: [Date]) {
            self.times = times
        }

        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            return times.removeFirst()
        }
    }

    /// 回灌出口的收件箱(MainActor 上收)。
    @MainActor
    private final class RestoreInbox {
        private(set) var received: [LineageRegistry] = []

        func receive(_ lineage: LineageRegistry) {
            received.append(lineage)
        }
    }

    /// 一轮主干上下文:空进程表(只关心系统行),系统负载与网络下行增量按需给。
    private func round(load: Double, netDown: UInt64) -> RoundContext {
        let snapshot = ProcessSnapshot(takenAt: minute0, processes: [])
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: nil, current: snapshot),
            cpu: CPULoadBreakdown(total: load, user: load, system: 0),
            memory: nil,
            network: NetworkRoundResult(
                interface: "en0",
                rates: .zero,
                upBytesDelta: 0,
                downBytesDelta: netDown
            ),
            rankings: .empty
        ))
    }

    /// system_min 的一行(ts / 负载均值 / 负载峰值 / 下行增量)。
    private struct SystemMinuteRow: Equatable {
        let ts: Int
        let loadAverage: Double
        let loadPeak: Double
        let netRx: Int64
    }

    private func systemMinuteRows(in queue: DatabaseQueue) throws -> [SystemMinuteRow] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, load_avg, load_max, net_rx FROM system_min ORDER BY ts")
                .map { row in
                    SystemMinuteRow(ts: row["ts"], loadAverage: row["load_avg"], loadPeak: row["load_max"], netRx: row["net_rx"])
                }
        }
    }

    /// 等到条件成立(MainActor 让出,写入者得以推进);超时记失败。
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            XCTFail("等待超时(\(timeout)s):\(what)")
        }
    }

    // MARK: - 串行写入:严格按轮次顺序

    /// 五轮背靠背喂入(中间不让出):分钟 0 三轮(负载 10/20/30,下行 100/200/300)、
    /// 分钟 1 一轮(50 / 400)、分钟 2 一轮(70 / 500,冲刷分钟 1)。按序生效 →
    /// 分钟 0 行 = 均值 20 / 峰值 30 / 下行 600,分钟 1 行 = 50 / 50 / 400;分钟 2 仍在
    /// 内存缓冲。累计在最后一笔落库后读回:今日下行 = 600 + 400 = 1000。
    /// (乱序落库时迟到的旧分钟样本会被缓冲丢弃,行与累计都会少。)
    func testRoundsFedBackToBackLandInRoundOrderAndTotalsFollowTheLastIngest() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let engine = HistoryEngine(database: queue, now: minute0, calendar: calendar)
        let clock = SteppingClock([5, 10, 15, 65, 125].map { minute0.addingTimeInterval($0) })
        let feature = HistoryFeature(engine: engine, clock: { clock.next() })
        feature.start()
        defer { feature.stop() }

        for (load, down) in zip([10.0, 20, 30, 50, 70], [UInt64(100), 200, 300, 400, 500]) {
            feature.onRound(round(load: load, netDown: down))
        }
        await waitUntil("五笔落库后的累计") { feature.networkTotals?.todayDownBytes == 1_000 }

        let minute0Seconds = HistoryWindows.epochSeconds(of: minute0)
        XCTAssertEqual(try systemMinuteRows(in: queue), [
            SystemMinuteRow(ts: minute0Seconds, loadAverage: 20, loadPeak: 30, netRx: 600),
            SystemMinuteRow(ts: minute0Seconds + 60, loadAverage: 50, loadPeak: 50, netRx: 400),
        ])
        XCTAssertEqual(feature.networkTotals?.weekDownBytes, 1_000)
        XCTAssertEqual(feature.networkTotals?.todayUpBytes, 0)
    }

    // MARK: - 回灌

    /// 上一会话落过库的出生登记(worker 200 生在 host 100 下):新会话 start 后经
    /// 回灌出口交出一次,字段原样。
    func testStartHandsLineageRestoredFromTheDatabaseToTheRestoreOutlet() async throws {
        let queue = try HistoryDatabase.openInMemory()
        var births = LineageRegistry()
        births.register(pid: 200, entry: LineageRegistry.Entry(
            parentPID: 100,
            identity: ProcessIdentity(executablePath: "/usr/local/bin/worker", cwd: "/Users/x/work", argv: ["worker"])
        ))
        let previousSession = HistoryEngine(database: queue, now: minute0, calendar: calendar)
        await previousSession.ingest(at: minute0, systemLoad: 1, groups: [], displayNames: [:], lineage: births)

        let feature = HistoryFeature(
            engine: HistoryEngine(database: queue, now: minute0.addingTimeInterval(120), calendar: calendar)
        )
        let inbox = RestoreInbox()
        feature.onLineageRestored = { inbox.receive($0) }
        feature.start()
        defer { feature.stop() }
        await waitUntil("回灌交出") { !inbox.received.isEmpty }

        XCTAssertEqual(inbox.received.count, 1)
        let restored = try XCTUnwrap(inbox.received.first)
        XCTAssertEqual(restored.entries.keys.sorted(), [200])
        XCTAssertEqual(restored.entries[200]?.parentPID, 100)
        XCTAssertEqual(restored.entries[200]?.executablePath, "/usr/local/bin/worker")
    }

    // MARK: - 引擎缺席

    /// 库打开失败的降级路径:start 不起写入者、不回灌;喂轮次与磁盘读数都不发布
    /// 累计;查询 nil。
    func testWithoutEngineNothingIsRestoredOrPublishedAndSeriesIsNil() async {
        let feature = HistoryFeature(engine: nil)
        let inbox = RestoreInbox()
        feature.onLineageRestored = { inbox.receive($0) }

        feature.start()
        feature.recordDiskThroughput(DiskThroughputReading(current: .zero, trend: [], readBytesDelta: 4_096))
        feature.onRound(round(load: 10, netDown: 100))
        await Task.yield()
        let series = await feature.series(metric: .systemLoad, range: .hour1, now: minute0)

        XCTAssertNil(feature.networkTotals)
        XCTAssertTrue(inbox.received.isEmpty)
        XCTAssertNil(series)
    }

    // MARK: - SystemMonitor 接线

    /// SystemMonitor 构造即登记历史模块:start 后首轮心跳经 onRound 落进注入的内存库,
    /// 累计读回发布到 `monitor.history`(惰性网络源 → 增量 0,累计全 0 而非 nil)。
    func testSystemMonitorFeedsRoundsIntoItsHistoryFeature() async throws {
        let monitor = SystemMonitor(
            source: SyntheticProcessSource(processes: [
                RawProcess(pid: 50, parentPID: 1, executablePath: "/Applications/WaifuX.app/Contents/MacOS/WaifuX"),
            ]),
            coreTicks: InertCoreTickSource(),
            memoryStats: InertMemoryStatsSource(),
            networkCounters: InertNetworkCountersSource(),
            projectRoots: [],
            killService: InertKillService(),
            birthScanSource: InertBirthScanSource(),
            historyEngine: HistoryEngine(database: try HistoryDatabase.openInMemory()),
            batterySource: InertBatterySource(),
            diskCapacitySource: InertDiskCapacitySource(),
            diskThroughputSource: { _ in InertDiskThroughputSource() },
            nettopSource: InertNettopCSVSource(),
            devServerPortScanner: InertDevServerPortScanner(),
            alertCenter: AlertCenter.inert()
        )

        monitor.start()
        defer { monitor.stop() }
        await waitUntil("首笔落库后的累计") { monitor.history.networkTotals != nil }

        XCTAssertEqual(monitor.history.networkTotals, NetworkTotalsReading(
            todayDownBytes: 0, todayUpBytes: 0, weekDownBytes: 0, weekUpBytes: 0
        ))
    }
}
