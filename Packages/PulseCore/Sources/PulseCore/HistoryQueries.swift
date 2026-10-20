import Foundation
import GRDB

// MARK: - 历史页查询(工单 04)
// 时间范围 → ts 界与桶网格、降采样分桶、空段留缺不补零、五指标与库六表
// 的取数口径,全部钉在这一份里(单测见 HistoryQueryTests,真 SQLite);
// 历史页 UI 只消费 HistorySeries,不碰 SQL。

/// 历史页时间范围(工单 04):近 1 小时 / 24 小时 / 7 天 / 30 天。
/// 桶宽即"降采样"口径:近 1 小时读分钟表 60 点;24 小时读分钟表、按 5 分钟
/// 桶聚合成 288 点(≤300 再画);7/30 天读小时表 168/720 点(小时行即桶)。
/// 各档窗长都是桶宽整数倍 → 桶网格天然对齐。
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour1
    case day1
    case days7
    case days30

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hour1: "近 1 小时"
        case .day1: "24 小时"
        case .days7: "7 天"
        case .days30: "30 天"
        }
    }

    /// 展示窗总长(秒)。
    public var spanSeconds: Int {
        switch self {
        case .hour1: 3600
        case .day1: 24 * 3600
        case .days7: 7 * 24 * 3600
        case .days30: 30 * 24 * 3600
        }
    }

    /// 降采样桶宽(秒)。
    public var bucketSeconds: Int {
        switch self {
        case .hour1: 60
        case .day1: 300
        case .days7, .days30: 3600
        }
    }

    /// 7/30 天读小时表(工单 04);其余读分钟表。
    public var readsHourTable: Bool {
        switch self {
        case .days7, .days30: true
        case .hour1, .day1: false
        }
    }

    /// 桶数(= 曲线点数上限)。
    public var bucketCount: Int { spanSeconds / bucketSeconds }

    /// 查询 ts 界 `[start, end)`:end 对齐桶边界向下取整(now 所在的未满桶
    /// 不画半桶),start = end − span(整倍数 → start 也对齐)。
    /// 对齐与 HistoryWindows 同一口径(整秒 epoch 与本地时区无关)。
    public func bounds(now: Date) -> (start: Int, end: Int) {
        let bucket = bucketSeconds
        let end = HistoryWindows.epochSeconds(of: now) / bucket * bucket
        return (end - spanSeconds, end)
    }
}

/// 历史页五类指标(工单 04)与库六表的取数口径(表档/列/聚合一一对应):
/// - 系统负载:system 表 `load_avg`——全部核占用率 0–100、含内核,菜单栏
///   同口径(GLOSSARY「系统 CPU 负载」);
/// - CPU:组级表全组 `cpu_avg` 先按 ts 求和、桶内取均——组 CPU% 之和,
///   进程口径不含内核(GLOSSARY「组 CPU%」;与系统负载是两个口径,页面
///   文案区分,工单票面既定);
/// - 内存:组级表全组 `mem_max` 先按 ts 求和、桶内取均——全部组内存峰值
///   合计(App 归因视角;库无系统级内存列,如实按此口径展示);
/// - 网络 / 磁盘:system 表每行增量(`net_rx + net_tx`、`disk_read +
///   disk_written`)桶内求和,换算平均速率(字节/秒)——工单 06 起才有
///   数据,本阶段恒 NULL → 全空段,页面显示"暂无数据"不伪造 0。
public enum HistoryMetricKey: String, CaseIterable, Identifiable, Sendable {
    case systemLoad
    case cpu
    case memory
    case network
    case disk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemLoad: "系统负载"
        case .cpu: "CPU"
        case .memory: "内存"
        case .network: "网络"
        case .disk: "磁盘"
        }
    }

    /// 图表与选择器强调色(复用 MetricAccent 令牌,工单 04 验收:浅深色都对
    /// ——令牌表自带动全身)。
    public var accent: Metric {
        switch self {
        case .systemLoad, .cpu: .cpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        }
    }

    /// 读系统级表(system_*)还是组级表(sample_*)。
    public var readsSystemTables: Bool {
        switch self {
        case .systemLoad, .network, .disk: true
        case .cpu, .memory: false
        }
    }

    /// 页面脚注(口径说明,GLOSSARY 两口径/占位语义的展示出口)。
    public var caption: String {
        switch self {
        case .systemLoad: "系统 CPU 负载:全部核占用率,内核与 root 计入(菜单栏同口径)"
        case .cpu: "全部组 CPU% 之和:进程口径不含内核;与系统负载是两个口径"
        case .memory: "全部组内存峰值之和(App 归因视角;系统级未计入)"
        case .network: "收发合计平均速率;工单 06 起开始记录"
        case .disk: "读写合计平均速率;工单 06 起开始记录"
        }
    }

    /// 统计行数字文案:负载/CPU 百分比、内存字节、网络/磁盘速率——格式化
    /// 全部走 PulseFormat 同源出口,与实时页不会差一个字。
    public func statisticText(_ value: Double) -> String {
        switch self {
        case .systemLoad, .cpu: PulseFormat.cpuPercent(value)
        case .memory: PulseFormat.memory(UInt64(value.rounded()))
        case .network, .disk: PulseFormat.diskRate(value)
        }
    }
}

/// 一条历史曲线:固定桶网格上的值。`nil` = 该桶无行(app 未运行 / 该指标
/// 未记录)——留缺不补零(spec User Story 8);曲线分段绘制,统计只数
/// 有数据的桶。
public struct HistorySeries: Equatable, Sendable {
    public let metric: HistoryMetricKey
    public let range: HistoryRange
    /// 网格起点(epoch 秒,桶对齐;= range.bounds(now:).start)。
    public let startSeconds: Int
    public let bucketSeconds: Int
    /// 桶值,长度恒 = range.bucketCount。
    public let values: [Double?]

    public var endSeconds: Int { startSeconds + values.count * bucketSeconds }

    /// 有数据的桶数。
    public var filledCount: Int { values.lazy.compactMap { $0 }.count }

    public var isEmpty: Bool { filledCount == 0 }

    /// 连续非空段(曲线分笔绘制用):段间空桶断线,不跨缺连线。
    public func segments() -> [[Double]] {
        var segments: [[Double]] = []
        var current: [Double] = []
        for value in values {
            if let value {
                current.append(value)
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// 窗口统计(仅非空桶):均值 / 峰值;全空 → nil。
    public func statistics() -> (average: Double, peak: Double)? {
        let filled = values.compactMap { $0 }
        guard !filled.isEmpty else { return nil }
        let total = filled.reduce(0.0, +)
        return (total / Double(filled.count), filled.max() ?? 0)
    }

    public init(
        metric: HistoryMetricKey,
        range: HistoryRange,
        startSeconds: Int,
        bucketSeconds: Int,
        values: [Double?]
    ) {
        self.metric = metric
        self.range = range
        self.startSeconds = startSeconds
        self.bucketSeconds = bucketSeconds
        self.values = values
    }
}

/// 查询执行(真 SQLite,测试不设缝):同步、直接给 `Database`——线程由
/// 调用方决定,app 侧经 `HistoryEngine.series`(actor)在后台执行。
public enum HistoryQuery {
    public static func series(
        metric: HistoryMetricKey,
        range: HistoryRange,
        now: Date,
        in db: Database
    ) throws -> HistorySeries {
        let (start, end) = range.bounds(now: now)
        let bucket = range.bucketSeconds
        let table = range.readsHourTable
            ? (metric.readsSystemTables ? "system_hour" : "sample_hour")
            : (metric.readsSystemTables ? "system_min" : "sample_min")

        // 表名 / 列名 / 桶宽全部来自封闭枚举常量(非用户输入),纯 Swift 插值
        // 拼进语句;时间界走绑定参数。net/disk 增量列任一侧 NULL 的行不计
        // (NULL 传染)——全 NULL 的桶 SUM 为 NULL,落网格即空段,不伪造 0。
        let sql: String
        switch metric {
        case .systemLoad:
            sql = """
                SELECT ts / \(bucket) * \(bucket) AS bucket, AVG(load_avg) AS value
                FROM \(table) WHERE ts >= ? AND ts < ?
                GROUP BY bucket ORDER BY bucket
                """
        case .network:
            sql = """
                SELECT ts / \(bucket) * \(bucket) AS bucket, SUM(net_rx + net_tx) AS value
                FROM \(table) WHERE ts >= ? AND ts < ?
                GROUP BY bucket ORDER BY bucket
                """
        case .disk:
            sql = """
                SELECT ts / \(bucket) * \(bucket) AS bucket,
                       SUM(disk_read + disk_written) AS value
                FROM \(table) WHERE ts >= ? AND ts < ?
                GROUP BY bucket ORDER BY bucket
                """
        case .cpu, .memory:
            // 组级指标两级聚合:内层按 ts 对全组求和(每分钟/每小时一行),
            // 外层桶内取均——桶内各分钟组数不同也不会歪。组级磁盘两列本阶段
            // 恒空,不在查询面里。
            let column = metric == .cpu ? "cpu_avg" : "mem_max"
            sql = """
                SELECT ts / \(bucket) * \(bucket) AS bucket, AVG(per_period.total) AS value
                FROM (
                    SELECT ts, SUM(\(column)) AS total
                    FROM \(table) WHERE ts >= ? AND ts < ?
                    GROUP BY ts
                ) AS per_period
                GROUP BY ts / \(bucket) * \(bucket)
                ORDER BY bucket
                """
        }

        var values = [Double?](repeating: nil, count: range.bucketCount)
        let rows = try Row.fetchAll(db, sql: sql, arguments: [start, end])
        for row in rows {
            let bucketStart: Int = row["bucket"]
            guard let raw: Double = row["value"] else { continue } // NULL 列 → 空段
            let offset = bucketStart - start
            guard offset >= 0, offset < range.spanSeconds, offset % bucket == 0 else { continue }
            let index = offset / bucket
            // 网络/磁盘:桶内字节合计 ÷ 桶宽 = 平均速率(字节/秒),跨范围语义
            // 一致;其余口径原值(负载/CPU 百分比、内存字节)。
            let value: Double
            switch metric {
            case .network, .disk: value = raw / Double(bucket)
            default: value = raw
            }
            values[index] = value
        }
        return HistorySeries(
            metric: metric,
            range: range,
            startSeconds: start,
            bucketSeconds: bucket,
            values: values
        )
    }
}

// MARK: - 引擎入口(actor 后台执行,工单 04 验收:查询走后台队列不掉帧)

extension HistoryEngine {
    /// 历史页查询:引擎 actor 上执行 = 不占主线程(spec User Story 10);
    /// 失败返回 nil(历史是旁路,查询失败也不打断页面),日志走读路径健康状态沿
    /// (只在翻转时记,arch-review-2026-10-18/03 乙6)——页面每分钟重查,逐次记会刷屏。
    /// 库不可用同样返回 nil,页面按占位处理。
    public func series(
        metric: HistoryMetricKey,
        range: HistoryRange,
        now: Date
    ) async -> HistorySeries? {
        guard let database else { return nil }
        do {
            // GRDB 的 read 在 async 上下文走 async 重载:闭包照旧同步跑在
            // 库队列上,await 只挂起本 actor 任务(查询在后台队列,工单 04 验收)。
            let series = try await database.read { db in
                try HistoryQuery.series(metric: metric, range: range, now: now, in: db)
            }
            noteReadSuccess()
            return series
        } catch {
            noteReadFailure("历史页查询失败", error)
            return nil
        }
    }
}
