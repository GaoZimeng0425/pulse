import Foundation

// MARK: - mcp-clean 双端共用数据面(mcp-clean/01)

//
// app 内 IPC 服务(CleanIPCService)与 pulse-mcp 可执行共同依赖:端点发现、
// HTTP DTO、路径求交与中文输出格式化。单出处的目的:pulse-mcp 只做 IO 接线,
// 口径与文案全部可测(PulseCore 夹具),两端口径永不漂移。

/// IPC 端点文件(`~/.Pulse/mcp-clean.json`,权限 0600):app 启动写、退出删;
/// pulse-mcp 读它发现端口与令牌(pid 已死 = app 不在,如实当未运行处理)。
public struct McpCleanEndpoint: Codable, Sendable, Equatable {
    public let port: UInt16
    public let token: String
    public let pid: Int32

    public init(port: UInt16, token: String, pid: Int32) {
        self.port = port
        self.token = token
        self.pid = pid
    }

    public static let fileName = "mcp-clean.json"

    public static func url(directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 读端点(缺失/损坏 = nil,绝不半解)。
    public static func load(at url: URL) -> McpCleanEndpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// 写端点:临时文件 + 原子换名,权限 0600(令牌只许本用户读)。
    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        let tmp = url.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: tmp.path) {
            try FileManager.default.removeItem(at: tmp)
        }
        try data.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

// MARK: - DTO

/// `/cleanable` 响应项(人话字段已折好,双端不再碰原始 epoch)。
public struct McpCleanableItem: Codable, Sendable, Equatable {
    public let title: String
    public let path: String
    /// 组标题(全局缓存 / 项目产物 / 卸载残留)。
    public let group: String
    public let bytes: Int64
    /// 「N 天未动」人话(档位与 app 内 JunkAgeText.idle 同粒度,单出处在此)。
    public let idleText: String

    public init(title: String, path: String, group: String, bytes: Int64, idleText: String) {
        self.title = title
        self.path = path
        self.group = group
        self.bytes = bytes
        self.idleText = idleText
    }
}

/// `/cleanable` 响应。
public struct McpCleanableListResponse: Codable, Sendable, Equatable {
    public let items: [McpCleanableItem]
    /// 扫描完成时刻(epoch 秒;nil = 未知,如实标)。
    public let scanFinishedAtEpoch: Double?

    public init(items: [McpCleanableItem], scanFinishedAtEpoch: Double?) {
        self.items = items
        self.scanFinishedAtEpoch = scanFinishedAtEpoch
    }
}

/// `/clean` 请求体。
public struct McpCleanRequest: Codable, Sendable, Equatable {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

/// `/clean` 响应体。
public struct McpCleanRunResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// 用户在确认单上点了「移入废纸篓」(逐项结果在 items)。
        case confirmed
        /// 用户关掉/取消确认单,一项没删。
        case cancelledByUser
        /// 等待确认超时,已撤单。
        case timeout
        /// app 已有清理在确认/进行中。
        case busy
        /// 拉起主窗口失败(等待期内窗口没开)。
        case noWindow
        /// 求交后没有任何可安全清理项(全在用/先检查档/不在清单)。
        case emptySelection
        /// 意外错误(message 为人话)。
        case appError
    }

    public let status: Status
    public let items: [McpCleanRunItem]
    /// 请求里未执行(不在当前安全档清单,或属先检查/在用保护)的路径,原样退回。
    public let unrecognized: [String]
    public let message: String?

    public init(
        status: Status,
        items: [McpCleanRunItem] = [],
        unrecognized: [String] = [],
        message: String? = nil
    ) {
        self.status = status
        self.items = items
        self.unrecognized = unrecognized
        self.message = message
    }
}

/// `/clean` 响应项(执行结果人话)。
public struct McpCleanRunItem: Codable, Sendable, Equatable {
    public let path: String
    public let outcomeText: String

    public init(path: String, outcomeText: String) {
        self.path = path
        self.outcomeText = outcomeText
    }
}

// MARK: - 求交(与界面组选同口径)

/// 请求路径 ×「可安全清理 ∩ 非在用」求交(mcp-clean/01)。
/// 「先检查」档与在用保护项的路径落进 unrecognized **原样退回**——AI 拿到的是
/// 「哪些没执行」,不是静默丢弃;删除侧另有 plan 二次判定兜底,双层防线。
public enum McpCleanMatching {
    public struct Result: Sendable, Equatable {
        public let matched: [JunkCandidate]
        public let unrecognized: [String]
    }

    public static func match(
        requestedPaths: [String],
        candidates: [JunkCandidate],
        activityEntries: [CleanActivityEntry]
    ) -> Result {
        let byPath = Dictionary(
            candidates.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var matched: [JunkCandidate] = []
        var unrecognized: [String] = []
        var seen = Set<String>()
        for raw in requestedPaths {
            let path = PathNormalization.normalize(raw)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            guard let candidate = byPath[path],
                  candidate.tier == .safe,
                  CleanInUse.reasons(
                      protectingPath: CleanInUse.protectionPath(for: candidate),
                      entries: activityEntries
                  ) == nil
            else {
                unrecognized.append(raw)
                continue
            }
            matched.append(candidate)
        }
        return Result(matched: matched, unrecognized: unrecognized)
    }
}

// MARK: - 中文输出(MCP 工具文案单出处)

/// `list_cleanable` / `clean` 两工具的输出文案:pulse-mcp 只接线,不造句。
public enum McpCleanText {
    /// list_cleanable 输出。
    public static func cleanableList(_ response: McpCleanableListResponse, now: Date = Date()) -> String {
        guard !response.items.isEmpty else {
            return "当前没有「可安全清理」的项——未扫描、已清完,或全部处于在用保护。"
                + "先在 Pulse app 的「可清理」页点「扫描整台 Mac」。"
        }
        let total = response.items.reduce(Int64(0)) { $0 + $1.bytes }
        var lines = [
            "可安全清理 \(response.items.count) 项 · 合计 \(PulseFormat.memory(UInt64(max(0, total))))"
                + (response.scanFinishedAtEpoch.map { "(数据来自 \(scanAgeText(atEpoch: $0, now: now))的扫描)" } ?? ""),
        ]
        for (index, item) in response.items.enumerated() {
            lines.append(
                "\(index + 1). [\(item.group)] \(item.title) — \(item.path)"
                    + " · \(PulseFormat.memory(UInt64(max(0, item.bytes)))) · \(item.idleText)"
            )
        }
        lines.append("只含「可安全清理」且此刻不在用的项;「先检查」档与在用保护项不在此清单,须在 Pulse app 里亲手勾选。")
        return lines.joined(separator: "\n")
    }

    /// clean 输出。
    public static func cleanResult(_ response: McpCleanRunResponse) -> String {
        var lines: [String]
        switch response.status {
        case .confirmed:
            let recycled = response.items.filter { $0.outcomeText == recycledText }.count
            lines = ["已执行:用户在 Pulse 确认单上点了「移入废纸篓」,\(recycled)/\(response.items.count) 项已进废纸篓。"]
            for item in response.items {
                lines.append("- \(item.path) — \(item.outcomeText)")
            }
        case .cancelledByUser:
            lines = ["用户取消了确认单,一项没删。"]
        case .timeout:
            lines = ["等待确认超时(10 分钟),确认单已撤,一项没删。需要的话重新发起。"]
        case .busy:
            lines = ["Pulse 里已有清理在确认或进行中,稍后再试。"]
        case .noWindow:
            lines = ["没能拉起 Pulse 主窗口(60 秒内没开窗),已撤单——请打开 Pulse 后重试。"]
        case .emptySelection:
            lines = ["请求的路径没有可安全清理项(不在当前清单,或属「先检查」档/在用保护)。"]
        case .appError:
            lines = ["清理请求失败:\(response.message ?? "未知错误")"]
        }
        if !response.unrecognized.isEmpty {
            lines.append("未执行(不在安全档清单或在用保护):")
            lines.append(response.unrecognized.map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// CleanRunReport → 响应项(结果文案单出处)。
    public static func runItems(from report: CleanRunReport) -> [McpCleanRunItem] {
        report.items.map { item in
            McpCleanRunItem(path: item.path, outcomeText: outcomeText(item.outcome))
        }
    }

    public static let recycledText = "已移入废纸篓"

    /// newestChangeEpoch →「N 天未动」(档位与 app 内 JunkAgeText.idle 一致:
    /// 天/月/年;文案重复而非引用——那是 app 目标 internal,提公共只为这一句不值)。
    public static func idleText(epoch: Double?, now: Date = Date()) -> String {
        guard let epoch else { return "未动时间未知" }
        let days = Int(now.timeIntervalSince1970 - epoch) / 86400
        switch days {
        case ..<1: return "今天动过"
        case ..<30: return "\(days) 天未动"
        case ..<365: return "\(days / 30) 个月未动"
        default: return "\(days / 365) 年未动"
        }
    }

    private static func scanAgeText(atEpoch epoch: Double, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince1970 - epoch) / 60
        if minutes < 1 {
            return "刚刚"
        }
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) 小时前"
        }
        return "\(hours / 24) 天前"
    }

    private static func outcomeText(_ outcome: CleanItemOutcome) -> String {
        switch outcome {
        case .recycled: recycledText
        case let .permanentlyDeleted(route): route == .brew ? "已卸载(brew,永久)" : "永久删除"
        case let .failed(reason): "失败:\(reason)"
        }
    }
}
