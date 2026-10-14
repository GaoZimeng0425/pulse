import XCTest
@testable import Pulse

/// 接缝:采样历史环形缓冲(工单 P0.6-01,纯逻辑)。
/// 固定容量、随采样轮推进、时间序读取、avg/peak/min 按需折叠——
/// 期望值全部是手工推演的字面量;组消失即停止追加并逐出的口径也在本接缝验证。
final class SampleHistoryTests: XCTestCase {

    // MARK: - RingSeries:容量与时间序

    func testEmptySeriesHasNoValuesAndNoStatistics() {
        // 零轮采样:序列为空,统计不存在(不伪造 0)。
        let series = RingSeries<Double>(capacity: 3)

        XCTAssertTrue(series.values.isEmpty)
        XCTAssertEqual(series.count, 0)
        XCTAssertNil(series.statistics)
    }

    func testValuesStayChronologicalBelowCapacity() {
        // 未满容量:按追加顺序读回(旧 → 新),统计覆盖全部样本。
        var series = RingSeries<Double>(capacity: 5)
        [10, 20, 30].forEach { series.append($0) }

        XCTAssertEqual(series.values, [10, 20, 30])
        XCTAssertEqual(series.count, 3)
    }

    func testFullSeriesEvictsOldest() {
        // 容量 3,追加 4 个:最旧的 10 被覆盖,窗口 = [20, 30, 40]。
        var series = RingSeries<Double>(capacity: 3)
        [10, 20, 30, 40].forEach { series.append($0) }

        XCTAssertEqual(series.values, [20, 30, 40])
        XCTAssertEqual(series.count, 3)
    }

    func testLongSequenceKeepsOnlyRecentWindow() {
        // 追加 1...8、容量 5:窗口 = [4, 5, 6, 7, 8],旧值整体滚出。
        var series = RingSeries<Double>(capacity: 5)
        (1...8).forEach { series.append(Double($0)) }

        XCTAssertEqual(series.values, [4, 5, 6, 7, 8])
    }

    // MARK: - RingSeries:avg/peak/min 折叠

    func testStatisticsFoldAveragePeakMinimum() {
        // [10, 20, 30]:均值 20、峰值 30、谷值 10、样本数 3。
        var series = RingSeries<Double>(capacity: 5)
        [10, 20, 30].forEach { series.append($0) }

        let stats = series.statistics
        XCTAssertEqual(stats?.count, 3)
        XCTAssertEqual(stats?.average ?? 0, 20, accuracy: 0.0001)
        XCTAssertEqual(stats?.peak ?? 0, 30, accuracy: 0.0001)
        XCTAssertEqual(stats?.minimum ?? 0, 10, accuracy: 0.0001)
    }

    func testStatisticsFoldOnlyOverCurrentWindow() {
        // 滚动窗口口径:统计永远只算窗口内样本(容量 3 → [20, 30, 40] 的均值是 30,不是 25)。
        var series = RingSeries<Double>(capacity: 3)
        [10, 20, 30, 40].forEach { series.append($0) }

        XCTAssertEqual(series.statistics?.average ?? 0, 30, accuracy: 0.0001)
        XCTAssertEqual(series.statistics?.peak ?? 0, 40, accuracy: 0.0001)
        XCTAssertEqual(series.statistics?.minimum ?? 0, 20, accuracy: 0.0001)
    }

    func testMemorySeriesFoldsByteValues() {
        // 内存序列(UInt64,字节):组内存可达 GB 级,双精度折叠无精度损失。
        var series = RingSeries<UInt64>(capacity: 4)
        [120_000_000, 2_400_000_000, 900_000_000].forEach { series.append($0) }

        XCTAssertEqual(series.values, [120_000_000, 2_400_000_000, 900_000_000])
        XCTAssertEqual(series.statistics?.peak ?? 0, 2_400_000_000, accuracy: 0.5)
        XCTAssertEqual(series.statistics?.average ?? 0, 1_140_000_000, accuracy: 0.5)
    }

    // MARK: - SampleHistoryStore:随采样轮推进

    func testDefaultCapacityIsSixtyPoints() {
        // ~60 点窗口:5s 节奏 = 5 分钟,1s 节奏 = 1 分钟(spec 实现决策)。
        XCTAssertEqual(SampleHistoryStore().capacity, 60)
    }

    func testAdvanceRecordsSystemLoadAndGroupSeries() {
        // 一轮采样:系统负载与每组 CPU%/内存各得一个点,时间序正确。
        var store = SampleHistoryStore(capacity: 10)
        store.advance(
            systemCPULoad: 42,
            groups: [
                GroupSample(id: "bundle:x", cpuPercent: 320, memoryBytes: 2_400_000_000),
                GroupSample(id: "orphan:y", cpuPercent: 7, memoryBytes: 30_000_000),
            ]
        )
        store.advance(
            systemCPULoad: 55,
            groups: [GroupSample(id: "bundle:x", cpuPercent: 445, memoryBytes: 2_500_000_000)]
        )

        XCTAssertEqual(store.systemCPULoad.values, [42, 55])
        let x = store.series(forGroup: "bundle:x")
        XCTAssertEqual(x?.cpuPercent.values, [320, 445])
        XCTAssertEqual(x?.memoryBytes.values, [2_400_000_000, 2_500_000_000])
        // 第二轮缺席的组:序列已逐出,不再可读。
        XCTAssertNil(store.series(forGroup: "orphan:y"))
    }

    func testVanishedGroupStopsAppendingAndIsEvicted() {
        // 组消失 = 组内进程全部退场:本轮起停止追加,序列随即逐出(内存不无限增长)。
        var store = SampleHistoryStore(capacity: 10)
        store.advance(systemCPULoad: 10, groups: [GroupSample(id: "g", cpuPercent: 100, memoryBytes: 1)])
        store.advance(systemCPULoad: 20, groups: [])

        XCTAssertNil(store.series(forGroup: "g"))
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testReturningGroupRestartsItsSeries() {
        // 同 id 组去而复返:视为新 incarnation,序列从头累计(旧窗口不复活)。
        var store = SampleHistoryStore(capacity: 10)
        store.advance(systemCPULoad: 10, groups: [GroupSample(id: "g", cpuPercent: 5, memoryBytes: 10)])
        store.advance(systemCPULoad: 20, groups: [])
        store.advance(systemCPULoad: 30, groups: [GroupSample(id: "g", cpuPercent: 9, memoryBytes: 20)])

        let series = store.series(forGroup: "g")
        XCTAssertEqual(series?.cpuPercent.values, [9])
        XCTAssertEqual(series?.memoryBytes.values, [20])
    }

    func testGroupSeriesAreIndependent() {
        // 多组并存:各自序列互不串扰。
        var store = SampleHistoryStore(capacity: 10)
        store.advance(
            systemCPULoad: 10,
            groups: [
                GroupSample(id: "a", cpuPercent: 12, memoryBytes: 100),
                GroupSample(id: "b", cpuPercent: 34, memoryBytes: 200),
            ]
        )
        store.advance(
            systemCPULoad: 20,
            groups: [
                GroupSample(id: "a", cpuPercent: 56, memoryBytes: 150),
                GroupSample(id: "b", cpuPercent: 78, memoryBytes: 250),
            ]
        )

        XCTAssertEqual(store.series(forGroup: "a")?.cpuPercent.values, [12, 56])
        XCTAssertEqual(store.series(forGroup: "b")?.cpuPercent.values, [34, 78])
    }

    func testSystemLoadRespectsCapacityAcrossSweeps() {
        // 系统负载序列同受容量约束:容量 2,四轮后只剩最后两个值。
        var store = SampleHistoryStore(capacity: 2)
        [10, 60, 90, 30].forEach { load in
            store.advance(systemCPULoad: load, groups: [])
        }

        XCTAssertEqual(store.systemCPULoad.values, [90, 30])
        // 窗口统计:均值 60、峰值 90、谷值 30。
        XCTAssertEqual(store.systemCPULoad.statistics?.average ?? 0, 60, accuracy: 0.0001)
        XCTAssertEqual(store.systemCPULoad.statistics?.peak ?? 0, 90, accuracy: 0.0001)
        XCTAssertEqual(store.systemCPULoad.statistics?.minimum ?? 0, 30, accuracy: 0.0001)
    }
}
