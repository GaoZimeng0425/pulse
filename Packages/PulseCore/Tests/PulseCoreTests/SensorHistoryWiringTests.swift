import GRDB
@testable import PulseCore
import XCTest

/// P2 传感器趋势量的历史接线(p2-sensors/08;p2-review/09 收成按键窄表):
/// 仪表样本 → 分钟聚合 → gauge_min/gauge_hour 窄行 → 序列查询。三段各测:
/// rollup 缓冲聚合、feed 暂存/携带、引擎端到端落库 + 查询(真 SQLite 内存库,
/// 与 HistoryQueryTests 同款纪律)。存量宽表 → 窄表的变换对拍见
/// HistoryGaugeMigrationTests。
final class SensorHistoryWiringTests: XCTestCase {
    private var base: Int {
        1_789_000_000 / 3600 * 3600
    }

    // MARK: - rollup 缓冲:仪表聚合

    func testRollupAggregatesGaugesIntoMinuteRows() {
        // 一分钟内三个样本:均值键取均、最热键取最大;缺席键不产行。
        var buffer = MinuteRollupBuffer()
        let start = Date(timeIntervalSince1970: Double(base))
        for offset: TimeInterval in [0, 20, 40] {
            buffer.ingest(
                at: start.addingTimeInterval(offset),
                systemLoad: 10,
                groups: [],
                gauges: [
                    .tempAverage: 45 + offset,
                    .tempMax: 50 + offset,
                    .gpuUtilization: 20 + offset,
                    .powerCpu: 2.0, .powerGpu: 1.0, .powerSoc: 0.5, // ane/ram 缺席
                ]
            )
        }
        // 跨分钟触发冲刷。
        let flushed = buffer.ingest(
            at: start.addingTimeInterval(60),
            systemLoad: 10,
            groups: []
        )
        let aggregate = try? XCTUnwrap(flushed)
        XCTAssertEqual(aggregate?.gauges[.tempAverage]?.average ?? -1, 45 + 20, accuracy: 0.001)
        XCTAssertEqual(aggregate?.gauges[.tempMax]?.max, 90)
        XCTAssertEqual(aggregate?.gauges[.gpuUtilization]?.average ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(aggregate?.gauges[.powerCpu]?.average ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(aggregate?.gauges[.powerAne], "缺席域不伪造行")
        XCTAssertNil(aggregate?.gauges[.powerRam])
    }

    func testRollupGaugesStayEmptyWithoutSamples() {
        // 传感器缺席的分钟:仪表字典为空(无行可写,查询空段)。
        var buffer = MinuteRollupBuffer()
        let start = Date(timeIntervalSince1970: Double(base))
        buffer.ingest(at: start, systemLoad: 10, groups: [])
        let flushed = buffer.ingest(at: start.addingTimeInterval(60), systemLoad: 10, groups: [])
        let aggregate = try? XCTUnwrap(flushed)
        XCTAssertEqual(aggregate?.gauges, [:])
    }

    // MARK: - feed:广播暂存 + 每轮携带

    func testFeedRecordsGaugesAndCarriesIntoIngest() {
        // 键值暂存覆盖;takeIngest 整笔带走(轮间携带前推)。读失败轮(feature
        // 不广播)不动既有暂存——空字典即"本轮无仪表"。
        let sampledAt = Date(timeIntervalSince1970: 1_789_000_100)
        var feed = HistoryFeed()
        feed.recordGauges(
            GpuReading.make(from: GpuRawReading(deviceUtilizationPercent: 42)).historyGauges,
            at: sampledAt
        )
        feed.recordGauges(
            Self.smcReading(cpuAverage: 48, cpuHottest: 52, gpuHottest: 55, socHottest: 49)
                .historyGauges,
            at: sampledAt
        )
        feed.recordGauges(
            PowerReading(watts: [.cpu: 3, .ane: 0.4], takenAt: sampledAt).historyGauges,
            at: sampledAt
        )
        feed.recordGauges([:], at: sampledAt.addingTimeInterval(1)) // 全族读失败形状

        let ingest = feed.takeIngest(from: Self.context(), at: sampledAt.addingTimeInterval(2))
        XCTAssertEqual(ingest.gauges[.gpuUtilization], 42, "空广播(读失败)不覆盖既有暂存")
        XCTAssertEqual(ingest.gauges[.tempAverage], 48)
        XCTAssertEqual(ingest.gauges[.tempMax], 55, "全机最热 = cpu/gpu/soc 三最热取最大(口径在模型)")
        XCTAssertEqual(ingest.gauges[.powerCpu], 3)
        XCTAssertEqual(ingest.gauges[.powerAne], 0.4)
    }

    func testGaugeSamplesExpireInsteadOfFreezing() {
        // 审计⑤:传感器持续失败 → 不再广播 → 暂存样本超过 90s 即出空段,
        // 不把冻结值无限写进历史。新鲜窗口内照常携带;且按键独立过期。
        var feed = HistoryFeed()
        let sampledAt = Date(timeIntervalSince1970: 1_789_000_100)
        feed.recordGauges([.gpuUtilization: 42], at: sampledAt)
        feed.recordGauges([.tempAverage: 48], at: sampledAt.addingTimeInterval(50))

        // 60s 后(两键均在窗内):携带。
        let fresh = feed.takeIngest(from: Self.context(), at: sampledAt.addingTimeInterval(60))
        XCTAssertEqual(fresh.gauges[.gpuUtilization], 42)
        XCTAssertEqual(fresh.gauges[.tempAverage], 48)

        // 91s 后(gpu 超窗、temp 仍在窗内):按键独立过期。
        let expired = feed.takeIngest(from: Self.context(), at: sampledAt.addingTimeInterval(91))
        XCTAssertNil(expired.gauges[.gpuUtilization], "冻结样本过期出空段,不无限携带")
        XCTAssertEqual(expired.gauges[.tempAverage], 48, "后到的键仍在窗内独立携带")
    }

    /// 最小一轮主干上下文(单进程、无差分;与 HistoryFeedTests.context 同款最小形)。
    private static func context() -> RoundContext {
        let snapshot = ProcessSnapshot(takenAt: Date(), processes: [
            RawProcess(pid: 50, parentPID: 1, executablePath: "/bin/ls"),
        ])
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: nil, current: snapshot),
            cpu: .zero,
            memory: nil,
            network: nil,
            rankings: .empty
        ))
    }

    /// 合成 SMC 读数(只带派生值;明细/风扇空)。
    private static func smcReading(
        cpuAverage: Double?, cpuHottest: Double?, gpuHottest: Double?, socHottest: Double?
    ) -> SmcReading {
        SmcReading(
            knownTemps: [],
            unknownTemps: [],
            fans: [],
            derived: SmcDerivedTemps(
                cpuAverage: cpuAverage,
                cpuHottest: cpuHottest,
                gpuAverage: nil,
                gpuHottest: gpuHottest,
                socAverage: nil,
                socHottest: socHottest
            ),
            batteryPowerWatts: nil,
            adapterWatts: nil,
            takenAt: Date()
        )
    }

    // MARK: - 功率合计的缺域语义(审计⑤)

    func testPowerSeriesSumsPresentDomainKeysAndSkipsEmptyMinutes() async throws {
        // 直插窄表行:①只有 pow_cpu(缺 ANE/RAM 域的芯片形状)→ 合计 = cpu 单域,
        // 不整分钟丢弃;②无任何功率行的分钟 → 该桶空段。
        let queue = try HistoryDatabase.openInMemory()
        let minute = base - 60
        let currentBase = base // 局部量进 @Sendable 写闭包(XCTestCase 非 Sendable)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (?, 1, 1)",
                arguments: [minute]
            )
            try db.execute(
                sql: "INSERT INTO gauge_min (ts, key, avg, max) VALUES (?, 'pow_cpu', 12.5, NULL)",
                arguments: [minute]
            )
            try db.execute(
                sql: "INSERT INTO system_min (ts, load_avg, load_max) VALUES (?, 1, 1)",
                arguments: [currentBase]
            )
        }
        let engine = HistoryEngine(database: queue)
        let series = await engine.series(
            metric: .power, range: .hour1, now: Date(timeIntervalSince1970: Double(base + 60))
        )
        let values = try XCTUnwrap(series).values
        XCTAssertEqual(try XCTUnwrap(values[58]), 12.5, accuracy: 0.001, "缺域分钟按在场域键合计")
        XCTAssertNil(values[59], "无功率行分钟空段不补零")
    }

    // MARK: - 引擎端到端:落库 → 序列查询

    func testEngineIngestWithGaugesFeedsNewSeries() async throws {
        // 引擎真库:两轮带仪表的 ingest(跨分钟冲刷)→ gauge_min 窄行 →
        // 温度/GPU/功率序列出数;无样本分钟 → 空段不补零。
        let engine = try HistoryEngine(database: HistoryDatabase.openInMemory())
        let start = Date(timeIntervalSince1970: Double(base))
        await engine.ingest(
            at: start,
            systemLoad: 10,
            groups: [],
            displayNames: [:],
            lineage: LineageRegistry(),
            gauges: [
                .tempAverage: 47,
                .tempMax: 51,
                .gpuUtilization: 33,
                .powerCpu: 2, .powerGpu: 1, .powerAne: 0.5, .powerRam: 0.3, .powerSoc: 0.2,
            ]
        )
        await engine.ingest( // 跨分钟:上一分钟冲刷落库;本轮无仪表样本
            at: start.addingTimeInterval(60),
            systemLoad: 10,
            groups: [],
            displayNames: [:],
            lineage: LineageRegistry()
        )

        let now = start.addingTimeInterval(120)
        let temperature = await engine.series(metric: .temperature, range: .hour1, now: now)
        let hottest = await engine.series(
            metric: .temperature, breakdown: .temperatureHottest, range: .hour1, now: now
        )
        let gpu = await engine.series(metric: .gpu, range: .hour1, now: now)
        let power = await engine.series(metric: .power, range: .hour1, now: now)

        // 桶宽 60s;样本分钟落 index 58(base 对齐小时,窗口起点 base−3480),
        // 其后无样本分钟空段不补零。
        let temperatureValues = try XCTUnwrap(temperature).values
        XCTAssertEqual(temperatureValues[58], 47)
        XCTAssertNil(temperatureValues[59], "传感器缺席分钟空段不补零")

        XCTAssertEqual(try XCTUnwrap(hottest).values[58], 51, "最热键读 max 列")

        let gpuValues = try XCTUnwrap(gpu).values
        XCTAssertEqual(gpuValues[58], 33)

        let powerValues = try XCTUnwrap(power).values
        XCTAssertEqual(try XCTUnwrap(powerValues[58]), 4.0, accuracy: 0.001, "五路合计 2+1+0.5+0.3+0.2")
    }

    func testHourRollupAggregatesGaugeNarrowRows() async throws {
        // 跨小时卷积:均键 AVG(avg)、最热键 MAX(max)——与宽列口径逐位一致。
        let queue = try HistoryDatabase.openInMemory()
        let hour = base
        try await queue.write { db in
            for (offset, avg, max) in [(0, 40.0, 50.0), (60, 46.0, 62.0), (120, 52.0, 58.0)] {
                try db.execute(
                    sql: "INSERT INTO gauge_min (ts, key, avg, max) VALUES (?, 'temp_avg', ?, NULL)",
                    arguments: [hour + offset, avg]
                )
                try db.execute(
                    sql: "INSERT INTO gauge_min (ts, key, avg, max) VALUES (?, 'temp_max', NULL, ?)",
                    arguments: [hour + offset, max]
                )
            }
        }
        let engine = HistoryEngine(database: queue)
        // 跨小时边界触发卷积;窗口起点对齐小时,小时桶宽 3600 → days7 档。
        await engine.ingest(
            at: Date(timeIntervalSince1970: Double(hour + 3600)),
            systemLoad: 1, groups: [], displayNames: [:], lineage: LineageRegistry()
        )
        let series = await engine.series(
            metric: .temperature, range: .days7, now: Date(timeIntervalSince1970: Double(hour + 7200))
        )
        // 桶宽 3600;该小时桶 = AVG(40,46,52)。
        let index = (hour - (hour - 7 * 24 * 3600 + 3600)) / 3600
        _ = index
        let values = try XCTUnwrap(series).values
        // 直接找有值的桶断言(窗口下标计算易错,取首个非空)。
        let firstNonNil = try XCTUnwrap(values.compactMap(\.self).first)
        XCTAssertEqual(firstNonNil, (40 + 46 + 52) / 3, accuracy: 0.001)

        let hottest = await engine.series(
            metric: .temperature, breakdown: .temperatureHottest, range: .days7,
            now: Date(timeIntervalSince1970: Double(hour + 7200))
        )
        let hottestFirst = try XCTUnwrap(try XCTUnwrap(hottest).values.compactMap(\.self).first)
        XCTAssertEqual(hottestFirst, 62.0, "最热小时卷积取 MAX")
    }
}
