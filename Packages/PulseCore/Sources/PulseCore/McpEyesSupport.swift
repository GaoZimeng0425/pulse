import Foundation
import GRDB

// MARK: - mcp-eyes 双端共用(mcp-eyes/01+02)

//
// 文案单出处 + 告警/dev server 的读侧查询(读侧给 pulse-mcp 经 withDatabase
// 直查,写侧在 app 的两个 actor store,同一张表两把钥匙)。口径注释全在
// InsightQuery 与两个 store;这里只有「怎么讲成人话」。

/// recent_alerts 的一行:同 (kind, subject) 聚合后的告警画像。
public struct AlertEventRow: Equatable, Sendable {
    public let kind: String
    public let subjectKey: String
    public let subjectName: String?
    /// 最近一次触发的读数(种类原生单位)。
    public let latestValue: Double
    /// 最近一次触发(epoch 秒)。
    public let latestAtSeconds: Int
    /// 窗口内触发次数。
    public let count: Int

    public init(
        kind: String,
        subjectKey: String,
        subjectName: String?,
        latestValue: Double,
        latestAtSeconds: Int,
        count: Int
    ) {
        self.kind = kind
        self.subjectKey = subjectKey
        self.subjectName = subjectName
        self.latestValue = latestValue
        self.latestAtSeconds = latestAtSeconds
        self.count = count
    }
}

/// list_dev_servers 的一行:dev server 状态快照(pid 主键 upsert)。
public struct DevServerStateRow: Equatable, Sendable {
    public let pid: Int
    public let kind: String
    public let name: String
    public let memoryBytes: Int
    /// 闲置秒数;nil = 最后一次见到时未闲置。
    public let idleSeconds: Double?
    public let ports: [UInt16]
    public let firstSeenSeconds: Int
    public let lastSeenSeconds: Int

    public init(
        pid: Int,
        kind: String,
        name: String,
        memoryBytes: Int,
        idleSeconds: Double?,
        ports: [UInt16],
        firstSeenSeconds: Int,
        lastSeenSeconds: Int
    ) {
        self.pid = pid
        self.kind = kind
        self.name = name
        self.memoryBytes = memoryBytes
        self.idleSeconds = idleSeconds
        self.ports = ports
        self.firstSeenSeconds = firstSeenSeconds
        self.lastSeenSeconds = lastSeenSeconds
    }
}

/// 读侧直查(pulse-mcp 经 withDatabase;store 单测复用同一 SQL,不双写口径)。
public enum McpEyesQuery {
    /// 窗口 [now−hours·3600, now] 内告警,同主体聚合(最新读数/时刻 + 次数),
    /// 按最近触发降序。
    public static func recentAlerts(
        hours: Int,
        now: Date,
        in db: Database
    ) throws -> [AlertEventRow] {
        let end = HistoryWindows.epochSeconds(of: now)
        let start = end - hours * 3600
        let latest = try Row.fetchAll(
            db,
            sql: """
            SELECT e.kind, e.subject_key, e.subject_name, e.value, e.ts
            FROM alert_event AS e
            WHERE e.ts >= ? AND e.ts <= ?
              AND e.ts = (
                  SELECT MAX(x.ts) FROM alert_event AS x
                  WHERE x.kind = e.kind AND x.subject_key = e.subject_key
                    AND x.ts >= ? AND x.ts <= ?
              )
            ORDER BY e.ts DESC
            """,
            arguments: [start, end, start, end]
        )
        let counts = try Dictionary(
            uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: """
                SELECT kind, subject_key, COUNT(*) AS hits FROM alert_event
                WHERE ts >= ? AND ts <= ?
                GROUP BY kind, subject_key
                """,
                arguments: [start, end]
            ).map { row -> (String, Int) in
                let key = "\(row["kind"] as String)|\(row["subject_key"] as String)"
                return (key, row["hits"] ?? 0)
            }
        )
        return latest.map { row in
            let kind: String = row["kind"]
            let subjectKey: String = row["subject_key"]
            return AlertEventRow(
                kind: kind,
                subjectKey: subjectKey,
                subjectName: row["subject_name"],
                latestValue: row["value"] ?? 0,
                latestAtSeconds: row["ts"],
                count: counts["\(kind)|\(subjectKey)"] ?? 1
            )
        }
    }

    /// dev server 全量状态行(按最后见到降序;新鲜度由调用方换算)。
    public static func devServers(in db: Database) throws -> [DevServerStateRow] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT pid, kind, name, memory_bytes, idle_seconds, ports, first_seen, last_seen FROM dev_server_state ORDER BY last_seen DESC, pid"
        )
        return rows.map { row in
            DevServerStateRow(
                pid: row["pid"],
                kind: row["kind"],
                name: row["name"],
                memoryBytes: row["memory_bytes"] ?? 0,
                idleSeconds: row["idle_seconds"],
                ports: (row["ports"] as String?)
                    .map { $0.split(separator: ",").compactMap { UInt16($0) } } ?? [],
                firstSeenSeconds: row["first_seen"],
                lastSeenSeconds: row["last_seen"]
            )
        }
    }
}

/// 五个 mcp-eyes 工具的中文输出(单出处;pulse-mcp 只接线)。
public enum McpEyesText {
    /// why_memory_high 输出;systemMemory 上下文行(nil = 库里暂无整机内存读数)。
    public static func memoryRanking(
        _ rows: [InsightQuery.GroupMemoryInsight],
        systemMemory: LatestSnapshot.Gauge?,
        lookbackMinutes: Int,
        now: Date
    ) -> String {
        if rows.isEmpty {
            return emptyWindowText("内存排行", windowMinutes: lookbackMinutes)
        }
        var lines: [String] = []
        if let memory = systemMemory {
            lines.append(
                "全部应用内存合计(当分钟峰值,含压缩可超物理):"
                    + PulseFormat.memory(UInt64(max(0, memory.value)))
                    + "(\(ageText(atSeconds: memory.atSeconds, now: now)))"
            )
        }
        lines.append("最近窗口内内存(当分钟峰值)最高的 \(rows.count) 个组:")
        for (index, group) in rows.enumerated() {
            var line = "\(index + 1). \(group.name) — 均值 \(PulseFormat.memory(UInt64(max(0, group.memoryAverageBytes)))),峰值 \(PulseFormat.memory(UInt64(max(0, group.memoryPeakBytes))))(\(group.processCount) 进程)"
            if let project = group.projectRoot {
                line += ",项目:\(project)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// top_disk_io 输出(窗口总量口径)。
    public static func diskRanking(
        _ rows: [InsightQuery.GroupDiskInsight],
        lookbackMinutes: Int,
        now _: Date
    ) -> String {
        if rows.isEmpty {
            return "最近 \(lookbackMinutes) 分钟历史库没有磁盘账(sample_min 的 disk_r/disk_w 为空——app 未运行或该时段无样本)。"
        }
        var lines = ["最近 \(lookbackMinutes) 分钟磁盘读写总量最高的 \(rows.count) 个组:"]
        let anyNull = rows.contains(where: \.hasNullMinutes)
        if anyNull {
            lines.append("(部分分钟缺磁盘账,总量偏小,已如实计 0)")
        }
        for (index, group) in rows.enumerated() {
            var line = "\(index + 1). \(group.name) — 读 \(PulseFormat.memory(UInt64(max(0, group.readBytes)))),写 \(PulseFormat.memory(UInt64(max(0, group.writtenBytes))))"
            if let project = group.projectRoot {
                line += ",项目:\(project)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// process_info 输出;alive 按 pid 注入(true/false,nil = 没探)。
    public static func processProfiles(
        _ rows: [InsightQuery.ProcessProfile],
        alive: [Int: Bool],
        now: Date
    ) -> String {
        if rows.isEmpty {
            return "出生登记表里没有匹配的进程(档案只登记 Pulse 运行期间见过的进程;刚启动的查不到)。"
        }
        var lines = ["匹配 \(rows.count) 个进程(出生登记档案,首见≠存活):"]
        for profile in rows {
            var line = "- pid \(profile.pid)"
            if let isAlive = alive[profile.pid] {
                line += isAlive ? "(存活)" : "(已退出)"
            }
            line += " 父pid \(profile.parentPID) 首见 \(ageText(atSeconds: profile.firstSeenSeconds, now: now))"
            if let path = profile.executablePath, !path.isEmpty {
                line += "\n  可执行:\(path)"
            }
            if let cwd = profile.cwd, !cwd.isEmpty {
                line += "\n  工作目录:\(cwd)"
            }
            if let argv = profile.argv, !argv.isEmpty {
                line += "\n  命令行:\(String(argv.prefix(300)))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// recent_alerts 输出(同主体聚合)。
    public static func alertHistory(_ rows: [AlertEventRow], now: Date) -> String {
        if rows.isEmpty {
            return "窗口内没有告警记录(app 触发过才会落库;落盘自 mcp-eyes 起生效,更早的告警没有留档)。"
        }
        var lines = ["窗口内告警 \(rows.count) 类(同主体聚合,按最近触发降序):"]
        for row in rows {
            let title = AlertKind(rawValue: row.kind)?.title ?? row.kind
            var line = "- \(title)\(row.subjectName.map { "(\($0))" } ?? "") — 最近 \(ageText(atSeconds: row.latestAtSeconds, now: now)),读数 \(formatAlertValue(kind: row.kind, value: row.latestValue))"
            if row.count > 1 {
                line += ",窗口内 \(row.count) 次"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// list_dev_servers 输出;超过 `goneAfterSeconds` 未见如实说可能已退出。
    public static func devServers(
        _ rows: [DevServerStateRow],
        now: Date,
        goneAfterSeconds: Int = 600
    ) -> String {
        if rows.isEmpty {
            return "没有 dev server 记录(Pulse 运行期间没见过本地 dev server 进程,如 vite/next dev)。"
        }
        var lines = ["dev server \(rows.count) 个(状态为最后一次见到时;退出即从表里清掉,久未见=可能已退出):"]
        for row in rows {
            let age = max(0, HistoryWindows.epochSeconds(of: now) - row.lastSeenSeconds)
            var line = "- \(row.name)(\(row.kind)) pid \(row.pid) · \(PulseFormat.memory(UInt64(max(0, row.memoryBytes))))"
            if let idle = row.idleSeconds {
                line += " · 已闲置 \(PulseFormat.duration(seconds: idle))"
            } else {
                line += " · 活跃中(最近 10 分钟有活动)"
            }
            line += row.ports.isEmpty ? "" : " · 端口 \(row.ports.map(String.init).joined(separator: "/"))"
            line += " · 最后见到 \(ageText(atSeconds: row.lastSeenSeconds, now: now))"
            if age > goneAfterSeconds {
                line += "(可能已退出)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 数据年龄人话(与 pulse-mcp 私有 ageText 同档:秒/分钟/小时)。
    public static func ageText(atSeconds: Int, now: Date) -> String {
        let age = max(0, HistoryWindows.epochSeconds(of: now) - atSeconds)
        if age < 90 {
            return "\(age) 秒前"
        }
        if age < 90 * 60 {
            return "\(age / 60) 分钟前"
        }
        return "\(age / 3600) 小时前"
    }

    private static func emptyWindowText(_ what: String, windowMinutes: Int) -> String {
        "最近 \(windowMinutes) 分钟历史库没有样本(Pulse 未运行,或刚启动还没落库),\(what)无从谈起。"
    }

    /// 告警读数单位随种类(与 AlertNotificationContent 同口径的最小版)。
    private static func formatAlertValue(kind: String, value: Double) -> String {
        switch AlertKind(rawValue: kind) {
        case .diskAvailable:
            PulseFormat.diskCapacity(UInt64(max(0, value)))
        default:
            PulseFormat.cpuPercent(value)
        }
    }
}
