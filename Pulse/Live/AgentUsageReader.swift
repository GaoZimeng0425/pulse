import Foundation
import GRDB
import PulseCore

// MARK: - 每日 token 账本 Live 读取(agent-tab/02)

//
// 三源的真 IO(路径注入 home,可测;同 LiveAgentSessionReader 惯例):
// - ZCode `~/.zcode/cli/db/db.sqlite` `model_usage` 只读查询(GRDB;表/列
//   不识别安静返回空——schema 是 ZCode 私有演进物);`PRAGMA query_only`
//   硬保证只读(HistoryDatabase.openReader 同款,WAL 库的 -shm 需要可创建,
//   不能用 SQLite readonly 模式);busy 3 秒防 ZCode 大事务写入瞬间偶发繁忙。
//   2.8GB 大头是对话正文(part/message),用量表 33MB——增量 WHERE 走
//   (started_at, …) 索引。
// - Claude `~/.claude/projects/**/*.jsonl` 文件枚举 + 64KB 分块流式逐行
//   (mtime 过滤交给调用档位:今天档只喂今天有改动的文件)。
//   `~/.claude/transcripts/`(wrapper 转录,实测行无 message.usage)不扫。
// - `~/.claude/stats-cache.json` 只读 Data。

/// 每日账本三源 Live 读取。
struct LiveAgentUsageReader: AgentUsageReading {
    /// 测试注入的 home(默认真实用户目录)。
    let home: URL

    /// jsonl 分块读的块大小。
    private static let chunkBytes = 64 * 1024

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func zcodeUsageSamples(sinceStartedAtMs: Int64?) -> (
        samples: [ZCodeUsageSample], legacySchema: Bool
    ) {
        let dbURL = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return ([], false) }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")
        }
        configuration.busyMode = .timeout(3)
        guard let database = try? DatabaseQueue(path: dbURL.path, configuration: configuration)
        else { return ([], false) }

        // 列探测:表不在 → 空;`computed_total_tokens` 缺失 = legacy schema
        // (tokscale 同款判定,唯一索引列不猜)。`model_id` 缺失(更老 schema)
        // → SELECT 补 NULL,样本不带模型、只进合计/项目轨(agent-tab/05)。
        let columns = (try? database.read { db in
            try db.columns(in: "model_usage")
        }) ?? []
        guard !columns.isEmpty else { return ([], false) }
        let legacySchema = !columns.contains { $0.name == "computed_total_tokens" }
        let hasModelID = columns.contains { $0.name == "model_id" }

        // 列名全限定 model_usage 前缀(modern 版 join session 后 `id` 等会歧义);
        // workspace 两列走别名,缺失(NULL)→ 样本 workspacePath nil,只进合计轨。
        let baseColumns = """
        model_usage.id, model_usage.started_at, model_usage.completed_at, model_usage.duration_ms,
        model_usage.input_tokens, model_usage.output_tokens, model_usage.reasoning_tokens,
        model_usage.cache_read_input_tokens, model_usage.cache_creation_input_tokens,
        \(hasModelID ? "model_usage.model_id" : "NULL AS model_id")
        """
        var sql = if legacySchema {
            "SELECT \(baseColumns) FROM model_usage"
        } else {
            """
            SELECT \(baseColumns), model_usage.computed_total_tokens,
                   NULLIF(s.directory, '') AS workspace_directory, NULLIF(s.path, '') AS workspace_path
            FROM model_usage LEFT JOIN session s ON s.id = model_usage.session_id
            """
        }
        var arguments: [DatabaseValueConvertible] = []
        if let sinceStartedAtMs {
            sql += " WHERE model_usage.started_at >= ?"
            arguments.append(sinceStartedAtMs)
        }

        var samples: [ZCodeUsageSample] = []
        _ = try? database.read { db in
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)) {
                let workspace: String? = legacySchema
                    ? nil
                    : ((row["workspace_directory"] as String?) ?? (row["workspace_path"] as String?))
                samples.append(
                    ZCodeUsageSample(
                        id: row["id"] ?? "",
                        startedAtMs: row["started_at"],
                        completedAtMs: row["completed_at"],
                        durationMs: row["duration_ms"],
                        inputTokens: row["input_tokens"],
                        outputTokens: row["output_tokens"],
                        reasoningTokens: row["reasoning_tokens"],
                        cacheReadTokens: row["cache_read_input_tokens"],
                        cacheWriteTokens: row["cache_creation_input_tokens"],
                        computedTotalTokens: legacySchema ? nil : row["computed_total_tokens"],
                        workspacePath: workspace,
                        modelId: (row["model_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                    )
                )
            }
        }
        return (samples, legacySchema)
    }

    func readClaudeTranscripts(
        modifiedSince: Date?,
        consume: (_ relativePath: String, _ line: String) -> Void
    ) {
        let projectsRoot = home.appendingPathComponent(".claude/projects")
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  modifiedSince == nil
                  || (values.contentModificationDate ?? .distantPast) >= modifiedSince!
            else { continue }
            // 相对路径 <slug>/<sessionId>.jsonl:项目归组的输入(agent-tab/04)。
            // 取「父目录名 + 文件名」拼——enumerator 会把 URL 解析成 symlink 后的
            // 绝对拼写(实测 /var → /private/var,且 resolvingSymlinksInPath 还原
            // 不出 enumerator 的拼写),任何绝对前缀匹配都不可靠;projects 布局
            // 恒为 slug 一层,父目录名即 slug。
            let relativePath = url.deletingLastPathComponent().lastPathComponent
                + "/" + url.lastPathComponent
            readFileLines(url) { line in
                consume(relativePath, line)
            }
        }
    }

    func claudeStatsCacheData() -> Data? {
        try? Data(contentsOf: home.appendingPathComponent(".claude/stats-cache.json"))
    }

    /// 现存会话数(agent-tab/06):Claude = projects/<slug>/ 下 jsonl 文件数
    /// (只列文件名零读内容;30 天滚动删,口径 = 现存);ZCode = db 按 workspace
    /// 数不同 session_id(有账全史)。归组键合成项目计数在 AgentUsageWindow。
    func agentSessionCounts() -> (claude: [String: Int], zcode: [String: Int]) {
        var claude: [String: Int] = [:]
        let projectsRoot = home.appendingPathComponent(".claude/projects")
        if let slugs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for slug in slugs where (try? slug.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let sessions = (try? FileManager.default.contentsOfDirectory(
                    at: slug,
                    includingPropertiesForKeys: nil
                )) ?? []
                let count = sessions.filter { $0.pathExtension == "jsonl" }.count
                if count > 0 {
                    claude[slug.lastPathComponent] = count
                }
            }
        }

        var zcode: [String: Int] = [:]
        let dbURL = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA query_only = 1")
            }
            configuration.busyMode = .timeout(3)
            if let database = try? DatabaseQueue(path: dbURL.path, configuration: configuration),
               (try? database.read { db in try db.tableExists("model_usage") }) == true {
                // workspace 取 session 表 directory/path(与用量查询同源);NULL
                // workspace 的会话归不了组,如实不计。
                _ = try? database.read { db in
                    for row in try Row.fetchAll(db, sql: """
                    SELECT COALESCE(NULLIF(s.directory, ''), NULLIF(s.path, '')) AS workspace,
                           COUNT(DISTINCT model_usage.session_id) AS sessions
                    FROM model_usage LEFT JOIN session s ON s.id = model_usage.session_id
                    GROUP BY workspace
                    """) {
                        if let workspace = row["workspace"] as String?, !workspace.isEmpty,
                           let sessions: Int = row["sessions"], sessions > 0 {
                            zcode[workspace] = sessions
                        }
                    }
                }
            }
        }
        return (claude, zcode)
    }

    /// 64KB 分块流式逐行(大 jsonl 不整文件进内存;半行留在缓冲跨块拼接,
    /// 尾行无换行也喂)。
    private func readFileLines(_ url: URL, consume: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = (try? handle.read(upToCount: Self.chunkBytes)) ?? Data()
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex ..< newline)
                buffer.removeSubrange(buffer.startIndex ... newline)
                if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                    consume(line)
                }
            }
            if chunk.isEmpty {
                break
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            consume(line)
        }
    }
}
