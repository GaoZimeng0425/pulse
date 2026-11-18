import GRDB
@testable import PulseCore
import XCTest

// MARK: - Claude 增量检查点扫描测试(agent-tab/12)

//
// 引擎语义:多轮演化(追加/原地改写/删除/resume 复制/mtime 快路径)后,
// 账本 == 全量重解析;未触碰文件零重读;改写检出换贡献不残留;账本行不受
// 源存亡影响(文件删除后该天旧行保留)。真实文件 IO 的等价性在 PulseTests
// (AgentIncrementalLiveTests),这里用假 reader 盯引擎本身。

/// 假 reader:内存文件(key → 行内容);哈希直接用前缀原文(引擎只比 Data
/// 相等,不关心摘要算法);只喂完整行(与 Live 语义一致)。
private final class FakeIncrementalReader: AgentUsageReading, @unchecked Sendable {
    var zcode: [ZCodeUsageSample] = []
    var legacySchema = false
    /// key → 内容(建议行以 \n 结尾;无换行尾巴不消费,与 Live 同语义)。
    var claudeFiles: [String: String] = [:]
    /// key → mtime(引擎快路径要它稳定;缺省用固定值,测试显式改)。
    var mtimes: [String: Date] = [:]
    var statsCache: Data?
    private(set) var incrementalReadCount = 0

    func zcodeUsageSamples(sinceStartedAtMs: Int64?) -> (
        samples: [ZCodeUsageSample], legacySchema: Bool
    ) {
        let filtered: [ZCodeUsageSample] = if let since = sinceStartedAtMs {
            zcode.filter { ($0.startedAtMs ?? 0) >= since }
        } else {
            zcode
        }
        return (filtered, legacySchema)
    }

    func claudeFileInventory() -> [ClaudeFileRef] {
        claudeFiles
            .map { key, content in
                ClaudeFileRef(
                    key: key,
                    modifiedAt: mtimes[key] ?? Date(timeIntervalSince1970: 1_000_000),
                    sizeBytes: UInt64(content.utf8.count)
                )
            }
            .sorted { $0.key < $1.key }
    }

    func readClaudeFileIncremental(
        _ file: ClaudeFileRef,
        checkpoint: (offset: UInt64, prefixSha256: Data)?,
        consume: (_ line: String) -> Void
    ) -> ClaudeFileReadOutcome {
        incrementalReadCount += 1
        guard let content = claudeFiles[file.key] else { return .unchanged }
        let data = Data(content.utf8)
        if let checkpoint {
            let offset = Int(checkpoint.offset)
            guard data.count >= offset, Data(data.prefix(offset)) == checkpoint.prefixSha256 else { return .rewritten }
            if data.count == offset {
                return .unchanged
            }
        }
        var consumed = checkpoint?.offset ?? 0
        var tail = data.suffix(from: Int(consumed))
        while let newline = tail.firstIndex(of: 0x0A) {
            let lineData = tail[tail.startIndex ..< newline]
            if !lineData.isEmpty, let line = String(data: Data(lineData), encoding: .utf8) {
                consume(line)
            }
            consumed += UInt64(lineData.count) + 1
            tail.removeSubrange(tail.startIndex ... newline)
        }
        return .advanced(consumedOffset: consumed, prefixSha256: Data(data.prefix(Int(consumed))))
    }

    func claudeStatsCacheData() -> Data? {
        statsCache
    }
}

/// assistant 行夹具(usage 形状 = projects jsonl 实测;五桶可注入)。
private func line(
    id: String,
    timestamp: String,
    input: Int = 100,
    cacheRead: Int = 50,
    cacheWrite: Int = 10,
    output: Int = 200,
    cwd: String? = nil,
    model: String? = nil
) -> String {
    let messageId = "\"id\":\"\(id)\","
    let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
    let modelField = model.map { "\"model\":\"\($0)\"," } ?? ""
    return """
    {"type":"assistant","timestamp":"\(timestamp)",\(cwdField)"message":{\(messageId)\(modelField)"role":"assistant","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite),"output_tokens":\(output)}}}
    """
}

/// UTC ISO 串(与真实 jsonl 同形)。
private func isoUtc(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

final class AgentIncrementalModelTests: XCTestCase {
    private var reader: FakeIncrementalReader!
    private var store: AgentUsageStore!
    private var checkpoints: AgentCheckpointStore!
    private var scan: AgentUsageScan!

    override func setUpWithError() throws {
        let database = try HistoryDatabase.openInMemory()
        store = AgentUsageStore(database: database)
        checkpoints = AgentCheckpointStore(database: database)
        reader = FakeIncrementalReader()
        scan = AgentUsageScan()
    }

    private var baseTime: Date {
        // 相对时钟:正午锚,任何合理时区偏移下加减小时仍在同一天。
        Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
            .addingTimeInterval(12 * 3600)
    }

    // MARK: 首轮与 Σ

    /// 首轮全量:三轨落账(合计/项目/模型),数值 = 全部文件贡献之和。
    func testFreshScanProducesLedger() throws {
        let day1 = baseTime
        let day2 = baseTime.addingTimeInterval(-86400)
        reader.claudeFiles = [
            "proj-a/s1.jsonl": [
                line(id: "m1", timestamp: isoUtc(day1), cwd: "/Users/x/alpha", model: "opus"),
                line(id: "m2", timestamp: isoUtc(day2), cwd: "/Users/x/alpha", model: "opus"),
            ].joined(separator: "\n") + "\n",
            "proj-b/s2.jsonl":
                line(id: "m3", timestamp: isoUtc(day2), cwd: "/Users/x/beta", model: "sonnet") + "\n",
        ]

        let rows = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))

        // 每行 usage 总量 = 100+50+10+200 = 360。
        let day1Row = rows.first { $0.source == .claude && $0.day == dayKey(day1) }
        XCTAssertEqual(day1Row?.totalTokens, 360)
        XCTAssertEqual(day1Row?.requestCount, 1)

        let day2Row = rows.first { $0.source == .claude && $0.day == dayKey(day2) }
        XCTAssertEqual(day2Row?.totalTokens, 720)
        XCTAssertEqual(day2Row?.requestCount, 2)

        let projects = try store.projectRows().filter { $0.source == .claude }
        XCTAssertEqual(projects.first { $0.project == "alpha" }?.day, dayKey(day2))
        XCTAssertEqual(projects.filter { $0.day == dayKey(day2) }.count, 2)

        let models = try store.modelRows().filter { $0.source == .claude }
        XCTAssertEqual(models.count, 3) // (alpha, opus) × 2 天 + (beta, sonnet) × 1 天
    }

    // MARK: 追加 + 不缩水回归

    /// round2 只追加一个文件:未触碰文件零重读(mtime 快路径),昨日合计 =
    /// 缓存贡献 + 新增量——agent-tab/02「闭环会话被抹掉」实案的新语义回归。
    func testAppendGrowsAndClosedSessionsNeverShrink() throws {
        let yesterday = baseTime
        reader.claudeFiles = [
            "proj-a/closed.jsonl": line(id: "m1", timestamp: isoUtc(yesterday), input: 1000) + "\n",
            "proj-a/alive.jsonl": line(id: "m2", timestamp: isoUtc(yesterday), input: 2000) + "\n",
        ]
        let first = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        XCTAssertEqual(first.first { $0.source == .claude }?.totalTokens, 3520) // 1260 + 2260(按行五桶)
        let readsAfterFirst = reader.incrementalReadCount

        // round2:只动 alive(mtime 前拨触发重读),追加新 id 的一行。
        reader.claudeFiles["proj-a/alive.jsonl"]?.append(
            line(id: "m3", timestamp: isoUtc(yesterday), input: 500) + "\n"
        )
        reader.mtimes["proj-a/alive.jsonl"] = Date(timeIntervalSince1970: 2_000_000)

        let second = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .today
        ))
        // closed 零重读:只读了 alive 一个文件。
        XCTAssertEqual(reader.incrementalReadCount - readsAfterFirst, 1)
        // 昨日 = 3520(旧行两条)+ 新行 760,不缩水。
        let row = second.first { $0.source == .claude }
        XCTAssertEqual(row?.totalTokens, 3520 + 760)
        XCTAssertEqual(row?.requestCount, 3)
    }

    // MARK: 无换行尾巴

    /// 尾行无换行:本轮不消费(无检查点失配),补上换行后下轮计一次。
    func testTailWithoutNewlineDeferred() throws {
        let when = baseTime
        let path = "proj-a/s.jsonl"
        reader.claudeFiles = [
            path: line(id: "m1", timestamp: isoUtc(when), input: 10) + "\n"
                + line(id: "m2", timestamp: isoUtc(when), input: 20), // 无换行
        ]
        reader.mtimes[path] = Date(timeIntervalSince1970: 1_000_000)

        let first = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        // 只计完整行 m1(270 = 10+50+10+200)。
        XCTAssertEqual(first.first { $0.source == .claude }?.requestCount, 1)

        reader.claudeFiles[path]?.append("\n")
        reader.mtimes[path] = Date(timeIntervalSince1970: 3_000_000)
        let second = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        XCTAssertEqual(second.first { $0.source == .claude }?.requestCount, 2)
    }

    // MARK: 原地改写

    /// compact 改写:前缀哈希失配 → 清该文件 seen → 全量重读,贡献**替换**
    /// 不残留;幸存 id 重计、消失 id 不再计。
    func testRewriteReplacesContribution() throws {
        let when = baseTime
        let path = "proj-a/s.jsonl"
        reader.claudeFiles = [
            path: [
                line(id: "keep", timestamp: isoUtc(when), input: 100),
                line(id: "drop", timestamp: isoUtc(when), input: 9999),
            ].joined(separator: "\n") + "\n",
        ]
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))

        // 改写:只剩 keep(id 复用——幸存轮次不得被旧 seen 误判重复)。
        reader.claudeFiles[path] = line(id: "keep", timestamp: isoUtc(when), input: 100) + "\n"
        reader.mtimes[path] = Date(timeIntervalSince1970: 9_000_000)

        let second = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let row = second.first { $0.source == .claude }
        XCTAssertEqual(row?.requestCount, 1)
        XCTAssertEqual(row?.inputTokens, 100)

        // 检查点库里 seen 只剩 keep(改写清旧)。
        let seen = try checkpoints.loadSeenMessageIDs()
        XCTAssertEqual(seen, ["keep"])
    }

    // MARK: 文件删除

    /// 文件删除:检查点清、贡献移出 Σ;**账本旧行保留**(agent-tab/02 立身
    /// 之本——落库行不受源存亡影响)。
    func testDeletedFileKeepsLedgerRows() throws {
        let dayA = baseTime
        let dayB = baseTime.addingTimeInterval(-86400)
        reader.claudeFiles = [
            "proj-a/shared.jsonl": line(id: "m1", timestamp: isoUtc(dayA), input: 100) + "\n",
            "proj-a/only-b.jsonl": line(id: "m2", timestamp: isoUtc(dayB), input: 200) + "\n",
        ]
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))

        reader.claudeFiles["proj-a/only-b.jsonl"] = nil
        let second = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        // dayA 照常;dayB 行保留(旧值不归零)。
        XCTAssertEqual(second.first { $0.source == .claude && $0.day == dayKey(dayA) }?.requestCount, 1)
        XCTAssertEqual(second.first { $0.source == .claude && $0.day == dayKey(dayB) }?.requestCount, 1)
        // 检查点与 seen 已清。
        XCTAssertTrue(try checkpoints.loadCheckpoints()["proj-a/only-b.jsonl"] == nil)
        XCTAssertFalse(try checkpoints.loadSeenMessageIDs().contains("m2"))
    }

    // MARK: resume 复制

    /// resume 把历史复制进新文件:同 id 不双计,新文件只贡献自己的新轮次。
    func testResumeCopyDoesNotDoubleCount() throws {
        let when = baseTime
        let original = "proj-a/s1.jsonl"
        reader.claudeFiles = [
            original: line(id: "m1", timestamp: isoUtc(when), input: 100) + "\n",
        ]
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))

        // 新文件 = 原文件内容拷贝(m1 同 id)+ 一条新行。
        reader.claudeFiles["proj-a/s2.jsonl"] = [
            line(id: "m1", timestamp: isoUtc(when), input: 100),
            line(id: "m2", timestamp: isoUtc(when), input: 300),
        ].joined(separator: "\n") + "\n"

        let second = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let row = second.first { $0.source == .claude }
        XCTAssertEqual(row?.requestCount, 2) // m1 只计一次 + m2
        XCTAssertEqual(row?.inputTokens, 400)
    }

    // MARK: mtime 快路径

    /// 未触碰文件(mtime 与 size 同检查点):零重读——库存 stat 后直接用缓存。
    func testUntouchedFilesAreNotRead() throws {
        reader.claudeFiles = [
            "proj-a/s1.jsonl": line(id: "m1", timestamp: isoUtc(baseTime)) + "\n",
            "proj-b/s2.jsonl": line(id: "m2", timestamp: isoUtc(baseTime)) + "\n",
        ]
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let reads = reader.incrementalReadCount
        XCTAssertEqual(reads, 2)

        // 什么都不动:零打开。
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .today
        ))
        XCTAssertEqual(reader.incrementalReadCount, reads)
    }

    // MARK: stats-cache 回填 + ZCode 合入

    /// 全量档:cache 只填「无细粒度数据且非今天」的天;ZCode 增量合入同一账本。
    func testFullScopeBackfillsCacheAndMergesZCode() throws {
        let now = Date()
        let today = dayKey(now)
        reader.claudeFiles = [
            "proj-a/s1.jsonl": line(id: "m1", timestamp: isoUtc(now)) + "\n",
        ]
        reader.statsCache = """
        {"dailyModelTokens":[
          {"date":"2026-08-01","tokensByModel":{"m":500}},
          {"date":"\(today)","tokensByModel":{"m":999}}
        ]}
        """.data(using: .utf8)
        let zcodeToday = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000) + 1000
        reader.zcode = [
            ZCodeUsageSample(
                id: "z1", startedAtMs: zcodeToday,
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150
            ),
        ]

        let rows = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: now, scope: .full
        ))
        // cache 只填缺天:08-01 有,今天不回填(999 不出现)。
        XCTAssertEqual(rows.first { $0.origin == .cache }?.day, "2026-08-01")
        XCTAssertFalse(rows.contains { $0.origin == .cache && $0.day == today })
        // ZCode 今日行与 Claude 今日行同天并存。
        XCTAssertEqual(rows.filter { $0.day == today }.count, 2)
        XCTAssertEqual(rows.first { $0.source == .zcode }?.totalTokens, 150)
    }

    /// 定时档:ZCode 只拉今天(昨天样本不下账),Claude 侧与全量档等价。
    func testTodayScopePullsZCodeSinceMidnight() throws {
        let now = Date()
        let startTodayMs = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
        reader.zcode = [
            ZCodeUsageSample(
                id: "old", startedAtMs: startTodayMs - 1000,
                inputTokens: 10, outputTokens: 5, computedTotalTokens: 15
            ),
            ZCodeUsageSample(
                id: "new", startedAtMs: startTodayMs + 1000,
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150
            ),
        ]
        let rows = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: now, scope: .today
        ))
        XCTAssertEqual(rows.filter { $0.source == .zcode }.count, 1)
        XCTAssertEqual(rows.first { $0.source == .zcode }?.totalTokens, 150)
    }

    // MARK: 接线(三轨落库)

    /// 扫描产出项目轨行:claude(slug 归组)与 zcode(worktree 折主仓)同归 pulse。
    func testScanWritesProjectRowsBothSources() throws {
        reader.zcode = [
            ZCodeUsageSample(
                id: "u1", startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150,
                workspacePath: "/Users/x/pulse/.worktrees/agent-project"
            ),
        ]
        reader.claudeFiles = [
            "-Users-x-pulse/s1.jsonl": line(id: "m1", timestamp: isoUtc(Date())) + "\n",
        ]
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let projects = try store.projectRows()
        XCTAssertEqual(projects.count, 2)
        XCTAssertTrue(projects.allSatisfy { $0.project == "pulse" })
    }

    /// 扫描产出模型轨行(zcode model_id 路径)。
    func testScanWritesModelRows() throws {
        reader.zcode = [
            ZCodeUsageSample(
                id: "u1", startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                inputTokens: 100, outputTokens: 50, computedTotalTokens: 150,
                workspacePath: "/Users/x/pulse/.worktrees/agent-project",
                modelId: "GLM-5.3"
            ),
        ]
        _ = try XCTUnwrap(scan.scan(
            reader: reader, checkpoints: checkpoints, ledger: store, now: Date(), scope: .full
        ))
        let models = try store.modelRows()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "GLM-5.3")
        XCTAssertEqual(models.first?.project, "pulse")
    }
}

/// 本地日键(与账本落库同口径)。
private func dayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}
