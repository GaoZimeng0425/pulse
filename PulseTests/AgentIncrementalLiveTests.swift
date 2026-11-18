@testable import Pulse
import PulseCore
import XCTest

// MARK: - Claude 增量检查点端到端等价(agent-tab/12)

//
// 真实文件 IO(LiveAgentUsageReader + 临时 home):多轮演化(追加/原地改写/
// 删除/resume 复制)后的账本 == 「同样终态从零全量扫」的账本(等价性金标)。
// 引擎语义(去重/替换/冻结行)的逐项断言在 PulseCoreTests/
// AgentIncrementalModelTests,这里只盯真实字节路径的等价性。

final class AgentIncrementalLiveTests: XCTestCase {
    private var home: URL!
    /// 「金标」home:每轮演化后镜像终态,最终从零全量扫作对照。
    private var mirror: URL!

    override func setUpWithError() throws {
        let homeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-incremental-\(UUID().uuidString)")
        let mirrorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-incremental-mirror-\(UUID().uuidString)")
        home = homeRoot
        mirror = mirrorRoot
        for root in [homeRoot, mirrorRoot] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".claude/projects/proj-a"),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: mirror)
    }

    private func write(_ text: String, relativePath: String) throws {
        let url = home.appendingPathComponent(".claude/projects").appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        mirrorCurrentState()
    }

    private func append(_ text: String, relativePath: String) throws {
        let url = home.appendingPathComponent(".claude/projects").appendingPathComponent(relativePath)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        mirrorCurrentState()
    }

    private func remove(relativePath: String) throws {
        try FileManager.default.removeItem(
            at: home.appendingPathComponent(".claude/projects").appendingPathComponent(relativePath)
        )
        let mirrored = mirror.appendingPathComponent(".claude/projects").appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: mirrored.path) {
            try FileManager.default.removeItem(at: mirrored)
        }
    }

    /// 镜像当前 projects 终态(整目录拷贝语义:逐文件重写)。
    private func mirrorCurrentState() {
        let source = home.appendingPathComponent(".claude/projects")
        let target = mirror.appendingPathComponent(".claude/projects")
        let manager = FileManager.default
        if let files = try? manager.subpathsOfDirectory(atPath: source.path) {
            for file in files where file.hasSuffix(".jsonl") {
                try? manager.createDirectory(
                    at: target.appendingPathComponent((file as NSString).deletingLastPathComponent),
                    withIntermediateDirectories: true
                )
                try? manager.removeItem(at: target.appendingPathComponent(file))
                try? manager.copyItem(
                    at: source.appendingPathComponent(file),
                    to: target.appendingPathComponent(file)
                )
            }
        }
    }

    private func line(id: String, minutesAgo: Double, input: Int) -> String {
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/Users/x/alpha","message":{"id":"\(id)","model":"claude-opus-5-5","role":"assistant","usage":{"input_tokens":\(input),"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":200}}}
        """
    }

    /// 多轮演化 == 终态全量(三轨逐行对比)。
    func testEvolvedLedgerEqualsFreshFullScan() throws {
        let database = try HistoryDatabase.openInMemory()
        let checkpoints = AgentCheckpointStore(database: database)
        let store = AgentUsageStore(database: database)
        let reader = LiveAgentUsageReader(home: home)

        // round 1:三个文件,两个 id 跨文件各归各的项目(cwd 驱动)。
        try write(
            line(id: "a1", minutesAgo: 600, input: 100) + "\n"
                + line(id: "a2", minutesAgo: 300, input: 200) + "\n",
            relativePath: "proj-a/s1.jsonl"
        )
        try write(
            line(id: "b1", minutesAgo: 700, input: 300) + "\n",
            relativePath: "proj-a/s2.jsonl"
        )
        try write(
            line(id: "c1", minutesAgo: 800, input: 400) + "\n",
            relativePath: "proj-a/s3.jsonl"
        )
        let scan = AgentUsageScan()
        XCTAssertNotNil(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))

        // round 2:追加(s1 续命);原地改写(s2 换内容,id 有幸存有消失);
        // 删除 s3;resume 复制(s4 拷贝 s1 终态 + 新行)。
        try append(line(id: "a3", minutesAgo: 1, input: 500) + "\n", relativePath: "proj-a/s1.jsonl")
        try write(
            line(id: "b1", minutesAgo: 700, input: 300) + "\n"
                + line(id: "b2", minutesAgo: 2, input: 600) + "\n",
            relativePath: "proj-a/s2.jsonl"
        )
        try remove(relativePath: "proj-a/s3.jsonl")
        try write(
            line(id: "a1", minutesAgo: 600, input: 100) + "\n"
                + line(id: "a2", minutesAgo: 300, input: 200) + "\n"
                + line(id: "a3", minutesAgo: 1, input: 500) + "\n"
                + line(id: "s4new", minutesAgo: 1, input: 700) + "\n",
            relativePath: "proj-a/s4.jsonl"
        )
        let evolved = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))

        // 金标:同样终态、全新库从零全量扫。
        let freshDatabase = try HistoryDatabase.openInMemory()
        let fresh = try XCTUnwrap(AgentUsageScan().scan(
            reader: LiveAgentUsageReader(home: mirror),
            checkpoints: AgentCheckpointStore(database: freshDatabase),
            ledger: AgentUsageStore(database: freshDatabase),
            now: Date(),
            scope: .full
        ))

        // 主轨逐天逐源对比(scannedAt 忽略)。
        let key: (AgentDailyUsageRow) -> String = { "\($0.day)|\($0.source)" }
        let evolvedByDay = Dictionary(uniqueKeysWithValues: evolved.map { (key($0), $0) })
        let freshByDay = Dictionary(uniqueKeysWithValues: fresh.map { (key($0), $0) })
        XCTAssertEqual(Set(evolvedByDay.keys), Set(freshByDay.keys))
        for (day, freshRow) in freshByDay {
            let evolvedRow = try XCTUnwrap(evolvedByDay[day], "evolved missing \(day)")
            XCTAssertEqual(evolvedRow.totalTokens, freshRow.totalTokens, "\(day) total")
            XCTAssertEqual(evolvedRow.requestCount, freshRow.requestCount, "\(day) requests")
            XCTAssertEqual(evolvedRow.cacheReadTokens, freshRow.cacheReadTokens, "\(day) cacheR")
        }

        // 项目轨 / 模型轨同口径对比。
        let evolvedProjects = try store.projectRows().filter { $0.source == .claude }
        let freshProjects = try freshDatabase.read { db in
            try AgentProjectUsageRow.fetchAll(
                db,
                sql: "SELECT * FROM agent_daily_project_usage WHERE source = 'claude'"
            )
        }
        XCTAssertEqual(evolvedProjects.count, freshProjects.count)
        XCTAssertEqual(
            evolvedProjects.map { "\($0.day)|\($0.project)|\($0.totalTokens)" }.sorted(),
            freshProjects.map { "\($0.day)|\($0.project)|\($0.totalTokens)" }.sorted()
        )

        let evolvedModels = try store.modelRows().filter { $0.source == .claude }
        let freshModels = try freshDatabase.read { db in
            try AgentModelUsageRow.fetchAll(db, sql: "SELECT * FROM agent_daily_model_usage WHERE source = 'claude'")
        }
        XCTAssertEqual(evolvedModels.count, freshModels.count)
        XCTAssertEqual(
            evolvedModels.map { "\($0.day)|\($0.project)|\($0.model)|\($0.totalTokens)" }.sorted(),
            freshModels.map { "\($0.day)|\($0.project)|\($0.model)|\($0.totalTokens)" }.sorted()
        )
    }

    /// 文件删除后,该文件独占的天:账本行保留(不归零)——agent-tab/02 立身
    /// 之本在增量模式下不变。
    func testDeletedFileDayRowSurvivesInLedger() throws {
        let database = try HistoryDatabase.openInMemory()
        let checkpoints = AgentCheckpointStore(database: database)
        let store = AgentUsageStore(database: database)
        let reader = LiveAgentUsageReader(home: home)
        let scan = AgentUsageScan()

        // 两天各一个文件;day-2 只有 s2 贡献。
        try write(
            line(id: "d1", minutesAgo: 60, input: 100) + "\n",
            relativePath: "proj-a/s1.jsonl"
        )
        let oldLine = """
        {"type":"assistant","timestamp":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-48 * 3600)))","cwd":"/Users/x/alpha","message":{"id":"d2","usage":{"input_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
        """
        try write(oldLine + "\n", relativePath: "proj-a/s2.jsonl")
        let first = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let twoDaysAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        let oldDayKey = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: twoDaysAgo)
        }()
        let oldRowBefore = first.first { $0.day == oldDayKey }
        XCTAssertEqual(oldRowBefore?.inputTokens, 200)

        // 删 s2 后再扫:该天账本行原样保留(Σ 无该天 → 不写不删)。
        try remove(relativePath: "proj-a/s2.jsonl")
        let second = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let oldRowAfter = second.first { $0.day == oldDayKey }
        XCTAssertEqual(oldRowAfter?.inputTokens, 200)
        XCTAssertEqual(oldRowAfter?.requestCount, 1)
    }
}
