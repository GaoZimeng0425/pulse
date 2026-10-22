import GRDB
@testable import PulseCore
import XCTest

/// P2 传感器趋势量的历史接线(p2-sensors/08):仪表型样本 → 分钟聚合 →
/// system 表新列 → 序列查询。三段各测:rollup 缓冲聚合、feed 暂存/携带、
/// 引擎端到端落库 + 查询(真 SQLite 内存库,与 HistoryQueryTests 同款纪律)。
final class SensorHistoryWiringTests: XCTestCase {
    private var base: Int {
        1_789_000_000 / 3600 * 3600
    }

    // MARK: - rollup 缓冲:仪表聚合

    func testRollupAggregatesGaugesIntoMinuteRow() {
        // 一分钟内三个样本:温度均值取均、最热取最大、GPU 取均、五路各域独立取均。
        var buffer = MinuteRollupBuffer()
        let start = Date(timeIntervalSince1970: Double(base))
        for offset: TimeInterval in [0, 20, 40] {
            buffer.ingest(
                at: start.addingTimeInterval(offset),
                systemLoad: 10,
                groups: [],
                tempAverage: 45 + offset,
                tempMax: 50 + offset,
                gpuUtilization: 20 + offset,
                powerWatts: [.cpu: 2.0, .gpu: 1.0, .soc: 0.5] // ane/ram 缺席
            )
        }
        // 跨分钟触发冲刷。
        let flushed = buffer.ingest(
            at: start.addingTimeInterval(60),
            systemLoad: 10,
            groups: []
        )
        let aggregate = try? XCTUnwrap(flushed)
        XCTAssertEqual(aggregate?.tempAverage ?? -1, 45 + 20, accuracy: 0.001)
        XCTAssertEqual(aggregate?.tempMax, 90)
        XCTAssertEqual(aggregate?.gpuUtilization ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(aggregate?.powerWatts?.cpu ?? -1, 2.0, accuracy: 0.001)
        XCTAssertNil(aggregate?.powerWatts?.ane, "缺席域不伪造 0")
        XCTAssertNil(aggregate?.powerWatts?.ram)
        XCTAssertEqual(aggregate?.powerWatts?.total ?? -1, 3.5, accuracy: 0.001)
    }

    func testRollupGaugesStayNilWithoutSamples() {
        // 传感器缺席的分钟:仪表列全 nil(NULL 落库,查询空段)。
        var buffer = MinuteRollupBuffer()
        let start = Date(timeIntervalSince1970: Double(base))
        buffer.ingest(at: start, systemLoad: 10, groups: [])
        let flushed = buffer.ingest(at: start.addingTimeInterval(60), systemLoad: 10, groups: [])
        let aggregate = try? XCTUnwrap(flushed)
        XCTAssertNil(aggregate?.tempAverage)
        XCTAssertNil(aggregate?.tempMax)
        XCTAssertNil(aggregate?.gpuUtilization)
        XCTAssertNil(aggregate?.powerWatts)
    }

    // MARK: - feed:广播样本暂存 + 每轮携带

    func testFeedRecordsSensorSamplesAndCarriesIntoIngest() {
        // fresh 广播暂存,stale 不覆盖;takeIngest 整笔带走(轮间携带前推)。
        var feed = HistoryFeed()
        feed.recordGpu(.fresh(GpuReading.make(from: GpuRawReading(deviceUtilizationPercent: 42))))
        feed.recordSmc(.fresh(Self.smcReading(cpuAverage: 48, cpuHottest: 52, gpuHottest: 55, socHottest: 49)))
        feed.recordPower(.fresh(PowerReading(watts: [.cpu: 3, .ane: 0.4], takenAt: Date())))
        feed.recordGpu(.stale(GpuReading.make(from: GpuRawReading(deviceUtilizationPercent: 99))))

        let ingest = feed.takeIngest(from: Self.context(), at: Date())
        XCTAssertEqual(ingest.gpuUtilization, 42, "stale 重投不覆盖 fresh 值")
        XCTAssertEqual(ingest.tempAverage, 48)
        XCTAssertEqual(ingest.tempMax, 55, "全机最热 = cpu/gpu/soc 三最热取最大")
        XCTAssertEqual(ingest.powerWatts?[.cpu], 3)
        XCTAssertEqual(ingest.powerWatts?[.ane], 0.4)
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

    // MARK: - 引擎端到端:落库 → 序列查询

    func testEngineIngestWithGaugesFeedsNewSeries() async throws {
        // 引擎真库:两轮带仪表的 ingest(跨分钟冲刷)→ system_min 新列有值 →
        // 温度/GPU/功率序列出数;无样本分钟 → 空段不补零。
        let engine = try HistoryEngine(database: HistoryDatabase.openInMemory())
        let start = Date(timeIntervalSince1970: Double(base))
        await engine.ingest(
            at: start,
            systemLoad: 10,
            groups: [],
            displayNames: [:],
            lineage: LineageRegistry(),
            tempAverage: 47,
            tempMax: 51,
            gpuUtilization: 33,
            powerWatts: [.cpu: 2, .gpu: 1, .ane: 0.5, .ram: 0.3, .soc: 0.2]
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
        let gpu = await engine.series(metric: .gpu, range: .hour1, now: now)
        let power = await engine.series(metric: .power, range: .hour1, now: now)

        // 桶宽 60s;样本分钟落 index 58(base 对齐小时,窗口起点 base−3480),
        // 其后无样本分钟空段不补零。
        let temperatureValues = try XCTUnwrap(temperature).values
        XCTAssertEqual(temperatureValues[58], 47)
        XCTAssertNil(temperatureValues[59], "传感器缺席分钟空段不补零")

        let gpuValues = try XCTUnwrap(gpu).values
        XCTAssertEqual(gpuValues[58], 33)

        let powerValues = try XCTUnwrap(power).values
        XCTAssertEqual(try XCTUnwrap(powerValues[58]), 4.0, accuracy: 0.001, "五路合计 2+1+0.5+0.3+0.2")
    }
}
