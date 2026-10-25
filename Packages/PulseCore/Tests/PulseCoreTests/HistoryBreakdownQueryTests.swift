import GRDB
@testable import PulseCore
import XCTest

/// 历史页分项查询(p2-review/07,GLOSSARY「分项」):真 SQLite(内存库)+ 显式
/// 注入时间,缝 = HistoryQuery.series(metric:breakdown:…)。钉住:每个分项读
/// 对应列;功率合计口径与分项前逐位等价(COALESCE + FILTER,审计⑤);列为
/// NULL 的分钟如实空段、不伪造 0。视图(次级药丸条)走预览 + 手动验收。
final class HistoryBreakdownQueryTests: XCTestCase {
    /// 基准时刻:对齐到小时边界(分钟 / 5 分钟 / 小时桶边界在此重合)。
    private var base: Int {
        1_789_000_000 / 3600 * 3600
    }

    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try HistoryDatabase.openInMemory()
    }

    // MARK: 夹具:按 schema 直插传感器趋势列(绕过引擎管线,聚焦查询口径)

    private struct SensorRow {
        let ts: Int
        var tempAverage: Double?
        var tempMax: Double?
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var ram: Double?
        var soc: Double?
    }

    /// 窄表播种(p2-review/09):系统表只写基础行,仪表行进 gauge_*——平均键
    /// 写 avg 列、最热写 max 列,与存储层同形;缺席键不产行。
    private func insert(_ rows: [SensorRow], table: String = "system_min") throws {
        let gaugeTable = table == "system_min" ? "gauge_min" : "gauge_hour"
        try queue.write { db in
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO \(table) (ts, load_avg, load_max) VALUES (?, 1, 1)",
                    arguments: [row.ts]
                )
                let keys: [(String, Double?, Bool)] = [
                    ("temp_avg", row.tempAverage, false),
                    ("temp_max", row.tempMax, true),
                    ("pow_cpu", row.cpu, false),
                    ("pow_gpu", row.gpu, false),
                    ("pow_ane", row.ane, false),
                    ("pow_ram", row.ram, false),
                    ("pow_soc", row.soc, false),
                ]
                for (key, value, isMax) in keys {
                    guard let value else { continue }
                    try db.execute(
                        sql: "INSERT INTO \(gaugeTable) (ts, key, avg, max) VALUES (?, ?, ?, ?)",
                        arguments: [row.ts, key, isMax ? nil : value, isMax ? value : nil]
                    )
                }
            }
        }
    }

    private func series(
        _ metric: HistoryMetricKey,
        _ breakdown: HistoryBreakdown?,
        _ range: HistoryRange
    ) throws -> HistorySeries {
        try queue.read { db in
            try HistoryQuery.series(
                metric: metric,
                breakdown: breakdown,
                range: range,
                now: Date(timeIntervalSince1970: Double(base)),
                in: db
            )
        }
    }

    // MARK: 温度分项

    func testTemperatureHottestReadsTempMaxAndTakesBucketPeak() throws {
        // 分钟表两行落在 24 小时档的同一个 5 分钟桶:最热取桶内峰值(与小时
        // 汇总 MAX(temp_max) 同口径),CPU 均值仍取桶内均值。
        let start = base - 86400
        try insert([
            SensorRow(ts: start + 60, tempAverage: 40, tempMax: 70),
            SensorRow(ts: start + 120, tempAverage: 50, tempMax: 90),
        ])

        let hottest = try series(.temperature, .temperatureHottest, .day1)
        XCTAssertEqual(hottest.values[0], 90, "最热 = temp_max 桶内峰值")
        XCTAssertEqual(hottest.breakdown, .temperatureHottest)

        let average = try series(.temperature, .temperatureAverage, .day1)
        XCTAssertEqual(average.values[0], 45, "CPU 均值 = temp_avg 桶内均值")
    }

    // MARK: 功率分项

    func testEachPowerDomainReadsItsOwnColumn() throws {
        // 五路各取互异值:每个分项只读本域列;另一分钟只有 CPU 域(缺 ANE/RAM
        // 的芯片形状)→ 其余域该桶如实空段,不伪造 0。
        try insert([
            SensorRow(ts: base - 120, cpu: 2, gpu: 1, ane: 0.5, ram: 0.3, soc: 0.2),
            SensorRow(ts: base - 60, cpu: 12.5),
        ])
        let expected: [(PowerDomain, Double)] = [
            (.cpu, 2), (.gpu, 1), (.ane, 0.5), (.ram, 0.3), (.soc, 0.2),
        ]
        for (domain, watts) in expected {
            let curve = try series(.power, .powerDomain(domain), .hour1)
            XCTAssertEqual(curve.breakdown, .powerDomain(domain))
            XCTAssertEqual(try XCTUnwrap(curve.values[58]), watts, accuracy: 1e-9, "\(domain) 读本域列")
        }
        let cpu = try series(.power, .powerDomain(.cpu), .hour1)
        XCTAssertEqual(cpu.values[59], 12.5)
        for domain in [PowerDomain.gpu, .ane, .ram, .soc] {
            let curve = try series(.power, .powerDomain(domain), .hour1)
            XCTAssertNil(curve.values[59], "\(domain) 列 NULL 的分钟空段,不补零")
        }
    }

    func testPowerTotalKeepsCoalesceFilterSemanticsAndIsTheDefault() throws {
        // 回归(审计⑤口径):缺域按 0 计、不整行丢弃;五路全 NULL 的分钟剔除 →
        // 空段。显式「合计」与不传分项(默认)逐位相同。
        try insert([
            SensorRow(ts: base - 180, cpu: 2, gpu: 1, ane: 0.5, ram: 0.3, soc: 0.2),
            SensorRow(ts: base - 120, cpu: 2, soc: 0.5),
            SensorRow(ts: base - 60),
        ])
        let total = try series(.power, .powerTotal, .hour1)
        XCTAssertEqual(try XCTUnwrap(total.values[57]), 4.0, accuracy: 1e-9, "2+1+0.5+0.3+0.2")
        XCTAssertEqual(try XCTUnwrap(total.values[58]), 2.5, accuracy: 1e-9, "缺域按 0 计")
        XCTAssertNil(total.values[59], "五路全 NULL 的分钟空段")

        let implicit = try series(.power, nil, .hour1)
        XCTAssertEqual(implicit, total, "默认分项 = 合计,逐位等价")
        XCTAssertEqual(implicit.breakdown, .powerTotal)
    }

    func testBreakdownsReadHourTableForLongRanges() throws {
        // 7 天档读小时表:最热读小时行 temp_max、单域读小时行 pow_*。
        try insert(
            [SensorRow(ts: base - 3600, tempAverage: 41, tempMax: 88, cpu: 3, gpu: 7)],
            table: "system_hour"
        )
        let last = HistoryRange.days7.bucketCount - 1
        XCTAssertEqual(try series(.temperature, .temperatureHottest, .days7).values[last], 88)
        XCTAssertEqual(try series(.power, .powerDomain(.gpu), .days7).values[last], 7)
    }

    func testEngineSeriesForwardsBreakdown() async throws {
        // 页面经引擎 actor 查询:分项须透传到查询层,不被吞成默认。
        try insert([SensorRow(ts: base - 60, tempAverage: 47, tempMax: 81)])
        let engine = HistoryEngine(database: queue)
        let curve = await engine.series(
            metric: .temperature,
            breakdown: .temperatureHottest,
            range: .hour1,
            now: Date(timeIntervalSince1970: Double(base))
        )
        XCTAssertEqual(curve?.values[59], 81)
        XCTAssertEqual(curve?.breakdown, .temperatureHottest)
    }

    // MARK: 分项目录与容错

    func testBreakdownCatalogPerMetric() {
        XCTAssertEqual(HistoryMetricKey.temperature.breakdowns.map(\.title), ["CPU 均值", "全机最热"])
        XCTAssertEqual(
            HistoryMetricKey.power.breakdowns.map(\.title),
            ["合计", "CPU", "GPU", "ANE", "RAM", "SoC"]
        )
        XCTAssertEqual(HistoryMetricKey.temperature.defaultBreakdown, .temperatureAverage)
        XCTAssertEqual(HistoryMetricKey.power.defaultBreakdown, .powerTotal)
        for metric in HistoryMetricKey.allCases where metric != .temperature && metric != .power {
            XCTAssertTrue(metric.breakdowns.isEmpty, "\(metric) 无分项 → 不出次级条")
            XCTAssertNil(metric.defaultBreakdown)
        }
        for metric in HistoryMetricKey.allCases {
            for breakdown in metric.breakdowns {
                XCTAssertEqual(breakdown.metric, metric, "\(breakdown) 归属一致")
            }
            let ids = metric.breakdowns.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(metric) 分项 id 唯一")
        }
    }

    func testForeignBreakdownFallsBackToMetricDefault() throws {
        // 不属于本指标的分项(视图切主指标的瞬间可能带着旧分项)→ 回落默认,
        // 无分项的指标恒 nil——不会拿温度分项去读功率列。
        try insert([SensorRow(ts: base - 60, tempAverage: 47, tempMax: 80, cpu: 2)])
        let power = try series(.power, .temperatureHottest, .hour1)
        XCTAssertEqual(power.breakdown, .powerTotal)
        XCTAssertEqual(power.values[59], 2)
        let load = try series(.systemLoad, .powerTotal, .hour1)
        XCTAssertNil(load.breakdown)
        XCTAssertEqual(load.values[59], 1)
    }
}
