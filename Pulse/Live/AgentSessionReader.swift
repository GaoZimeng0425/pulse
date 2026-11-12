import Foundation
import PulseCore

// MARK: - AI 助手会话文件读源(智能体 tab,agent-tab/01)

//
// ~/.claude 与 ~/.zcode 的纯文件读:注册表 / 用量快照 / 会话 jsonl 尾读 / 子代理
// 目录计数 / ZCode metadata。都是用户自己主目录下的普通文件,无 TCC 权限;不执行
// 任何 agent,不联网。读取节奏由 AgentSessionCatalog 节流(≥5s 一轮),本层只管
// 一次性读对地方。解析与编排全在 PulseCore(AgentSessionModel,单测合成夹具)。

/// Live 读源:路径约定钉在 Open(实测 2026-11-12)——
/// - `~/.claude/sessions/<pid>.json`(活跃实例注册表)
/// - `~/.claude/usage-snapshot.json`(订阅用量)
/// - `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`(slug = cwd 的 "/"→"-")
/// - `~/.zcode/cli/agents/sess_*/agent_*/metadata.json`(近窗按文件 mtime)
struct LiveAgentSessionReader: AgentSessionReading {
    /// jsonl 尾读窗口:末 128KB(末条 assistant usage 记录远小于此;窗口头部的
    /// 半行由解析器自然丢弃)。
    private static let transcriptTailBytes = 128 * 1024

    private let sessionsDirectory: URL
    private let usageSnapshotFile: URL
    private let projectsDirectory: URL
    private let zcodeAgentsDirectory: URL

    /// 无存储 FileManager(同 LiveAppCatalogSource 惯例:struct 纯函数集合,Sendable
    /// 由编译器自动合成;FileManager 每次调用点局部取 `.default`)。
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let claudeRoot = home.appendingPathComponent(".claude", isDirectory: true)
        sessionsDirectory = claudeRoot.appendingPathComponent("sessions", isDirectory: true)
        usageSnapshotFile = claudeRoot.appendingPathComponent("usage-snapshot.json")
        projectsDirectory = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        zcodeAgentsDirectory = home.appending(path: ".zcode/cli/agents", directoryHint: .isDirectory)
    }

    // MARK: Claude Code

    func claudeRegistryFiles() -> [Data] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                // 只认 <pid>.json;同目录的 *.key 伴生文件不是注册表。
                guard name.dropLast(".json".count).allSatisfy(\.isNumber) else { return nil }
                return try? Data(contentsOf: sessionsDirectory.appendingPathComponent(name))
            }
    }

    func claudeUsageSnapshotFile() -> Data? {
        try? Data(contentsOf: usageSnapshotFile)
    }

    func claudeTranscriptTail(cwd: String, sessionId: String) -> Data? {
        guard let url = resolveTranscript(cwd: cwd, sessionId: sessionId),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let window = UInt64(Self.transcriptTailBytes)
        let start = end > window ? end - window : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    func claudeSubagentCount(cwd: String, sessionId: String) -> Int {
        // 会话目录(与 jsonl 同目录,<sessionId>/subagents/agent-*.jsonl)。
        let sessionDirectory = projectsDirectory
            .appendingPathComponent(Self.slug(forCwd: cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("agent-") }.count
    }

    /// jsonl 路径解析:先按 slug 公式(cwd "/"→"-"),失配回退 projects 一层目录扫描。
    private func resolveTranscript(cwd: String, sessionId: String) -> URL? {
        let fileManager = FileManager.default
        let filename = "\(sessionId).jsonl"
        let primary = projectsDirectory
            .appendingPathComponent(Self.slug(forCwd: cwd), isDirectory: true)
            .appendingPathComponent(filename)
        if fileManager.fileExists(atPath: primary.path) {
            return primary
        }
        // 回退:注册表 cwd 可能与会话落盘时的项目根不一致(如会话起于 worktree)。
        let candidates = (try? fileManager.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
        for directory in candidates where
            fileManager.fileExists(
                atPath: projectsDirectory
                    .appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(filename).path
            ) {
            return projectsDirectory.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(filename)
        }
        return nil
    }

    /// cwd → projects 目录名(实测编码:"/"→"-",首斜杠产生前导 "-")。
    private static func slug(forCwd cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: ZCode

    func zcodeAgentMetadataFiles(lookback: TimeInterval, now: Date) -> [(session: String, data: Data)] {
        let fileManager = FileManager.default
        let cutoff = now.addingTimeInterval(-lookback)
        let sessionNames = (try? fileManager.contentsOfDirectory(atPath: zcodeAgentsDirectory.path)) ?? []
        // 每会话:收集近窗 metadata(URL, mtime),按 agent 数上限截(新者优先),
        // 全空(近窗无更新)不进结果;会话按最新 agent mtime 排序并按上限截。
        var sessions: [(name: String, files: [(url: URL, mtime: Date)])] = []
        for name in sessionNames where name.hasPrefix("sess_") {
            let sessionDirectory = zcodeAgentsDirectory.appendingPathComponent(name, isDirectory: true)
            let agentNames = (try? fileManager.contentsOfDirectory(atPath: sessionDirectory.path)) ?? []
            var files: [(url: URL, mtime: Date)] = []
            for agent in agentNames where agent.hasPrefix("agent_") {
                let url = sessionDirectory
                    .appendingPathComponent(agent, isDirectory: true)
                    .appendingPathComponent("metadata.json")
                guard let mtime = modificationDate(of: url), mtime >= cutoff else { continue }
                files.append((url, mtime))
            }
            guard !files.isEmpty else { continue }
            files.sort { $0.mtime > $1.mtime }
            sessions.append((name, Array(files.prefix(AgentSessionCatalog.maxZCodeAgentsPerSession))))
        }
        sessions.sort { $0.files.first?.mtime ?? .distantPast > $1.files.first?.mtime ?? .distantPast }
        return sessions.prefix(AgentSessionCatalog.maxZCodeSessions).flatMap { session in
            session.files.compactMap { file in
                (try? Data(contentsOf: file.url)).map { (session: session.name, data: $0) }
            }
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
