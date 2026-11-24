import GRDB
@testable import PulseCore
import XCTest

/// 组级磁盘账(arch-review-2026-11-24/04 方案 C):快照里的进程累计读写字节 →
/// GroupDiskLedger 差分 → HistoryFeed 折入参 → HistoryEngine 真落库 → InsightQuery
/// 排行 → MCP 文案。闭环测试只经生产写入路径造数据,不手写 sample_min 行。
final class GroupDiskIOTests: XCTestCase {
    /// 整点对齐,便于小时卷积断言。
    private let hour0 = Date(timeIntervalSince1970: Double(1_789_000_000 / 3600 * 3600))
    private let waifuXMain = "/Applications/WaifuX.app/Contents/MacOS/WaifuX"
    private let waifuXHelper = "/Applications/WaifuX.app/Contents/Frameworks/WaifuX Helper.app/Contents/MacOS/WaifuX Helper"
    private let zedMain = "/Applications/Zed.app/Contents/MacOS/zed"
    private let waifuX = GroupIdentity.app(bundlePath: "/Applications/WaifuX.app")
    private let zed = GroupIdentity.app(bundlePath: "/Applications/Zed.app")

    // MARK: 账本口径

    private func group(_ id: GroupIdentity, _ processes: [RawProcess]) -> ProcessGroup {
        ProcessGroup(id: id, name: "g", processes: processes, cpuPercent: 0, memoryBytes: 0)
    }

    private func process(
        _ pid: pid_t, read: UInt64, write: UInt64 = 0,
        available: Bool = true, start: Date? = nil
    ) -> RawProcess {
        RawProcess(
            pid: pid, parentPID: 1,
            diskBytesRead: read, diskBytesWritten: write,
            countersAvailable: available, startTime: start
        )
    }

    func testFirstSightingOnlySetsBaseline() {
        var ledger = GroupDiskLedger()
        let deltas = ledger.advance(groups: [group(waifuX, [process(50, read: 9_000_000, write: 7)])])
        XCTAssertEqual(deltas[waifuX], .zero, "终身累计不能当成一轮增量")
    }

    func testDeltaSumsProcessesWithinGroup() {
        var ledger = GroupDiskLedger()
        _ = ledger.advance(groups: [group(waifuX, [process(50, read: 100, write: 10), process(51, read: 0)])])
        let deltas = ledger.advance(groups: [group(waifuX, [process(50, read: 400, write: 30), process(51, read: 50)])])
        XCTAssertEqual(deltas[waifuX], GroupDiskDelta(readBytes: 350, writeBytes: 20))
    }

    func testUnavailableCountersDropBaselineAndRecoverWithoutSpike() {
        var ledger = GroupDiskLedger()
        _ = ledger.advance(groups: [group(waifuX, [process(50, read: 100)])])
        let failed = ledger.advance(groups: [group(waifuX, [process(50, read: 0, available: false)])])
        XCTAssertEqual(failed[waifuX], .zero)
        let recovered = ledger.advance(groups: [group(waifuX, [process(50, read: 500)])])
        XCTAssertEqual(recovered[waifuX], .zero, "恢复那一轮只重立基线")
        let next = ledger.advance(groups: [group(waifuX, [process(50, read: 600)])])
        XCTAssertEqual(next[waifuX], GroupDiskDelta(readBytes: 100, writeBytes: 0))
    }

    func testPidReuseAndCounterRegressionRebaseline() {
        var ledger = GroupDiskLedger()
        let first = Date(timeIntervalSince1970: 1)
        let reborn = Date(timeIntervalSince1970: 2)
        _ = ledger.advance(groups: [group(waifuX, [process(50, read: 100, start: first)])])
        let reused = ledger.advance(groups: [group(zed, [process(50, read: 900, start: reborn)])])
        XCTAssertEqual(reused[zed], .zero, "pid 复用 = 新进程,不继承旧基线")
        let regressed = ledger.advance(groups: [group(zed, [process(50, read: 10, start: reborn)])])
        XCTAssertEqual(regressed[zed], .zero, "计数回退钳零")
    }

    func testAbsentPidIsEvicted() {
        var ledger = GroupDiskLedger()
        _ = ledger.advance(groups: [group(waifuX, [process(50, read: 100)])])
        _ = ledger.advance(groups: [])
        let back = ledger.advance(groups: [group(waifuX, [process(50, read: 900)])])
        XCTAssertEqual(back[waifuX], .zero, "缺席一轮即逐出,回来按首见处理")
    }

    // MARK: 生产路径闭环

    private struct Proc {
        let pid: pid_t
        let parent: pid_t
        let path: String
        let read: UInt64
        let write: UInt64
    }

    /// 一轮:真主干归组 → 真喂料内核折入参 → 真引擎落库。
    private func round(
        _ procs: [Proc], at date: Date,
        spine: inout RoundSpine, feed: inout HistoryFeed,
        previous: inout ProcessSnapshot?, engine: HistoryEngine
    ) async {
        let snapshot = ProcessSnapshot(takenAt: date, processes: procs.map {
            RawProcess(
                pid: $0.pid, parentPID: $0.parent, executablePath: $0.path,
                diskBytesRead: $0.read, diskBytesWritten: $0.write
            )
        })
        let context = spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: previous, current: snapshot),
            cpu: .zero, memory: nil, network: nil, rankings: .empty
        ))
        previous = snapshot
        await engine.ingest(feed.takeIngest(from: context, at: date))
    }

    func testProductionPathFeedsTopDiskIO() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let engine = HistoryEngine(database: queue, now: hour0)
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        var feed = HistoryFeed()
        var previous: ProcessSnapshot?

        // r0 立基线;r1 WaifuX 主进程 +3000/+200、Helper 首见、Zed +500;
        // r2 Helper +1000;r3 跨分钟冲刷。
        await round([
            Proc(pid: 50, parent: 1, path: waifuXMain, read: 1000, write: 100),
            Proc(pid: 60, parent: 1, path: zedMain, read: 5000, write: 0),
        ], at: hour0, spine: &spine, feed: &feed, previous: &previous, engine: engine)
        await round([
            Proc(pid: 50, parent: 1, path: waifuXMain, read: 4000, write: 300),
            Proc(pid: 51, parent: 50, path: waifuXHelper, read: 9999, write: 0),
            Proc(pid: 60, parent: 1, path: zedMain, read: 5500, write: 0),
        ], at: hour0.addingTimeInterval(5), spine: &spine, feed: &feed, previous: &previous, engine: engine)
        await round([
            Proc(pid: 50, parent: 1, path: waifuXMain, read: 4000, write: 300),
            Proc(pid: 51, parent: 50, path: waifuXHelper, read: 10999, write: 0),
            Proc(pid: 60, parent: 1, path: zedMain, read: 5500, write: 0),
        ], at: hour0.addingTimeInterval(10), spine: &spine, feed: &feed, previous: &previous, engine: engine)
        await round(
            [],
            at: hour0.addingTimeInterval(60),
            spine: &spine,
            feed: &feed,
            previous: &previous,
            engine: engine
        )

        let now = hour0.addingTimeInterval(120)
        let top = try await queue.read { db in
            try InsightQuery.topDiskGroups(limit: 5, lookbackMinutes: 10, now: now, in: db)
        }
        XCTAssertEqual(top.map(\.groupID), [waifuX.stableKey, zed.stableKey])
        XCTAssertEqual(top[0].readBytes, 4000)
        XCTAssertEqual(top[0].writtenBytes, 200)
        XCTAssertEqual(top[1].readBytes, 500)
        XCTAssertFalse(top.contains(where: \.hasNullMinutes), "生产写入的分钟行不该缺账")

        let text = McpEyesText.diskRanking(top, lookbackMinutes: 10, now: now)
        XCTAssertTrue(text.contains("1. WaifuX"), text)
        XCTAssertFalse(text.contains("缺磁盘账"), text)
    }

    /// 列级契约:生产写入路径(分钟冲刷 + 小时卷积)写满组级 / 系统级四张表的
    /// 每一列——查询读的列若没有写入方,这里第一时间变红(防 disk_r 恒空复发)。
    func testProductionPathLeavesNoNullColumns() async throws {
        let queue = try HistoryDatabase.openInMemory()
        let engine = HistoryEngine(database: queue, now: hour0)
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        var feed = HistoryFeed()
        var previous: ProcessSnapshot?

        for (offset, read) in [(0.0, UInt64(100)), (5, 300), (60, 700), (65, 1000)] {
            await round(
                [Proc(pid: 50, parent: 1, path: waifuXMain, read: read, write: read / 10)],
                at: hour0.addingTimeInterval(offset),
                spine: &spine, feed: &feed, previous: &previous, engine: engine
            )
        }
        // 跨入下一小时:冲刷第二分钟并卷积整点小时。
        await round(
            [],
            at: hour0.addingTimeInterval(3600),
            spine: &spine,
            feed: &feed,
            previous: &previous,
            engine: engine
        )

        let key = waifuX.stableKey
        let hourDiskRead = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT disk_r FROM sample_hour WHERE group_id = ?", arguments: [key])
        }
        XCTAssertEqual(hourDiskRead, 900, "小时卷积对分钟增量求和(200 + 700),不取峰值")

        for table in ["sample_min", "system_min", "sample_hour", "system_hour"] {
            let (rows, nullCells) = try await queue.read { db -> (Int, [String]) in
                let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                let columns = try db.columns(in: table).map(\.name)
                var nulls: [String] = []
                for column in columns {
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NULL") ?? 0
                    if count > 0 {
                        nulls.append(column)
                    }
                }
                return (rows, nulls)
            }
            XCTAssertGreaterThan(rows, 0, "\(table) 应有生产写入的行")
            XCTAssertEqual(nullCells, [], "\(table) 有列没有生产写入方")
        }
    }
}
