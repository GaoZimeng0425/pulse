import Foundation
import GRDB

// MARK: - 洞察查询(p3-root-mcp/02:pulse-mcp 的读侧弹药)

// why_cpu_high 的组排行与 current_metrics 的最新快照,取数口径全部钉在这
// 一份里(单测见 InsightQueryTests,真 SQLite 内存库);三个工具的其余
// 曲线需求直接复用 `HistoryQuery.series`(工单 04 口径,零第二出处)。

/// why_cpu_high 的一行:时间窗内一个组的 CPU 画像。
public struct GroupCpuInsight: Equatable, Sendable {
    public let groupID: String
    /// 展示名(groups 缺行时以组 ID 兜底——引擎启动早期缓存未写也不丢组)。
    public let name: String
    /// 分类(groups 缺行时 "unknown")。
    public let category: String
    public let projectRoot: String?
    /// 窗口内该组 `cpu_avg` 的均值(%,进程口径不含内核,同历史页 CPU 口径)。
    public let cpuAverage: Double
    /// 窗口内该组 `cpu_max` 的最大(%)。
    public let cpuPeak: Double
    /// 窗口内该组 `mem_max` 的最大(字节)。
    public let memoryMaxBytes: Int
    /// 窗口内最新一行的进程数。
    public let processCount: Int

    public init(
        groupID: String,
        name: String,
        category: String,
        projectRoot: String?,
        cpuAverage: Double,
        cpuPeak: Double,
        memoryMaxBytes: Int,
        processCount: Int
    ) {
        self.groupID = groupID
        self.name = name
        self.category = category
        self.projectRoot = projectRoot
        self.cpuAverage = cpuAverage
        self.cpuPeak = cpuPeak
        self.memoryMaxBytes = memoryMaxBytes
        self.processCount = processCount
    }
}

/// current_metrics 的取数结果:每类指标最新一行 + 时间戳;缺数据为 nil
/// (app 未运行 / 该指标未记录),调用方如实标注年龄、不伪造 0。
public struct LatestSnapshot: Equatable, Sendable {
    /// 一个指标的最新值与其行时间(epoch 秒)。
    public struct Gauge: Equatable, Sendable {
        public let value: Double
        public let atSeconds: Int

        public init(value: Double, atSeconds: Int) {
            self.value = value
            self.atSeconds = atSeconds
        }
    }

    /// 系统负载(system_min.load_avg,全部核含内核,菜单栏同口径)。
    public let systemLoad: Gauge?
    /// 网络(system_min 最新分钟行收发增量 ÷ 60,字节/秒;任一侧 NULL → nil)。
    public let networkBytesPerSec: Gauge?
    /// 磁盘(同上口径)。
    public let diskBytesPerSec: Gauge?
    /// CPU(sample_min 最新分钟行全组 `cpu_avg` 之和,进程口径)。
    public let cpuSumPercent: Gauge?
    /// 内存(sample_min 最新分钟行全组 `mem_max` 之和,字节)。
    public let memoryBytes: Gauge?
    /// 仪表窄表各键最新 avg(gauge_min;键 = `GaugeKey.rawValue`)。
    public let gauges: [String: Gauge]
    /// sample_min 最新行时间(库整体"最近落库"主口径)。
    public let newestSampleSeconds: Int?
    /// system_min 最新行时间。
    public let newestSystemSeconds: Int?

    public init(
        systemLoad: Gauge?,
        networkBytesPerSec: Gauge?,
        diskBytesPerSec: Gauge?,
        cpuSumPercent: Gauge?,
        memoryBytes: Gauge?,
        gauges: [String: Gauge],
        newestSampleSeconds: Int?,
        newestSystemSeconds: Int?
    ) {
        self.systemLoad = systemLoad
        self.networkBytesPerSec = networkBytesPerSec
        self.diskBytesPerSec = diskBytesPerSec
        self.cpuSumPercent = cpuSumPercent
        self.memoryBytes = memoryBytes
        self.gauges = gauges
        self.newestSampleSeconds = newestSampleSeconds
        self.newestSystemSeconds = newestSystemSeconds
    }
}

public enum InsightQuery {
    /// 时间窗 `[now − lookbackMinutes·60, now)` 内 `cpu_avg` 均值最高的
    /// `limit` 个组(sample_min LEFT JOIN groups)。窗口边界与历史页同源
    /// 整秒口径;空库/无窗口数据返回 `[]`。
    public static func topCpuGroups(
        limit: Int = 5,
        lookbackMinutes: Int = 10,
        now: Date,
        in db: Database
    ) throws -> [GroupCpuInsight] {
        let end = HistoryWindows.epochSeconds(of: now)
        let start = end - lookbackMinutes * 60
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT s.group_id,
                   COALESCE(g.name, s.group_id) AS name,
                   COALESCE(g.category, 'unknown') AS category,
                   g.project_root AS project_root,
                   AVG(s.cpu_avg) AS cpu_average,
                   MAX(s.cpu_max) AS cpu_peak,
                   MAX(s.mem_max) AS memory_max,
                   (
                       SELECT procs FROM sample_min AS latest
                       WHERE latest.group_id = s.group_id
                         AND latest.ts >= ? AND latest.ts < ?
                       ORDER BY latest.ts DESC LIMIT 1
                   ) AS process_count
            FROM sample_min AS s
            LEFT JOIN groups AS g ON g.group_id = s.group_id
            WHERE s.ts >= ? AND s.ts < ?
            GROUP BY s.group_id
            ORDER BY cpu_average DESC, s.group_id
            LIMIT ?
            """,
            arguments: [start, end, start, end, limit]
        )
        return rows.map { row in
            GroupCpuInsight(
                groupID: row["group_id"],
                name: row["name"],
                category: row["category"],
                projectRoot: row["project_root"],
                cpuAverage: row["cpu_average"] ?? 0,
                cpuPeak: row["cpu_peak"] ?? 0,
                memoryMaxBytes: row["memory_max"] ?? 0,
                processCount: row["process_count"] ?? 0
            )
        }
    }

    /// 各指标最新一行(全空库 = 全 nil + 双 newest 为 nil)。
    public static func latestSnapshot(now _: Date, in db: Database) throws -> LatestSnapshot {
        // system_min 最新行:net/disk 任一侧 NULL 的列不计(NULL 传染,同
        // HistoryQuery 口径);单分钟增量 ÷ 60 = 平均速率。
        var systemLoad: LatestSnapshot.Gauge?
        var network: LatestSnapshot.Gauge?
        var disk: LatestSnapshot.Gauge?
        var newestSystemSeconds: Int?
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT ts, load_avg, net_rx, net_tx, disk_read, disk_written FROM system_min ORDER BY ts DESC LIMIT 1"
        ) {
            let ts: Int = row["ts"]
            newestSystemSeconds = ts
            systemLoad = .init(value: row["load_avg"] ?? 0, atSeconds: ts)
            if let rx: Int = row["net_rx"], let tx: Int = row["net_tx"] {
                network = .init(value: Double(rx + tx) / 60, atSeconds: ts)
            }
            if let read: Int = row["disk_read"], let written: Int = row["disk_written"] {
                disk = .init(value: Double(read + written) / 60, atSeconds: ts)
            }
        }

        // sample_min 最新分钟行:全组求和(与历史页 CPU/内存两级聚合的内层同口径)。
        var cpuSum: LatestSnapshot.Gauge?
        var memory: LatestSnapshot.Gauge?
        var newestSampleSeconds: Int?
        if let ts = try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM sample_min") {
            newestSampleSeconds = ts
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT SUM(cpu_avg) AS cpu, SUM(mem_max) AS mem FROM sample_min WHERE ts = ?",
                arguments: [ts]
            ) {
                // 窗口有行但值列 NULL 不会发生(cpu_avg/mem_max NOT NULL);
                // SUM 无行返回 NULL → 0 兜底是可达不到的分支,保持简单。
                cpuSum = .init(value: row["cpu"] ?? 0, atSeconds: ts)
                memory = .init(value: Double(row["mem"] ?? 0), atSeconds: ts)
            }
        }

        // gauge_min 各键最新 avg(相关子查询取每键最大 ts 的行;avg 列 NULL
        // 不可能——仪表行落地即有值,防御取 max 兜底)。
        var gauges: [String: LatestSnapshot.Gauge] = [:]
        let gaugeRows = try Row.fetchAll(
            db,
            sql: """
            SELECT key, ts, COALESCE(avg, max) AS value FROM gauge_min AS g
            WHERE ts = (SELECT MAX(ts) FROM gauge_min WHERE key = g.key)
            """
        )
        for row in gaugeRows {
            let key: String = row["key"]
            let ts: Int = row["ts"]
            if let value: Double = row["value"] {
                gauges[key] = .init(value: value, atSeconds: ts)
            }
        }

        return LatestSnapshot(
            systemLoad: systemLoad,
            networkBytesPerSec: network,
            diskBytesPerSec: disk,
            cpuSumPercent: cpuSum,
            memoryBytes: memory,
            gauges: gauges,
            newestSampleSeconds: newestSampleSeconds,
            newestSystemSeconds: newestSystemSeconds
        )
    }
}
