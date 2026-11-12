import GRDB
@testable import PulseCore
import XCTest

/// mcp-eyes(01+02):内存/磁盘排行、进程档案、告警历史与 dev server 状态的
/// 查询/落盘/文案——真 SQLite 内存库直插夹具,同 InsightQueryTests 纪律。
final class McpEyesTests: XCTestCase {
    private var base: Int {
        1_789_000_000 / 60 * 60
    }

    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try HistoryDatabase.openInMemory()
    }

    private var now: Date {
        Date(timeIntervalSince1970: Double(base + 60))
    }

    // MARK: 夹具

    private func insertSample(
        _ ts: Int, _ groupID: String, mem: Int, procs: Int,
        diskRead: Int?? = nil, diskWritten: Int?? = nil
    ) throws {
        // diskRead/diskWritten 用双层可选:nil 外层 = 不写列(行内 NULL)。
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sample_min (ts, group_id, cpu_avg, cpu_max, mem_max, procs, disk_r, disk_w)
                VALUES (?, ?, 0, 0, ?, ?, ?, ?)
                """,
                arguments: [ts, groupID, mem, procs, diskRead ?? nil, diskWritten ?? nil]
            )
        }
    }

    private func insertLineage(
        _ pid: Int, parent: Int, executable: String?, cwd: String?, argv: String?, firstSeen: Double
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO lineage (pid, parent_pid, executable_path, cwd, argv, first_seen) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [pid, parent, executable, cwd, argv, firstSeen]
            )
        }
    }

    // MARK: 内存排行(mcp-eyes/01)

    func testTopMemoryGroupsOrderByWindowAverageDesc() throws {
        try insertSample(base - 540, "a", mem: 1000, procs: 1)
        try insertSample(base - 60, "a", mem: 3000, procs: 2)
        try insertSample(base - 540, "b", mem: 2500, procs: 4)
        try insertSample(base - 700, "c", mem: 999_999, procs: 9) // 窗口外(超出 10 分钟)
        try queue.write { db in
            try db
                .execute(
                    sql: "INSERT INTO groups (group_id, name, category, project_root) VALUES ('b', '浏览器', 'app', '/dev/proj')"
                )
        }

        let top = try queue.read { db in
            try InsightQuery.topMemoryGroups(limit: 5, lookbackMinutes: 10, now: now, in: db)
        }
        XCTAssertEqual(top.map(\.groupID), ["b", "a"], "按窗口内均值降序,窗口外高分不进")
        XCTAssertEqual(top.first?.name, "浏览器", "JOIN groups 取人读名")
        XCTAssertEqual(top.first?.projectRoot, "/dev/proj")
        XCTAssertEqual(top.last?.memoryAverageBytes, 2000, "a 均值 (1000+3000)/2")
        XCTAssertEqual(top.last?.memoryPeakBytes, 3000)
        XCTAssertEqual(top.last?.processCount, 2, "窗口内最新一行的进程数")
    }

    // MARK: 磁盘排行(mcp-eyes/01)

    func testTopDiskGroupsSumsWindowAndFlagsNullMinutes() throws {
        try insertSample(base - 540, "a", mem: 0, procs: 1, diskRead: 100, diskWritten: 50)
        try insertSample(base - 60, "a", mem: 0, procs: 1, diskRead: 300, diskWritten: 150)
        // b:一行有账、一行 NULL(缺账分钟)
        try insertSample(base - 540, "b", mem: 0, procs: 1, diskRead: 500, diskWritten: 0)
        try insertSample(base - 60, "b", mem: 0, procs: 1) // disk 列 NULL
        try insertSample(base - 540, "c", mem: 0, procs: 1) // 全 NULL → 总量 0 也如实列

        let top = try queue.read { db in
            try InsightQuery.topDiskGroups(limit: 5, lookbackMinutes: 10, now: now, in: db)
        }
        // b 总量 500 > a 总量 600?500 < 600——a 应第一;b 第二(缺账如实标)。
        XCTAssertEqual(top.map(\.groupID), ["a", "b", "c"])
        XCTAssertEqual(top[0].readBytes, 400)
        XCTAssertEqual(top[0].writtenBytes, 200)
        XCTAssertFalse(top[0].hasNullMinutes)
        XCTAssertTrue(top[1].hasNullMinutes, "b 有一行缺磁盘账")
        XCTAssertEqual(top[1].readBytes, 500)
        XCTAssertTrue(top[2].hasNullMinutes, "全 NULL = 每分钟都缺账,同样如实标")
    }

    // MARK: 进程档案(mcp-eyes/01)

    func testLineageMatchesByPidAndSubstringWithEscaping() throws {
        try insertLineage(
            100,
            parent: 1,
            executable: "/usr/local/bin/node",
            cwd: "/dev/web",
            argv: "node vite dev --port 5173",
            firstSeen: Double(base - 3600)
        )
        try insertLineage(
            200,
            parent: 100,
            executable: "/usr/bin/tail",
            cwd: "/tmp",
            argv: "tail -f build.log",
            firstSeen: Double(base - 60)
        )

        let byPID = try queue.read { db in
            try InsightQuery.lineageMatches(pid: 200, in: db)
        }
        XCTAssertEqual(byPID.map(\.pid), [200])
        XCTAssertEqual(byPID.first?.parentPID, 100)
        XCTAssertEqual(byPID.first?.argv, "tail -f build.log")

        let bySubstring = try queue.read { db in
            try InsightQuery.lineageMatches(substring: "vite dev", in: db)
        }
        XCTAssertEqual(bySubstring.map(\.pid), [100], "子串命中 argv")

        let byPath = try queue.read { db in
            try InsightQuery.lineageMatches(substring: "/dev/web", in: db)
        }
        XCTAssertEqual(byPath.map(\.pid), [100], "子串命中 cwd")

        // LIKE 元字符当字面量:% 不再是通配。
        let literalPercent = try queue.read { db in
            try InsightQuery.lineageMatches(substring: "node%dev", in: db)
        }
        XCTAssertTrue(literalPercent.isEmpty, "% 不作通配")

        let nothing = try queue.read { db in
            try InsightQuery.lineageMatches(substring: "no-such-thing", in: db)
        }
        XCTAssertTrue(nothing.isEmpty)
    }

    // MARK: 告警历史(mcp-eyes/02)

    func testAlertEventStoreRecordsAndQueryAggregates() async throws {
        let store = AlertEventStore(database: queue)
        try await store.record(
            AlertOccurrence(
                kind: .systemLoad, subjectKey: "system", value: 80,
                firedAt: Date(timeIntervalSince1970: Double(base))
            ),
            offender: .none
        )
        try await store.record(
            AlertOccurrence(
                kind: .systemLoad, subjectKey: "system", value: 85,
                firedAt: Date(timeIntervalSince1970: Double(base + 120))
            ),
            offender: AlertOffenderSummary(
                groupName: "octok",
                entries: [AlertOffenderEntry(name: "electron", cpuPercent: 320, memoryBytes: 1000)]
            )
        )
        try await store.record(
            AlertOccurrence(
                kind: .groupCPU, subjectKey: "g|xcode", subjectName: "Xcode", value: 320,
                firedAt: Date(timeIntervalSince1970: Double(base + 60))
            ),
            offender: .none
        )

        let endSeconds = base + 180
        let rows = try await queue.read { db in
            try McpEyesQuery.recentAlerts(
                hours: 24, now: Date(timeIntervalSince1970: Double(endSeconds)), in: db
            )
        }
        XCTAssertEqual(rows.count, 2, "同主体聚合成一行")
        XCTAssertEqual(rows.first?.kind, AlertKind.systemLoad.rawValue, "按最近触发降序")
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(rows.first?.latestValue, 85)
        let groupRow = rows.first { $0.kind == AlertKind.groupCPU.rawValue }
        XCTAssertEqual(groupRow?.subjectName, "Xcode")
        XCTAssertEqual(groupRow?.count, 1)

        // 归因随最近一次触发落库(alert-offender-outlets):第二次 systemLoad 带
        // 归因(聚合取最新一行),老行/无归因行读出 nil/空表不炸。
        XCTAssertEqual(rows.first?.offenderGroup, "octok")
        XCTAssertEqual(rows.first?.offenderEntries.map(\.name), ["electron"])
        XCTAssertNil(groupRow?.offenderGroup)
        XCTAssertEqual(groupRow?.offenderEntries, [])

        // 输出文案点名「当时是谁干的」。
        let text = McpEyesText.alertHistory(rows, now: Date(timeIntervalSince1970: Double(endSeconds)))
        XCTAssertTrue(text.contains("归因:octok:electron 320%"), "输出行带归因,实际:\n\(text)")
    }

    // MARK: dev server 状态(mcp-eyes/02)

    private func server(
        pid: Int32,
        memory: UInt64 = 100,
        idle: TimeInterval? = nil,
        ports: [UInt16] = [5173]
    ) -> DevServerStatus {
        DevServerStatus(
            pid: pid,
            kind: .vite,
            displayName: "web(5173)",
            memoryBytes: memory,
            idleSeconds: idle,
            listeningPorts: ports
        )
    }

    func testDevServerStateStoreUpsertsThrottlesAndPrunes() async throws {
        let store = DevServerStateStore(database: queue)
        let t0 = Date(timeIntervalSince1970: Double(base))

        // 首写:落行,first_seen = last_seen。
        try await store.upsert([server(pid: 11)], now: t0)
        var rows = try await queue.read { db in try McpEyesQuery.devServers(in: db) }
        XCTAssertEqual(rows.map(\.pid), [11])
        XCTAssertEqual(rows.first?.firstSeenSeconds, base)
        XCTAssertEqual(rows.first?.ports, [5173])

        // 同分钟同 pid 集:跳过(内存变化不重写——分钟粒度)。
        try await store.upsert([server(pid: 11, memory: 999, ports: [3000])], now: t0.addingTimeInterval(30))
        rows = try await queue.read { db in try McpEyesQuery.devServers(in: db) }
        XCTAssertEqual(rows.first?.memoryBytes, 100, "同分钟节流,未重写")
        XCTAssertEqual(rows.first?.ports, [5173])

        // 新分钟:upsert 生效(first_seen 保留),顺手带上第二个 server。
        try await store.upsert(
            [server(pid: 11, memory: 999, ports: [3000]), server(pid: 22, memory: 500, idle: 900, ports: [8000])],
            now: t0.addingTimeInterval(90)
        )
        rows = try await queue.read { db in try McpEyesQuery.devServers(in: db) }
        XCTAssertEqual(Set(rows.map(\.pid)), [11, 22])
        XCTAssertEqual(rows.first { $0.pid == 11 }?.firstSeenSeconds, base, "first_seen 不被 upsert 抹掉")
        XCTAssertEqual(rows.first { $0.pid == 11 }?.memoryBytes, 999)
        XCTAssertEqual(rows.first { $0.pid == 22 }?.idleSeconds, 900)

        // 清尸:两个 server 都消失,11 分钟后全删。
        try await store.upsert([], now: t0.addingTimeInterval(90 + 700))
        rows = try await queue.read { db in try McpEyesQuery.devServers(in: db) }
        XCTAssertTrue(rows.isEmpty, "最后见到超 10 分钟的行清掉")
    }

    // MARK: 文案(mcp-eyes/01+02)

    func testEyesTextCoversKeyLines() {
        let memoryRow = InsightQuery.GroupMemoryInsight(
            groupID: "b", name: "浏览器", category: "app", projectRoot: nil,
            memoryAverageBytes: 2_000_000_000, memoryPeakBytes: 3_000_000_000, processCount: 5
        )
        let memoryText = McpEyesText.memoryRanking(
            [memoryRow],
            systemMemory: .init(value: 12_000_000_000, atSeconds: base),
            lookbackMinutes: 10,
            now: now
        )
        XCTAssertTrue(memoryText.contains("12.0 GB"))
        XCTAssertTrue(memoryText.contains("浏览器"))
        XCTAssertTrue(memoryText.contains("3.0 GB"), "峰值(GB 档带一位小数):\(memoryText)")

        let diskText = McpEyesText.diskRanking([], lookbackMinutes: 30, now: now)
        XCTAssertTrue(diskText.contains("没有磁盘账"))

        let profile = InsightQuery.ProcessProfile(
            pid: 100, parentPID: 1, executablePath: "/usr/local/bin/node",
            cwd: "/dev/web", argv: "node vite dev", firstSeenSeconds: base - 3600
        )
        let profileText = McpEyesText.processProfiles([profile], alive: [100: true], now: now)
        XCTAssertTrue(profileText.contains("(存活)"))
        XCTAssertTrue(profileText.contains("/usr/local/bin/node"))
        XCTAssertTrue(profileText.contains("工作目录:/dev/web"))

        let alertText = McpEyesText.alertHistory([], now: now)
        XCTAssertTrue(alertText.contains("没有告警记录"))

        let devText = McpEyesText.devServers([
            DevServerStateRow(
                pid: 11, kind: "vite", name: "web(5173)", memoryBytes: 500_000_000,
                idleSeconds: 1200, ports: [5173], firstSeenSeconds: base - 7200, lastSeenSeconds: base - 1200
            ),
        ], now: now)
        XCTAssertTrue(devText.contains("已闲置"))
        XCTAssertTrue(devText.contains("5173"))
        XCTAssertTrue(devText.contains("可能已退出"), "最后见到超 10 分钟如实说")
    }
}
