@testable import Pulse
@testable import PulseCore
import XCTest

/// LiveAgentSessionReader 的文件面 smoke(智能体 tab,agent-tab/01):合成临时
/// 目录冒充 home,钉路径约定 / 尾读 / slug 回退 / mtime 近窗过滤。不读真实
/// ~/.claude 与 ~/.zcode,负载极小(个位数小文件)。
final class AgentSessionReaderTests: XCTestCase {
    private var home: URL!
    private var reader: LiveAgentSessionReader!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        reader = LiveAgentSessionReader(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - 夹具

    private func directory(_ path: String) throws -> URL {
        let url = home.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ text: String, to path: String, mtime: Date? = nil) throws -> URL {
        let url = home.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.data(using: .utf8)?.write(to: url)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// 与内核测试同款的末条 assistant 行。
    private static let assistantLine = """
    {"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_read_input_tokens":479870,"cache_creation_input_tokens":425,"output_tokens":202}},"timestamp":"2026-11-12T08:15:08.276Z"}
    """

    // MARK: - Claude Code

    func testRegistryReadsOnlyPidJsonFiles() throws {
        try directory(".claude/sessions")
        try write(
            #"{"pid":123,"sessionId":"s1","cwd":"/Users/x/pulse","startedAt":1000,"status":"busy"}"#,
            to: ".claude/sessions/123.json"
        )
        // 伴生 key 与非纯数字名都不是注册表。
        try write("{}", to: ".claude/sessions/123.deadbeef.key")
        try write("{}", to: ".claude/sessions/readme.json")

        let entries = reader.claudeRegistryFiles().compactMap(ClaudeSessionRegistry.parse)
        XCTAssertEqual(entries.map(\.pid), [123])
        XCTAssertEqual(entries.first?.status, "busy")
    }

    func testUsageSnapshotReads() throws {
        try write(
            #"{"five_hour":{"used_percentage":17,"resets_at":"2026-11-12T12:00:00.000Z"}}"#,
            to: ".claude/usage-snapshot.json"
        )
        XCTAssertEqual(
            reader.claudeUsageSnapshotFile().flatMap(ClaudeUsageSnapshot.parse)?.fiveHour?.usedPercentage,
            17
        )
    }

    func testTranscriptTailResolvesSlugAndFallsBack() throws {
        try directory(".claude/projects/-Users-x-pulse")
        try write(Self.assistantLine, to: ".claude/projects/-Users-x-pulse/s1.jsonl")

        // cwd 公式命中(-Users-x-pulse)。
        let direct = reader.claudeTranscriptTail(cwd: "/Users/x/pulse", sessionId: "s1")
            .flatMap(ClaudeTranscriptTail.parse)
        XCTAssertEqual(direct?.context?.contextTokens, 479_872)

        // cwd 公式失配(会话起于别处)→ 回退 projects 一层扫描仍找到。
        let fallback = reader.claudeTranscriptTail(cwd: "/Users/x/other", sessionId: "s1")
            .flatMap(ClaudeTranscriptTail.parse)
        XCTAssertEqual(fallback?.context?.model, "claude-opus-5-5")

        // 完全不存在 → nil。
        XCTAssertNil(reader.claudeTranscriptTail(cwd: "/Users/x/gone", sessionId: "s9"))
    }

    func testSubagentCountCountsAgentFiles() throws {
        try directory(".claude/projects/-Users-x-pulse/s1/subagents")
        try write("{}", to: ".claude/projects/-Users-x-pulse/s1/subagents/agent-a.jsonl")
        try write("{}", to: ".claude/projects/-Users-x-pulse/s1/subagents/agent-b.jsonl")
        try write("{}", to: ".claude/projects/-Users-x-pulse/s1/subagents/notes.txt")
        XCTAssertEqual(reader.claudeSubagentCount(cwd: "/Users/x/pulse", sessionId: "s1"), 2)
        XCTAssertEqual(reader.claudeSubagentCount(cwd: "/Users/x/pulse", sessionId: "s2"), 0)
    }

    // MARK: - ZCode

    func testZCodeMetadataFiltersByMtimeLookback() throws {
        let now = Date()
        let fresh = now.addingTimeInterval(-60)
        let stale = now.addingTimeInterval(-48 * 3600)
        let meta = #"{"agentId":"agent_x","status":"completed","updatedAt":"2026-11-12T07:55:23.231Z","workspaceRoot":"/Users/x/pulse","profileId":"Explore","totalTokens":556100}"#
        try write(meta, to: ".zcode/cli/agents/sess_fresh/agent_a/metadata.json", mtime: fresh)
        try write(meta, to: ".zcode/cli/agents/sess_stale/agent_x/metadata.json", mtime: stale)

        let files = reader.zcodeAgentMetadataFiles(lookback: 24 * 3600, now: now)
        XCTAssertEqual(files.map(\.session), ["sess_fresh"])
        XCTAssertEqual(ZCodeAgentMetadata.parse(files[0].data)?.totalTokens, 556_100)
    }
}
