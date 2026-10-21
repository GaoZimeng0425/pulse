import GRDB
@testable import Pulse
@testable import PulseCore
import XCTest

/// 历史功能模块薄壳(HistoryFeature)唯一的壳层测试:真 SQLite 内存库(绝不开生产库)
/// + 注入时钟,钉住逐轮落库经单一串行写入者、严格按轮次顺序生效,累计在每笔落库之后
/// 读回发布。其余逻辑在纯内核 HistoryFeed(HistoryFeedTests);壳层不另测(2026-10-19
/// 拍板:测试只写在 RoundSpine / Leaderboard / 各模块纯内核这些接缝上)。
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
            lock.lock()
            defer { lock.unlock() }
            return times.removeFirst()
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
                    SystemMinuteRow(
                        ts: row["ts"],
                        loadAverage: row["load_avg"],
                        loadPeak: row["load_max"],
                        netRx: row["net_rx"]
                    )
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
        feature.start(.inert)
        defer { feature.stop() }

        for (load, down) in zip([10.0, 20, 30, 50, 70], [UInt64(100), 200, 300, 400, 500]) {
            feature.onRound(round(load: load, netDown: down))
        }
        await waitUntil("五笔落库后的累计") { feature.networkTotals?.todayDownBytes == 1000 }

        let minute0Seconds = HistoryWindows.epochSeconds(of: minute0)
        XCTAssertEqual(try systemMinuteRows(in: queue), [
            SystemMinuteRow(ts: minute0Seconds, loadAverage: 20, loadPeak: 30, netRx: 600),
            SystemMinuteRow(ts: minute0Seconds + 60, loadAverage: 50, loadPeak: 50, netRx: 400),
        ])
        XCTAssertEqual(feature.networkTotals?.weekDownBytes, 1000)
        XCTAssertEqual(feature.networkTotals?.todayUpBytes, 0)
    }
}
