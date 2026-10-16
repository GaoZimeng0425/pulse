import GRDB
import XCTest
@testable import Pulse

/// 历史引擎(工单 03):真 SQLite(内存/临时目录库)+ 显式注入时间,
/// 断言分钟卷积行数与数值、小时二级卷积、按日留存、出生登记持久化与
/// 重启归因、组元数据。5s 原始值不落盘以行数直接证明。
final class HistoryEngineTests: XCTestCase {
    /// 对齐到分钟边界的基准时刻。
    private let minute0 = HistoryWindows.minuteStart(of: Date(timeIntervalSince1970: 1_789_000_000))
    /// 固定时区(当地日界确定性)。
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private var fileURL: URL!
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        fileURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("pulse-engine-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: fileURL.path + suffix)
            )
        }
    }

    // MARK: 夹具

    private func makeMemoryEngine(now: Date) throws -> HistoryEngine {
        queue = try HistoryDatabase.openInMemory()
        return HistoryEngine(database: queue, now: now, calendar: calendar)
    }

    private func makeFileEngine(now: Date) throws -> HistoryEngine {
        queue = try HistoryDatabase.open(at: fileURL)
        return HistoryEngine(database: queue, now: now, calendar: calendar)
    }

    private func app(_ name: String) -> GroupIdentity {
        .app(bundlePath: "/Applications/\(name).app")
    }

    private func ingest(
        _ engine: HistoryEngine,
        at now: Date,
        load: Double = 10,
        groups: [GroupSample],
        names: [GroupIdentity: String]? = nil,
        lineage: LineageRegistry = LineageRegistry()
    ) async {
        let displayNames = names ?? Dictionary(
            uniqueKeysWithValues: groups.map { ($0.id, Self.title(of: $0.id)) }
        )
        await engine.ingest(
            at: now,
            systemLoad: load,
            groups: groups,
            displayNames: displayNames,
            lineage: lineage
        )
    }

    private static func title(of identity: GroupIdentity) -> String {
        switch identity {
        case .app(let path):
            String((path as NSString).lastPathComponent.dropLast(4))
        case .project(let root, _):
            (root as NSString).lastPathComponent
        case .system: "系统"
        case .backgroundService: "后台服务"
        case .orphan: "孤儿进程"
        }
    }

    private func scalarInt(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> Int {
        try XCTUnwrap(
            queue.read { db in
                try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments))
            }
        )
    }

    private func scalarDouble(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> Double {
        try XCTUnwrap(
            queue.read { db in
                try Double.fetchOne(db, sql: sql, arguments: StatementArguments(arguments))
            }
        )
    }

    private func scalarString(_ sql: String, _ arguments: [DatabaseValueConvertible] = []) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: 分钟卷积:5s 原始值不落盘

    /// 验收②:同一分钟内 12 轮 5s 采样(2 组 = 24 个原始点),库里只有每
    /// 组 1 行 + 系统级 1 行;聚合列逐一对得上。
    func testFiveSecondSamplesConvolveIntoOneRowPerGroupPerMinute() async throws {
        let engine = try makeMemoryEngine(now: minute0)
        let alpha = app("Alpha")
        let beta = GroupIdentity.project(root: "/Users/x/beta", worktreeName: nil)

        for step in 0..<12 {
            await ingest(
                engine,
                at: minute0.addingTimeInterval(TimeInterval(step * 5)),
                load: Double(step),
                groups: [
                    GroupSample(
                        id: alpha,
                        cpuPercent: Double(step),
                        memoryBytes: UInt64(step) * 100,
                        processCount: step
                    ),
                    GroupSample(id: beta, cpuPercent: 7, memoryBytes: 50, processCount: 1),
                ]
            )
        }
        // 跨入下一分钟的第一轮:上一分钟冲刷成行。
        await ingest(engine, at: minute0.addingTimeInterval(60), load: 99, groups: [])

        let groupRows = try scalarInt("SELECT count(*) FROM sample_min")
        let systemRows = try scalarInt("SELECT count(*) FROM system_min")
        XCTAssertEqual(groupRows, 2, "24 个 5s 原始点只允许落 2 行分钟聚合")
        XCTAssertEqual(systemRows, 1)

        let ts = try scalarInt("SELECT ts FROM sample_min WHERE group_id = ?", [alpha.stableKey])
        XCTAssertEqual(ts, HistoryWindows.epochSeconds(of: minute0))
        // alpha:均值 (0+1+…+11)/12 = 5.5,峰值 11,内存峰值 1100,进程峰值 11。
        XCTAssertEqual(
            try scalarDouble("SELECT cpu_avg FROM sample_min WHERE group_id = ?", [alpha.stableKey]),
            5.5, accuracy: 0.0001
        )
        XCTAssertEqual(
            try scalarDouble("SELECT cpu_max FROM sample_min WHERE group_id = ?", [alpha.stableKey]),
            11, accuracy: 0.0001
        )
        XCTAssertEqual(
            try scalarInt("SELECT mem_max FROM sample_min WHERE group_id = ?", [alpha.stableKey]),
            1_100
        )
        XCTAssertEqual(
            try scalarInt("SELECT procs FROM sample_min WHERE group_id = ?", [alpha.stableKey]),
            11
        )
        XCTAssertEqual(
            try scalarDouble("SELECT load_avg FROM system_min"),
            5.5, accuracy: 0.0001
        )
        XCTAssertEqual(try scalarDouble("SELECT load_max FROM system_min"), 11, accuracy: 0.0001)
    }

    /// 验收:所有组都记(行数断言)——五类身份各一行,组元数据齐全。
    func testAllGroupsAreRecordedWithDisplayMetadata() async throws {
        let engine = try makeMemoryEngine(now: minute0)
        let project = GroupIdentity.project(root: "/Users/x/pulse", worktreeName: "03")
        let identities: [GroupIdentity] = [
            app("Alpha"), project, .system, .backgroundService, .orphan,
        ]

        await ingest(
            engine,
            at: minute0,
            groups: identities.map { GroupSample(id: $0, cpuPercent: 1, memoryBytes: 1) }
        )
        await ingest(engine, at: minute0.addingTimeInterval(60), load: 0, groups: [])

        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_min"), 5)
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM groups"), 5)
        // 项目组的 project_root 落根路径,其余类别为 NULL;类别与身份种类一致。
        XCTAssertEqual(
            try scalarString("SELECT project_root FROM groups WHERE group_id = ?", [project.stableKey]),
            "/Users/x/pulse"
        )
        XCTAssertNil(
            try scalarString("SELECT project_root FROM groups WHERE group_id = ?", ["orphan"])
        )
        XCTAssertEqual(
            try scalarString("SELECT category FROM groups WHERE group_id = ?", [project.stableKey]),
            "project"
        )
        XCTAssertEqual(
            try scalarString("SELECT name FROM groups WHERE group_id = ?", [app("Alpha").stableKey]),
            "Alpha"
        )
    }

    /// app 未运行/睡眠的分钟不补零:跳过的窗口没有行。
    func testSkippedMinutesLeaveNoRows() async throws {
        let engine = try makeMemoryEngine(now: minute0)

        await ingest(engine, at: minute0, groups: [GroupSample(id: .orphan, cpuPercent: 1, memoryBytes: 1)])
        await ingest(engine, at: minute0.addingTimeInterval(60), groups: [GroupSample(id: .orphan, cpuPercent: 2, memoryBytes: 1)])
        // 三分钟静默后恢复采样:只冲刷有样本的分钟。
        await ingest(engine, at: minute0.addingTimeInterval(240), groups: [GroupSample(id: .orphan, cpuPercent: 3, memoryBytes: 1)])

        // 分钟行 = 各"已完整"的窗口(尾分钟要等下一次采样才冲刷);
        // 中间静默的 +120/+180 没有行——不补零。
        let minutes = try await queue.read { db in
            try Int.fetchAll(db, sql: "SELECT ts FROM system_min ORDER BY ts")
        }
        XCTAssertEqual(
            minutes,
            [
                HistoryWindows.epochSeconds(of: minute0),
                HistoryWindows.epochSeconds(of: minute0.addingTimeInterval(60)),
            ]
        )
    }

    // MARK: 小时二级卷积

    /// 小时表由分钟表再卷积:AVG(cpu_avg)/MAX(cpu_max)/MAX(mem)/MAX(procs),
    /// 分钟行保留(7 天明细)。
    func testHourTableAggregatesFromMinuteRows() async throws {
        let engine = try makeMemoryEngine(now: minute0)
        let alpha = app("Alpha")

        // 小时 H 的 25、26 两个分钟窗。
        await ingest(engine, at: minute0.addingTimeInterval(25 * 60), load: 10, groups: [GroupSample(id: alpha, cpuPercent: 10, memoryBytes: 1_000, processCount: 2)])
        await ingest(engine, at: minute0.addingTimeInterval(26 * 60), load: 30, groups: [GroupSample(id: alpha, cpuPercent: 30, memoryBytes: 3_000, processCount: 4)])
        await ingest(engine, at: minute0.addingTimeInterval(27 * 60), load: 20, groups: [])
        // 本小时不卷积(小时未完),分钟行已落。
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_min"), 2)
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_hour"), 0)

        // 跨入下一小时的第一轮:上一小时完整 → 卷积。
        await ingest(engine, at: minute0.addingTimeInterval(3600 + 5), load: 1, groups: [])

        let hourTs = HistoryWindows.epochSeconds(of: HistoryWindows.hourStart(of: minute0))
        XCTAssertEqual(
            try scalarDouble("SELECT cpu_avg FROM sample_hour WHERE group_id = ?", [alpha.stableKey]),
            20, accuracy: 0.0001
        )
        XCTAssertEqual(
            try scalarDouble("SELECT cpu_max FROM sample_hour WHERE group_id = ?", [alpha.stableKey]),
            30, accuracy: 0.0001
        )
        XCTAssertEqual(
            try scalarInt("SELECT mem_max FROM sample_hour WHERE group_id = ?", [alpha.stableKey]),
            3_000
        )
        XCTAssertEqual(
            try scalarInt("SELECT procs FROM sample_hour WHERE group_id = ?", [alpha.stableKey]),
            4
        )
        XCTAssertEqual(try scalarInt("SELECT ts FROM sample_hour"), hourTs)
        XCTAssertEqual(try scalarDouble("SELECT load_avg FROM system_hour"), 20, accuracy: 0.0001)
        XCTAssertEqual(try scalarDouble("SELECT load_max FROM system_hour"), 30, accuracy: 0.0001)
        // 分钟明细保留。
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_min"), 2)
    }

    /// 启动恢复:上一会话遗留的分钟行(未及小时卷积)在新引擎打开时补齐。
    func testStartupRecoversUnrolledHours() async throws {
        let engineA = try makeFileEngine(now: minute0)
        await ingest(engineA, at: minute0, load: 12, groups: [GroupSample(id: .orphan, cpuPercent: 8, memoryBytes: 10)])
        await ingest(engineA, at: minute0.addingTimeInterval(60), load: 0, groups: [])
        // 模拟"会话在小时中途结束":手动清掉小时表,只留分钟行。
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM sample_hour")
            try db.execute(sql: "DELETE FROM system_hour")
        }

        // "重启"(且已跨入下一小时):新引擎打开同一文件 → 启动补卷积
        // 把上一会话的完整小时补齐。
        _ = try makeFileEngine(now: minute0.addingTimeInterval(3600))

        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_hour"), 1)
        XCTAssertEqual(try scalarDouble("SELECT load_avg FROM system_hour"), 12, accuracy: 0.0001)
    }

    // MARK: 留存清理

    /// 分钟 7 天 / 小时 30 天,随每日首次 rollup 顺带;同日不重复清理。
    func testRetentionPurgesOnFirstRollupOfEachLocalDay() async throws {
        let day0 = calendar.startOfDay(for: minute0)
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 30, second: 0, of: day0))
        let engine = try makeFileEngine(now: noon)
        let orphan = GroupSample(id: .orphan, cpuPercent: 1, memoryBytes: 1)

        // 第 0 天:落一分钟数据并在跨分钟时冲刷。
        await ingest(engine, at: noon, load: 10, groups: [orphan])
        await ingest(engine, at: noon.addingTimeInterval(60), load: 0, groups: [])
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_min"), 1)

        // 第 8 天:过期清理(分钟 < now-7d 删,小时保留),旧分钟已卷积进小时。
        let day8 = try XCTUnwrap(calendar.date(byAdding: .day, value: 8, to: noon))
        await ingest(engine, at: day8, load: 10, groups: [orphan])
        await ingest(engine, at: day8.addingTimeInterval(60), load: 0, groups: [])
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_min"), 1, "第 0 天的分钟行应被清理")
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_hour"), 1, "第 0 天数据以小时粒度保留")
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM system_hour"), 1)

        // 第 45 天:小时表也过期(> 30 天)。
        let day45 = try XCTUnwrap(calendar.date(byAdding: .day, value: 45, to: noon))
        await ingest(engine, at: day45, load: 10, groups: [orphan])
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM sample_hour"), 0)
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM system_hour"), 0)
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM system_min"), 0)
    }

    // MARK: 出生登记持久化(重启保归因)

    /// 验收③:登记落库 → "重启"(重开同一库)回灌 → 断链进程仍归原宿主;
    /// 重复登记不产生重复行。
    func testLineagePersistsAndRestoresAttributionAfterRestart() async throws {
        let hostEntry = LineageRegistry.Entry(
            parentPID: 1,
            identity: ProcessIdentity(
                executablePath: "/Applications/Host.app/Contents/MacOS/Host",
                cwd: "/Users/x",
                argv: ["/Applications/Host.app/Contents/MacOS/Host"]
            )
        )
        let workerEntry = LineageRegistry.Entry(
            parentPID: 100,
            identity: ProcessIdentity(
                executablePath: "/usr/local/bin/worker",
                cwd: "/Users/x/work",
                argv: ["worker", "--fast"]
            )
        )
        var preRestart = LineageRegistry()
        preRestart.register(pid: 100, entry: hostEntry)
        preRestart.register(pid: 200, entry: workerEntry)

        let engineA = try makeFileEngine(now: minute0)
        await ingest(engineA, at: minute0, load: 1, groups: [], lineage: preRestart)
        await ingest(engineA, at: minute0.addingTimeInterval(5), load: 1, groups: [], lineage: preRestart)
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM lineage"), 2, "重复登记不重复落行")
        XCTAssertEqual(
            try scalarDouble("SELECT first_seen FROM lineage WHERE pid = 200"),
            Double(HistoryWindows.epochSeconds(of: minute0)), accuracy: 0.001
        )

        // "重启":同一库文件、全新引擎。
        let engineB = try makeFileEngine(now: minute0.addingTimeInterval(120))
        let restored = await engineB.importLineage()

        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.entries[200]?.parentPID, 100)
        XCTAssertEqual(restored.entries[200]?.identity.executablePath, "/usr/local/bin/worker")
        XCTAssertEqual(restored.entries[200]?.identity.cwd, "/Users/x/work")
        XCTAssertEqual(restored.entries[200]?.identity.argv, ["worker", "--fast"])
        XCTAssertEqual(
            restored.entries[100]?.identity.executablePath,
            "/Applications/Host.app/Contents/MacOS/Host"
        )

        // 断链归因:worker(pid 200)重挂 launchd、活链断,登记链回查仍归宿主 App。
        let snapshot = ProcessSnapshot(
            takenAt: minute0.addingTimeInterval(180),
            processes: [
                RawProcess(
                    pid: 200,
                    parentPID: 1,
                    executablePath: "/usr/local/bin/worker",
                    argv: ["worker"]
                )
            ]
        )
        let groups = GroupingEngine.groups(from: snapshot, lineage: restored)
        XCTAssertEqual(groups.map(\.id), [.app(bundlePath: "/Applications/Host.app")])
    }

    // MARK: 组元数据

    /// 改名才重写:同会话内改名后 groups 表跟着更新。
    func testGroupRenameUpdatesMetadataRow() async throws {
        let engine = try makeMemoryEngine(now: minute0)
        let alpha = app("Alpha")

        await ingest(engine, at: minute0, groups: [GroupSample(id: alpha, cpuPercent: 1, memoryBytes: 1)])
        await ingest(
            engine,
            at: minute0.addingTimeInterval(5),
            groups: [GroupSample(id: alpha, cpuPercent: 1, memoryBytes: 1)],
            names: [alpha: "Alpha Renamed"]
        )

        XCTAssertEqual(
            try scalarString("SELECT name FROM groups WHERE group_id = ?", [alpha.stableKey]),
            "Alpha Renamed"
        )
        XCTAssertEqual(try scalarInt("SELECT count(*) FROM groups"), 1)
    }
}
