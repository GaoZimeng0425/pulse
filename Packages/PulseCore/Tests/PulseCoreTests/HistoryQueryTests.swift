import GRDB
@testable import PulseCore
import XCTest

/// 历史页查询层(工单 04):真 SQLite(内存库)+ 显式注入时间(spec 测试
/// 决策:历史库不设缝,聚合查询打真 SQLite)。缝 = HistoryQuery.series——
/// 时间范围 → ts 界与桶网格、降采样分桶、空段留缺不补零、五指标与库六表
/// 的取数口径。UI(历史页)不单测,走预览 + 真机验收。
final class HistoryQueryTests: XCTestCase {
    /// 基准时刻:对齐到小时边界(分钟 / 5 分钟 / 小时桶边界在此重合,
    /// 槽位断言无歧义)。
    private var base: Int {
        1_789_000_000 / 3600 * 3600
    }

    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try HistoryDatabase.openInMemory()
    }

    // MARK: 夹具:按 schema 直插行(绕过引擎管线,聚焦查询口径本身)

    private func insertSystemMinutes(
        _ rows: [(ts: Int, load: Double, rx: Int?, tx: Int?, read: Int?, written: Int?)]
    ) throws {
        try queue.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO system_min
                        (ts, load_avg, load_max, net_rx, net_tx, disk_read, disk_written)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [row.ts, row.load, row.load, row.rx, row.tx, row.read, row.written]
                )
            }
        }
    }

    private func insertSystemHours(_ rows: [(ts: Int, load: Double)]) throws {
        try queue.write { db in
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO system_hour (ts, load_avg, load_max) VALUES (?, ?, ?)",
                    arguments: [row.ts, row.load, row.load]
                )
            }
        }
    }

    private func insertGroupMinutes(
        _ rows: [(ts: Int, group: String, cpu: Double, mem: Int)]
    ) throws {
        try queue.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO sample_min
                        (ts, group_id, cpu_avg, cpu_max, mem_max, procs)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [row.ts, row.group, row.cpu, row.cpu, row.mem, 1]
                )
            }
        }
    }

    private func insertGroupHours(
        _ rows: [(ts: Int, group: String, cpu: Double)]
    ) throws {
        try queue.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO sample_hour (ts, group_id, cpu_avg, cpu_max, mem_max, procs)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [row.ts, row.group, row.cpu, row.cpu, 0, 1]
                )
            }
        }
    }

    /// 以 base 为"现在"查一条曲线(窗口 [base−span, base))。
    private func series(
        _ metric: HistoryMetricKey,
        _ range: HistoryRange
    ) throws -> HistorySeries {
        try series(metric, range, now: base)
    }

    private func series(
        _ metric: HistoryMetricKey,
        _ range: HistoryRange,
        now: Int
    ) throws -> HistorySeries {
        try queue.read { db in
            try HistoryQuery.series(
                metric: metric,
                range: range,
                now: Date(timeIntervalSince1970: Double(now)),
                in: db
            )
        }
    }

    /// 有数据槽位的取数(断言辅助:缺槽在此显式炸出,正文只写期望值)。
    private func slot(
        _ curve: HistorySeries,
        _ index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        try XCTUnwrap(curve.values[index], "槽 \(index) 应有数据", file: file, line: line)
    }

    // MARK: 时间范围 → ts 界与桶网格

    func testRangeBucketGridAlignsToBoundsAndCapsPointCount() {
        let table: [(range: HistoryRange, span: Int, bucket: Int)] = [
            (.hour1, 3600, 60),
            (.day1, 86400, 300),
            (.days7, 7 * 86400, 3600),
            (.days30, 30 * 86400, 3600),
        ]
        for entry in table {
            let (start, end) = entry.range.bounds(now: Date(timeIntervalSince1970: Double(base)))
            XCTAssertEqual(end % entry.bucket, 0, "\(entry.range): end 对齐桶边界")
            XCTAssertEqual(end - start, entry.span, "\(entry.range): 窗长")
            XCTAssertEqual(entry.range.bucketSeconds, entry.bucket, "\(entry.range): 桶宽")
            XCTAssertEqual(entry.range.bucketCount, entry.span / entry.bucket, "\(entry.range): 桶数")
            XCTAssertTrue(entry.range.readsHourTable == (entry.bucket == 3600), "\(entry.range): 表档")
        }
        // spec:24 小时读分钟表但降采样到 ≤300 点再画。
        XCTAssertLessThanOrEqual(HistoryRange.day1.bucketCount, 300)
        XCTAssertEqual(HistoryRange.day1.bucketCount, 288)
    }

    // MARK: 空段留缺不补零(User Story 8)

    func testMinuteGapStaysEmptyNotZeroFilled() throws {
        // 分钟行缺一档(原点 57 与 59 有行,58 无行):58 号桶留 nil,
        // 不补零不连线——曲线分段绘制、统计只数有数据的桶。
        try insertSystemMinutes([
            (ts: base - 180, load: 30, rx: nil, tx: nil, read: nil, written: nil),
            (ts: base - 60, load: 70, rx: nil, tx: nil, read: nil, written: nil),
        ])
        let curve = try series(.systemLoad, .hour1)

        XCTAssertEqual(curve.values.count, 60)
        XCTAssertEqual(try slot(curve, 57), 30)
        XCTAssertNil(curve.values[58], "缺口桶 = nil(留缺,不补零)")
        XCTAssertEqual(try slot(curve, 59), 70)
        XCTAssertEqual(curve.segments(), [[30], [70]], "缺口两侧断成两段")
        let stats = try XCTUnwrap(curve.statistics())
        XCTAssertEqual(stats.average, 50, accuracy: 0.001, "统计只数有数据的桶")
        XCTAssertEqual(stats.peak, 70)
    }

    func testEmptyDatabaseYieldsAllEmptySeries() throws {
        let curve = try series(.cpu, .hour1)
        XCTAssertTrue(curve.isEmpty)
        XCTAssertEqual(curve.values, [Double?](repeating: nil, count: 60))
        XCTAssertNil(curve.statistics())
        XCTAssertTrue(curve.segments().isEmpty)
    }

    func testRowsOutsideWindowAreExcluded() throws {
        // 窗外行(早于 start / 晚于 end)不进网格:窗口口径是 [start, end)。
        try insertSystemMinutes([
            (ts: base - 3600 - 60, load: 111, rx: nil, tx: nil, read: nil, written: nil),
            (ts: base + 60, load: 222, rx: nil, tx: nil, read: nil, written: nil),
        ])
        let curve = try series(.systemLoad, .hour1)
        XCTAssertTrue(curve.isEmpty, "窗外行不计入")
        XCTAssertEqual(curve.startSeconds, base - 3600)
        XCTAssertEqual(curve.endSeconds, base)
    }

    // MARK: 降采样分桶(24 小时:分钟行 → 5 分钟桶)

    func testTwentyFourHoursDownsamplesMinutesIntoFiveMinuteBuckets() throws {
        let start = base - 86400
        try insertSystemMinutes([
            (ts: start + 60, load: 10, rx: nil, tx: nil, read: nil, written: nil),
            (ts: start + 120, load: 30, rx: nil, tx: nil, read: nil, written: nil),
            (ts: start + 180, load: 50, rx: nil, tx: nil, read: nil, written: nil),
            (ts: start + 360, load: 999, rx: nil, tx: nil, read: nil, written: nil),
        ])
        let curve = try series(.systemLoad, .day1)

        XCTAssertEqual(curve.values.count, 288)
        XCTAssertEqual(try slot(curve, 0), 30, "桶 0 内三行分钟均值 = 30")
        XCTAssertEqual(try slot(curve, 1), 999, "下一桶独立")
    }

    // MARK: 指标取数口径(与库六表对应)

    func testCpuSumsAllGroupsPerMinuteThenAveragesWithinBucket() throws {
        // CPU 口径:对组级表先按 ts 全组求和,再桶内取均——桶内各行组数
        // 不同也不歪(GLOSSARY 组 CPU% 与系统负载是两个口径,查询只管前者)。
        try insertGroupMinutes([
            (ts: base - 120, group: "g1", cpu: 10, mem: 0),
            (ts: base - 120, group: "g2", cpu: 30, mem: 0),
            (ts: base - 60, group: "g1", cpu: 20, mem: 0),
            (ts: base - 60, group: "g2", cpu: 40, mem: 0),
        ])
        let curve = try series(.cpu, .hour1)
        XCTAssertEqual(try slot(curve, 58), 40)
        XCTAssertEqual(try slot(curve, 59), 60)
    }

    func testMemorySumsGroupMemoryPeaksPerMinute() throws {
        // 内存口径:全组 mem_max 按 ts 求和(库无系统级内存列,app 归因视角)。
        try insertGroupMinutes([
            (ts: base - 60, group: "g1", cpu: 1, mem: 100),
            (ts: base - 60, group: "g2", cpu: 2, mem: 250),
        ])
        let curve = try series(.memory, .hour1)
        XCTAssertEqual(try slot(curve, 59), 350)
    }

    func testNetworkAndDiskStayEmptyWhileColumnsAreNull() throws {
        // 本阶段 system 表 net/disk 四列恒空(工单 06 起才有数据):
        // 网络/磁盘曲线全空段,不伪造 0——页面显示"暂无数据"。
        try insertSystemMinutes([
            (ts: base - 60, load: 5, rx: nil, tx: nil, read: nil, written: nil),
        ])
        XCTAssertTrue(try series(.network, .hour1).isEmpty)
        XCTAssertTrue(try series(.disk, .hour1).isEmpty)
    }

    func testNetworkValueConvertsBucketBytesToBytesPerSecond() throws {
        // 网络口径:每行 = 该分钟收发增量合计;曲线值 = 桶内合计 ÷ 桶宽 =
        // 平均速率(字节/秒),跨范围语义一致。
        try insertSystemMinutes([
            (ts: base - 120, load: 1, rx: 100, tx: 50, read: nil, written: nil),
            (ts: base - 60, load: 1, rx: 600, tx: 300, read: nil, written: nil),
        ])
        let curve = try series(.network, .hour1)
        XCTAssertEqual(try slot(curve, 58), 2.5, accuracy: 0.001)
        XCTAssertEqual(try slot(curve, 59), 15.0, accuracy: 0.001)
    }

    func testDiskAggregatesReadAndWrittenToBytesPerSecond() throws {
        try insertSystemMinutes([
            (ts: base - 60, load: 1, rx: nil, tx: nil, read: 1200, written: 600),
        ])
        let curve = try series(.disk, .hour1)
        XCTAssertEqual(try slot(curve, 59), 30.0, accuracy: 0.001, "(1200+600)/60 = 30 B/s")
    }

    func testSevenAndThirtyDayRangesReadHourTables() throws {
        // 7/30 天读小时表:小时行即桶;分钟行不进这两档。
        try insertSystemHours([(ts: base - 3600, load: 42)])
        try insertSystemMinutes([
            (ts: base - 60, load: 99, rx: nil, tx: nil, read: nil, written: nil),
        ])
        let week = try series(.systemLoad, .days7)
        let month = try series(.systemLoad, .days30)
        XCTAssertEqual(week.values.count, 168)
        XCTAssertEqual(month.values.count, 720)
        XCTAssertEqual(try slot(week, 167), 42, "7 天窗最后一个小时桶")
        XCTAssertEqual(try slot(month, 719), 42, "30 天窗最后一个小时桶")
        XCTAssertNil(week.values[59], "分钟行不漏进小时档")
    }

    func testGroupMetricsAggregateHourTableForLongRanges() throws {
        // 长档的组级指标:小时表先按 ts 全组求和,再桶内取均。
        try insertGroupHours([
            (ts: base - 3600, group: "g1", cpu: 5),
            (ts: base - 3600, group: "g2", cpu: 7),
        ])
        let curve = try series(.cpu, .days7)
        XCTAssertEqual(try slot(curve, 167), 12)
    }

    // MARK: 引擎入口(actor 后台执行)

    func testEngineSeriesQueriesOnActorAndMatchesDirectQuery() async throws {
        let engine = HistoryEngine(database: queue) // 启动补卷积跑在空库上,无副作用
        try insertSystemMinutes([
            (ts: base - 60, load: 30, rx: nil, tx: nil, read: nil, written: nil),
        ])
        let viaEngine = await engine.series(
            metric: .systemLoad,
            range: .hour1,
            now: Date(timeIntervalSince1970: Double(base))
        )
        let direct = try series(.systemLoad, .hour1)
        XCTAssertEqual(viaEngine, direct)
    }

    func testEngineSeriesReturnsNilWhenDatabaseUnavailable() async {
        let engine = HistoryEngine(database: nil)
        let curve = await engine.series(
            metric: .systemLoad, range: .hour1, now: Date(timeIntervalSince1970: Double(base))
        )
        XCTAssertNil(curve, "库不可用 → nil,页面按占位处理(历史是旁路)")
    }

    // MARK: 文案与令牌(纯值)

    func testMetricTitlesAccentsAndStatisticFormatting() {
        // P2 传感器趋势量(p2-sensors/08):温度/GPU/功率三键排在网络磁盘之后。
        XCTAssertEqual(
            HistoryMetricKey.allCases.map(\.title),
            ["系统负载", "CPU", "内存", "网络", "磁盘", "温度", "GPU", "功率"]
        )
        XCTAssertEqual(HistoryMetricKey.systemLoad.accent, .cpu)
        XCTAssertEqual(HistoryMetricKey.cpu.accent, .cpu)
        XCTAssertEqual(HistoryMetricKey.memory.accent, .memory)
        XCTAssertEqual(HistoryMetricKey.network.accent, .network)
        XCTAssertEqual(HistoryMetricKey.disk.accent, .disk)
        XCTAssertEqual(HistoryMetricKey.temperature.accent, .sensors)
        XCTAssertEqual(HistoryMetricKey.gpu.accent, .gpu)
        XCTAssertEqual(HistoryMetricKey.power.accent, .gpu)
        XCTAssertEqual(HistoryMetricKey.temperature.statisticText(48.26), "48.3°C")
        XCTAssertEqual(HistoryMetricKey.power.statisticText(12.34), "12.3 W")
        XCTAssertEqual(HistoryMetricKey.systemLoad.statisticText(42.4), "42%")
        XCTAssertEqual(HistoryMetricKey.cpu.statisticText(445.2), "445%")
        XCTAssertEqual(HistoryMetricKey.memory.statisticText(2_400_000_000), "2.4 GB")
        XCTAssertEqual(HistoryMetricKey.network.statisticText(12400), "12.4 KB/s")
        XCTAssertEqual(HistoryMetricKey.disk.statisticText(12400), "12.4 KB/s")
    }

    func testRangeTitlesAreChinese() {
        XCTAssertEqual(
            HistoryRange.allCases.map(\.title),
            ["近 1 小时", "24 小时", "7 天", "30 天"]
        )
    }
}
