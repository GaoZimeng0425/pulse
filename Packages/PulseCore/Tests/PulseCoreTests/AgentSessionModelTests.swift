@testable import PulseCore
import XCTest

/// 智能体 tab 内核(agent-tab/01):注册表 / jsonl 尾读 / 用量快照 / ZCode metadata
/// 的解析与编排。夹具全合成(字段形状取自 2026-11-12 本机实测),不读真实
/// ~/.claude、~/.zcode。
final class AgentSessionModelTests: XCTestCase {
    // MARK: - 注册表解析

    func testRegistryParseReadsFullRecord() {
        let json = #"{"pid":65825,"sessionId":"b175530f","cwd":"/Users/aa00930/Documents/Antalpha/octok-client","startedAt":1794418316661,"version":"2.1.322","name":"octok-client-0e","status":"busy"}"#
        let entry = ClaudeSessionRegistry.parse(Data(json.utf8))
        XCTAssertEqual(entry?.pid, 65825)
        XCTAssertEqual(entry?.sessionId, "b175530f")
        XCTAssertEqual(entry?.cwd, "/Users/aa00930/Documents/Antalpha/octok-client")
        XCTAssertEqual(entry?.startedAt, Date(timeIntervalSince1970: 1_794_418_316.661))
        XCTAssertEqual(entry?.name, "octok-client-0e")
        XCTAssertEqual(entry?.status, "busy")
    }

    func testRegistryParseRejectsMalformed() {
        XCTAssertNil(ClaudeSessionRegistry.parse(Data("not json".utf8)))
        XCTAssertNil(ClaudeSessionRegistry.parse(Data(#"{"pid":1}"#.utf8)))
    }

    // MARK: - jsonl 尾读

    private func assistantLine(
        model: String = "claude-opus-5-5",
        input: Int,
        cacheRead: Int,
        cacheCreation: Int,
        output: Int = 200,
        timestamp: String = "2026-11-12T08:15:08.276Z"
    ) -> String {
        let usage = #"{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation),"output_tokens":\#(output)}"#
        return #"{"type":"assistant","message":{"model":"\#(model)","usage":\#(usage)},"timestamp":"\#(timestamp)"}"#
    }

    func testTranscriptTailSumsInputAndCacheRead() {
        let text = """
        {"type":"user","message":{"content":"hi"}}
        \(assistantLine(input: 2, cacheRead: 479_870, cacheCreation: 425))
        {"type":"last-prompt","prompt":"下一步"}
        """
        let reading = ClaudeTranscriptTail.parse(Data(text.utf8))
        XCTAssertEqual(reading?.context?.model, "claude-opus-5-5")
        XCTAssertEqual(reading?.context?.contextTokens, 479_872)
        XCTAssertEqual(reading?.context?.timestamp, AgentISO8601.parse("2026-11-12T08:15:08.276Z"))
    }

    func testTranscriptTailFirstCacheBuildCountsCreationOnly() {
        // 会话首建缓存:cache_read 为 0 且 cache_creation > 0 → input + creation。
        let text = assistantLine(input: 100, cacheRead: 0, cacheCreation: 5000)
        XCTAssertEqual(ClaudeTranscriptTail.parse(Data(text.utf8))?.context?.contextTokens, 5100)
    }

    func testTranscriptTailTakesLastAssistantAndDropsHalfLine() {
        let halfLine = ##"put_tokens":1}},"timestamp":"2026-11-11T00:00:00.000Z"}"##
        let text = """
        \(halfLine)
        \(assistantLine(input: 10, cacheRead: 20000, cacheCreation: 0))
        {"type":"attachment","message":{}}
        \(assistantLine(input: 5, cacheRead: 30000, cacheCreation: 0))
        """
        XCTAssertEqual(ClaudeTranscriptTail.parse(Data(text.utf8))?.context?.contextTokens, 30005)
    }

    func testTranscriptTailWithoutUsageReturnsNil() {
        XCTAssertNil(ClaudeTranscriptTail.parse(Data(#"{"type":"assistant","message":{"model":"m"}}"#.utf8)))
        XCTAssertNil(ClaudeTranscriptTail.parse(Data()))
    }

    // MARK: - 当前任务摘要(agent-tab/03)

    /// 末条有效用户指令:tool_result 回传 / sidechain 子链 / 注入噪音("<"、
    /// resume 摘要)全跳过,取最后一条真实指令;与上下文读数同窗产出。
    func testTailPicksLastValidUserPrompt() {
        let text = """
        {"type":"user","message":{"content":"修弹窗布局循环"}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
        {"type":"user","isSidechain":true,"message":{"content":"子代理的指令"}}
        {"type":"user","message":{"content":"<command-name>/clear</command-name>"}}
        {"type":"user","message":{"content":"This session is being continued from a previous conversation"}}
        {"type":"user","message":{"content":[{"type":"text","text":"给每日消耗卡"},{"type":"text","text":"加热力图"}]}}
        \(assistantLine(input: 2, cacheRead: 1000, cacheCreation: 0))
        """
        let reading = ClaudeTranscriptTail.parse(Data(text.utf8))
        XCTAssertEqual(reading?.lastUserPrompt, "给每日消耗卡 加热力图")
        XCTAssertEqual(reading?.context?.contextTokens, 1002)
    }

    /// 只有指令没有 assistant usage:prompt 单独成立(新会话首条发出前)。
    func testTailPromptAloneWithoutAssistant() {
        let text = #"{"type":"user","message":{"content":"刚起的第一句话"}}"#
        let reading = ClaudeTranscriptTail.parse(Data(text.utf8))
        XCTAssertNil(reading?.context)
        XCTAssertEqual(reading?.lastUserPrompt, "刚起的第一句话")
    }

    /// 指令截断:换行折空格、封顶 120 字符;全噪音 → prompt 为 nil 但 context 照常。
    func testTailPromptTruncatesAndRejectsAllNoise() {
        let long = String(repeating: "字", count: 200)
        let truncated = ClaudeTranscriptTail.parse(
            Data(#"{"type":"user","message":{"content":"\#(long)"}"#.utf8 + Data("}".utf8))
        )?.lastUserPrompt
        XCTAssertEqual(truncated?.count, 120)

        let noiseOnly = """
        {"type":"user","message":{"content":"<system-reminder>x</system-reminder>"}}
        \(assistantLine(input: 1, cacheRead: 10, cacheCreation: 0))
        """
        let reading = ClaudeTranscriptTail.parse(Data(noiseOnly.utf8))
        XCTAssertNil(reading?.lastUserPrompt)
        XCTAssertEqual(reading?.context?.contextTokens, 11)
    }

    // MARK: - 上下文窗口二档

    func testContextWindowTwoTiers() {
        XCTAssertEqual(ClaudeContextWindow.limit(model: nil, contextTokens: 100_000), 200_000)
        XCTAssertEqual(ClaudeContextWindow.limit(model: "claude-opus-5-5", contextTokens: 480_499), 1_000_000)
        XCTAssertEqual(ClaudeContextWindow.limit(model: "model[1m]", contextTokens: 1000), 1_000_000)
    }

    func testStatusLabelMapsKnownAndPassesUnknown() {
        func label(_ status: String?) -> String? {
            ClaudeAgentSessionStatus(
                pid: 1, sessionId: "s", projectName: "p", cwd: "/p", status: status,
                ageSeconds: nil, model: nil, contextTokens: nil, contextLimit: nil, subagentCount: 0
            ).statusLabel
        }
        XCTAssertEqual(label("busy"), "忙")
        XCTAssertEqual(label("IDLE"), "空闲")
        XCTAssertEqual(label("waiting"), "等待")
        XCTAssertEqual(label("shell"), "Shell")
        XCTAssertEqual(label("brand-new-state"), "brand-new-state")
        XCTAssertNil(label(nil))
    }

    // MARK: - 用量限额快照

    func testUsageSnapshotParsesBothWindows() {
        let json = #"{"updated_at":"2026-11-12T08:26:32.020Z","five_hour":{"used_percentage":17,"resets_at":"2026-11-12T12:00:00.000Z"},"seven_day":{"used_percentage":54,"resets_at":"2026-11-14T17:00:00.000Z"}}"#
        let snapshot = ClaudeUsageSnapshot.parse(Data(json.utf8))
        XCTAssertEqual(snapshot?.fiveHour?.usedPercentage, 17)
        XCTAssertEqual(snapshot?.sevenDay?.usedPercentage, 54)
        XCTAssertEqual(snapshot?.fiveHour?.resetsAt, AgentISO8601.parse("2026-11-12T12:00:00.000Z"))
    }

    func testUsageSnapshotEmptyIsNil() {
        XCTAssertNil(ClaudeUsageSnapshot.parse(Data("{}".utf8)))
        XCTAssertNil(ClaudeUsageSnapshot.parse(Data("junk".utf8)))
    }

    // MARK: - ZCode metadata

    private func zcodeMeta(
        status: String = "completed",
        updatedAt: String = "2026-11-12T07:55:23.231Z",
        workspaceRoot: String = "/Users/aa00930/Documents/Learn/macos/pulse",
        tokens: Int? = 556_100
    ) -> Data {
        let tokensField = tokens.map { "\($0)" } ?? "null"
        return Data(
            #"{"agentId":"agent_x","status":"\#(status)","updatedAt":"\#(updatedAt)","workspaceRoot":"\#(workspaceRoot)","profileId":"Explore","totalTokens":\#(tokensField)}"#
                .utf8
        )
    }

    func testZCodeMetadataParse() {
        let meta = ZCodeAgentMetadata.parse(zcodeMeta())
        XCTAssertEqual(meta?.status, "completed")
        XCTAssertEqual(meta?.workspaceRoot, "/Users/aa00930/Documents/Learn/macos/pulse")
        XCTAssertEqual(meta?.profile, "Explore")
        XCTAssertEqual(meta?.totalTokens, 556_100)
        XCTAssertEqual(meta?.updatedAt, AgentISO8601.parse("2026-11-12T07:55:23.231Z"))
        XCTAssertNil(ZCodeAgentMetadata.parse(Data("junk".utf8)))
    }

    func testZCodeActiveIsNonTerminal() throws {
        // 终态 closed set:completed/failed/cancelled/error;未知状态按活跃计。
        XCTAssertFalse(try XCTUnwrap(ZCodeAgentMetadata.parse(zcodeMeta(status: "completed"))?.isActive))
        XCTAssertFalse(try XCTUnwrap(ZCodeAgentMetadata.parse(zcodeMeta(status: "Failed"))?.isActive))
        XCTAssertTrue(try XCTUnwrap(ZCodeAgentMetadata.parse(zcodeMeta(status: "running"))?.isActive))
        XCTAssertTrue(try XCTUnwrap(ZCodeAgentMetadata.parse(zcodeMeta(status: "whatever-new-state"))?.isActive))
        XCTAssertTrue(try XCTUnwrap(ZCodeAgentMetadata.parse(zcodeMeta(status: "null"))?.isActive))
    }

    // MARK: - 编排器

    /// 假读源:可编程返回值 + IO 调用计数(节流断言点)。
    private final class FakeReader: AgentSessionReading, @unchecked Sendable {
        var registry: [Data] = []
        var usage: Data?
        var tails: [String: Data] = [:]
        var subagents: [String: Int] = [:]
        /// ZCode 清单夹具:路径 → (session, 修改时间, 内容)。`zcode` 便捷写法按序生成路径、
        /// 修改时间统一取 epoch(只关心聚合口径的老用例用它)。
        var zcodeFiles: [(path: String, session: String, modifiedAt: Date, data: Data)] = []
        var zcode: [(session: String, data: Data)] {
            get { zcodeFiles.map { ($0.session, $0.data) } }
            set {
                zcodeFiles = newValue.enumerated().map { index, file in
                    ("\(file.session)/agent_\(index)", file.session, Date(timeIntervalSince1970: 0), file.data)
                }
            }
        }

        private(set) var ioCalls = 0
        /// metadata 内容读次数(增量断言点:清单里时间没变的不得重读)。
        private(set) var zcodeReads: [String] = []
        /// 读失败夹具:这些路径读内容返回 nil(stat 与读之间被替换 / 无权限)。
        var unreadable: Set<String> = []

        func claudeRegistryFiles() -> [Data] {
            ioCalls += 1
            return registry
        }

        func claudeUsageSnapshotFile() -> Data? {
            ioCalls += 1
            return usage
        }

        func claudeTranscriptTail(cwd: String, sessionId: String) -> Data? {
            ioCalls += 1
            return tails["\(cwd)|\(sessionId)"]
        }

        func claudeSubagentCount(cwd: String, sessionId: String) -> Int {
            ioCalls += 1
            return subagents["\(cwd)|\(sessionId)"] ?? 0
        }

        func zcodeAgentMetadataCandidates(lookback: TimeInterval, now: Date) -> [ZCodeMetadataCandidate] {
            ioCalls += 1
            return zcodeFiles
                .map { ZCodeMetadataCandidate(session: $0.session, path: $0.path, modifiedAt: $0.modifiedAt) }
        }

        func zcodeAgentMetadata(atPath path: String) -> Data? {
            ioCalls += 1
            zcodeReads.append(path)
            guard !unreadable.contains(path) else { return nil }
            return zcodeFiles.first { $0.path == path }?.data
        }
    }

    private func makeEntry(_ pid: pid_t, startedAtMs: Double, cwd: String = "/Users/x/pulse") -> Data {
        Data(#"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"\#(cwd)","startedAt":\#(startedAtMs),"status":"busy"}"#
            .utf8)
    }

    func testCatalogBuildsRowsForAliveInstancesNewestFirst() {
        let reader = FakeReader()
        reader.registry = [
            makeEntry(100, startedAtMs: 1_000_000),
            makeEntry(200, startedAtMs: 2_000_000, cwd: "/Users/x/octok"),
        ]
        reader.tails["/Users/x/pulse|s100"] = Data(assistantLine(input: 1, cacheRead: 99999, cacheCreation: 0).utf8)
        reader.subagents["/Users/x/pulse|s100"] = 3
        reader.usage = Data(
            #"{"five_hour":{"used_percentage":17,"resets_at":"2026-11-12T12:00:00.000Z"}}"#.utf8
        )

        let now = Date(timeIntervalSince1970: 3000)
        var catalog = AgentSessionCatalog(refreshInterval: 5)
        let snapshot = catalog.update(reader: reader, alivePids: [100, 200], now: now)

        XCTAssertEqual(snapshot.claudeSessions.map(\.pid), [200, 100])
        XCTAssertEqual(snapshot.claudeSessions[0].projectName, "octok")
        XCTAssertEqual(snapshot.claudeSessions[1].contextTokens, 100_000)
        XCTAssertEqual(snapshot.claudeSessions[1].contextLimit, 200_000)
        XCTAssertEqual(snapshot.claudeSessions[1].contextFraction ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.claudeSessions[1].subagentCount, 3)
        XCTAssertEqual(snapshot.claudeSessions[1].status, "busy")
        XCTAssertEqual(snapshot.claudeSessions[1].ageSeconds ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(snapshot.usage?.fiveHour?.usedPercentage, 17)
    }

    func testCatalogFiltersDeadPidEveryRoundWithoutIO() {
        let reader = FakeReader()
        reader.registry = [makeEntry(100, startedAtMs: 0), makeEntry(200, startedAtMs: 0)]

        let t0 = Date(timeIntervalSince1970: 1000)
        var catalog = AgentSessionCatalog(refreshInterval: 5)
        _ = catalog.update(reader: reader, alivePids: [100, 200], now: t0)
        let callsAfterRefresh = reader.ioCalls

        // 节流窗内:200 退出——立即下榜且零新增 IO;时长用新时刻重算。
        let t1 = t0.addingTimeInterval(2)
        let snapshot = catalog.update(reader: reader, alivePids: [100], now: t1)
        XCTAssertEqual(snapshot.claudeSessions.map(\.pid), [100])
        XCTAssertEqual(reader.ioCalls, callsAfterRefresh)
        XCTAssertEqual(snapshot.claudeSessions[0].ageSeconds ?? 0, 1002, accuracy: 0.001)

        // 越过节流窗:全套重读。
        let t2 = t0.addingTimeInterval(6)
        _ = catalog.update(reader: reader, alivePids: [100], now: t2)
        XCTAssertGreaterThan(reader.ioCalls, callsAfterRefresh)
    }

    func testCatalogAggregatesZCodeSessions() throws {
        let reader = FakeReader()
        reader.registry = []
        reader.zcode = [
            ("sess_old", zcodeMeta(updatedAt: "2026-11-12T07:00:00.000Z", tokens: 100)),
            ("sess_new", zcodeMeta(status: "running", updatedAt: "2026-11-12T08:00:00.000Z", tokens: 200)),
            ("sess_new", zcodeMeta(status: "completed", updatedAt: "2026-11-12T07:30:00.000Z", tokens: 300)),
            ("sess_new", zcodeMeta(updatedAt: "2026-11-12T07:40:00.000Z", tokens: nil)),
        ]

        let now = try XCTUnwrap(AgentISO8601.parse("2026-11-12T08:10:00.000Z"))
        var catalog = AgentSessionCatalog()
        let snapshot = catalog.update(reader: reader, alivePids: [], now: now)

        XCTAssertEqual(snapshot.zcodeSessions.map(\.sessionId), ["sess_new", "sess_old"])
        let latest = snapshot.zcodeSessions[0]
        XCTAssertEqual(latest.workspaceName, "pulse")
        // 真路径随行(agent-tab/05:在跑归组要全路径走 worktree 折叠)。
        XCTAssertEqual(latest.workspaceRoot, "/Users/aa00930/Documents/Learn/macos/pulse")
        XCTAssertEqual(latest.activeAgents, 1)
        XCTAssertEqual(latest.totalAgents, 3)
        XCTAssertEqual(latest.totalTokens, 500)
        XCTAssertEqual(latest.updatedAgoSeconds ?? 0, 600, accuracy: 0.001)
    }

    func testCatalogCapsZCodeSessionCount() {
        let reader = FakeReader()
        reader.registry = []
        reader.zcode = (0 ..< AgentSessionCatalog.maxZCodeSessions + 5).map { index in
            ("sess_\(index)", zcodeMeta(updatedAt: "2026-11-12T0\(index % 10):00:00.000Z"))
        }

        var catalog = AgentSessionCatalog()
        let snapshot = catalog.update(reader: reader, alivePids: [], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snapshot.zcodeSessions.count, AgentSessionCatalog.maxZCodeSessions)
    }

    // MARK: - ZCode 增量(agent-scan-cost)

    func testZCodeUnchangedMtimeIsNotReread() {
        let reader = FakeReader()
        let t0 = Date(timeIntervalSince1970: 1000)
        reader.zcodeFiles = [
            ("s/a1", "sess_a", t0, zcodeMeta(status: "running", updatedAt: "2026-11-12T08:00:00.000Z", tokens: 100)),
            ("s/a2", "sess_a", t0, zcodeMeta(updatedAt: "2026-11-12T07:00:00.000Z", tokens: 200)),
        ]
        var catalog = AgentSessionCatalog(refreshInterval: 5)
        let first = catalog.update(reader: reader, alivePids: [], now: t0)
        XCTAssertEqual(Set(reader.zcodeReads), ["s/a1", "s/a2"])
        XCTAssertEqual(first.zcodeSessions.first?.totalTokens, 300)

        // 越过节流窗、清单时间都没变:一份内容都不重读,聚合照旧。
        let second = catalog.update(reader: reader, alivePids: [], now: t0.addingTimeInterval(6))
        XCTAssertEqual(reader.zcodeReads.count, 2, "修改时间没变的 metadata 不得重读")
        XCTAssertEqual(second.zcodeSessions.map(\.sessionId), ["sess_a"])
        XCTAssertEqual(second.zcodeSessions.first?.totalTokens, 300)
        XCTAssertEqual(second.zcodeSessions.first?.activeAgents, 1)
    }

    func testZCodeChangedMtimeIsRereadAndVanishedIsDropped() {
        let reader = FakeReader()
        let t0 = Date(timeIntervalSince1970: 1000)
        reader.zcodeFiles = [
            ("s/a1", "sess_a", t0, zcodeMeta(status: "running", tokens: 100)),
            ("s/b1", "sess_b", t0, zcodeMeta(tokens: 50)),
        ]
        var catalog = AgentSessionCatalog(refreshInterval: 5)
        _ = catalog.update(reader: reader, alivePids: [], now: t0)

        // a1 被改写(时间前进 + 内容变),b1 掉出清单。
        reader.zcodeFiles = [
            ("s/a1", "sess_a", t0.addingTimeInterval(3), zcodeMeta(status: "completed", tokens: 900)),
        ]
        let snapshot = catalog.update(reader: reader, alivePids: [], now: t0.addingTimeInterval(6))
        XCTAssertEqual(reader.zcodeReads.filter { $0 == "s/a1" }.count, 2, "时间变了的要重读")
        XCTAssertEqual(snapshot.zcodeSessions.map(\.sessionId), ["sess_a"], "掉出清单的会话下榜")
        XCTAssertEqual(snapshot.zcodeSessions.first?.totalTokens, 900)
        XCTAssertEqual(snapshot.zcodeSessions.first?.activeAgents, 0)

        // b1 再回到清单(同一修改时间):缓存已删,必须重读而不是用陈旧项。
        reader.zcodeFiles.append(("s/b1", "sess_b", t0, zcodeMeta(tokens: 50)))
        _ = catalog.update(reader: reader, alivePids: [], now: t0.addingTimeInterval(12))
        XCTAssertEqual(reader.zcodeReads.filter { $0 == "s/b1" }.count, 2)
    }

    func testZCodeMalformedFileIsNotReparsedUntilItChanges() {
        let reader = FakeReader()
        let t0 = Date(timeIntervalSince1970: 1000)
        reader.zcodeFiles = [("s/bad", "sess_a", t0, Data("junk".utf8))]
        var catalog = AgentSessionCatalog(refreshInterval: 5)
        _ = catalog.update(reader: reader, alivePids: [], now: t0)
        _ = catalog.update(reader: reader, alivePids: [], now: t0.addingTimeInterval(6))
        XCTAssertEqual(reader.zcodeReads, ["s/bad"], "畸形但没变的文件不该每轮重读")

        reader.zcodeFiles = [("s/bad", "sess_a", t0.addingTimeInterval(7), zcodeMeta(tokens: 42))]
        let snapshot = catalog.update(reader: reader, alivePids: [], now: t0.addingTimeInterval(12))
        XCTAssertEqual(snapshot.zcodeSessions.first?.totalTokens, 42, "改写后应重读并上榜")
    }

    func testZCodeFailedReadIsRetriedNextRefresh() {
        let reader = FakeReader()
        let t0 = Date(timeIntervalSince1970: 1000)
        reader.zcodeFiles = [("s/a1", "sess_a", t0, zcodeMeta(tokens: 7))]
        reader.unreadable = ["s/a1"]
        var catalog = AgentSessionCatalog(refreshInterval: 5)
        let first = catalog.update(reader: reader, alivePids: [], now: t0)
        XCTAssertTrue(first.zcodeSessions.isEmpty)

        // 同一修改时间、这次读得到:必须重试,而不是把上次失败当「坏文件」缓存住。
        reader.unreadable = []
        let second = catalog.update(reader: reader, alivePids: [], now: t0.addingTimeInterval(6))
        XCTAssertEqual(second.zcodeSessions.first?.totalTokens, 7)
    }
}
