import XCTest
@testable import Pulse

/// 接缝(工单 P0.6-05):总览指标卡新增的系统级实时口径——CPU 用户/系统拆分、
/// 内存构成与压力等级、内存已用历史序列、主机信息与运行时长文案。
/// 期望值全部是手工推演的字面量,不经过实现同源计算。
final class SystemStatsTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)
    private let gib: Double = 1_073_741_824

    // MARK: CPU 用户/系统拆分(CoreTickDiffer.breakdown)

    private func ticks(
        user: [UInt64],
        system: [UInt64],
        idle: [UInt64],
        at seconds: TimeInterval
    ) -> CoreTickSample {
        let busy = zip(user, system).map { $0 + $1 }
        let total = zip(busy, idle).map { $0 + $1 }
        return CoreTickSample(
            busyTicks: busy,
            totalTicks: total,
            takenAt: base.addingTimeInterval(seconds),
            userTicks: user,
            systemTicks: system
        )
    }

    func testBreakdownSplitsUserAndSystemShareOfTotalTicks() {
        // 两核:用户差 30+10=40,系统差 10+10=20,总差 100+100=200
        // → 用户 20%,系统 10%,合计 30%(与 systemCPULoad 同一口径)。
        let breakdown = CoreTickDiffer.breakdown(
            previous: ticks(user: [0, 0], system: [0, 0], idle: [0, 0], at: 0),
            current: ticks(user: [30, 10], system: [10, 10], idle: [60, 80], at: 1)
        )

        XCTAssertEqual(breakdown.total, 30, accuracy: 0.0001)
        XCTAssertEqual(breakdown.user, 20, accuracy: 0.0001)
        XCTAssertEqual(breakdown.system, 10, accuracy: 0.0001)
    }

    func testBreakdownWithoutPreviousSampleIsZero() {
        let breakdown = CoreTickDiffer.breakdown(
            previous: nil,
            current: ticks(user: [30], system: [10], idle: [60], at: 0)
        )

        XCTAssertEqual(breakdown, .zero)
    }

    func testBreakdownWithoutSplitTicksKeepsTotalAndZeroesSplit() {
        // 旧口径样本(无用户/系统拆分):合计照算,拆分退化为 0,不伪造。
        let previous = CoreTickSample(busyTicks: [10], totalTicks: [100], takenAt: base)
        let current = CoreTickSample(busyTicks: [40], totalTicks: [220], takenAt: base.addingTimeInterval(1))

        let breakdown = CoreTickDiffer.breakdown(previous: previous, current: current)

        XCTAssertEqual(breakdown.total, 25, accuracy: 0.0001)
        XCTAssertEqual(breakdown.user, 0, accuracy: 0.0001)
        XCTAssertEqual(breakdown.system, 0, accuracy: 0.0001)
    }

    // MARK: 内存构成(MemoryBreakdown.make,活动监视器同口径)

    func testMemoryBreakdownFollowsActivityMonitorFormula() {
        // 页 16 KiB;App = 内部 - 可清除 = 1000 - 200 = 800 页;
        // 联动 300 页;压缩 100 页;缓存 = 外部 + 可清除 = 400 + 200 = 600 页。
        // 已用 = App + 联动 + 压缩 = 1200 页 = 19_660_800 字节。
        let breakdown = MemoryBreakdown.make(
            pages: VMPageCounts(internal: 1000, purgeable: 200, external: 400, wired: 300, compressor: 100),
            pageSize: 16_384,
            totalBytes: 40_000_000,
            pressure: .normal
        )

        XCTAssertEqual(breakdown.appBytes, 13_107_200)
        XCTAssertEqual(breakdown.wiredBytes, 4_915_200)
        XCTAssertEqual(breakdown.compressedBytes, 1_638_400)
        XCTAssertEqual(breakdown.cachedBytes, 9_830_400)
        XCTAssertEqual(breakdown.usedBytes, 19_660_800)
        // 空闲 = 总 - 已用 - 缓存 = 40_000_000 - 19_660_800 - 9_830_400。
        XCTAssertEqual(breakdown.freeBytes, 10_508_800)
    }

    func testMemoryBreakdownClampsInconsistentCounters() {
        // 可清除 > 内部(计数非原子读取的瞬时不一致):App 夹到 0;
        // 已用 + 缓存超过物理总量:空闲夹到 0,不下溢。
        let breakdown = MemoryBreakdown.make(
            pages: VMPageCounts(internal: 10, purgeable: 50, external: 1000, wired: 1000, compressor: 0),
            pageSize: 1000,
            totalBytes: 1_500_000,
            pressure: .warning
        )

        XCTAssertEqual(breakdown.appBytes, 0)
        XCTAssertEqual(breakdown.freeBytes, 0)
        XCTAssertEqual(breakdown.pressure, .warning)
    }

    func testMemoryPressureMapsKernelLevels() {
        // kern.memorystatus_vm_pressure_level:1 正常 / 2 警告 / 4 严重;未知值按正常。
        XCTAssertEqual(MemoryPressure(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(kernelLevel: 0), .normal)
    }

    func testMemoryPressureTitlesAreChinese() {
        XCTAssertEqual(MemoryPressure.normal.title, "正常")
        XCTAssertEqual(MemoryPressure.warning.title, "偏高")
        XCTAssertEqual(MemoryPressure.critical.title, "紧张")
    }

    // MARK: 内存已用历史(SampleHistoryStore)

    func testHistoryRecordsMemoryUsedWhenProvided() {
        var store = SampleHistoryStore(capacity: 3)
        store.advance(systemCPULoad: 10, memoryUsedBytes: 5_000, groups: [])
        store.advance(systemCPULoad: 20, memoryUsedBytes: nil, groups: [])
        store.advance(systemCPULoad: 30, memoryUsedBytes: 7_000, groups: [])

        // 缺读数的轮次不追加(不伪造 0 拉低走势)。
        XCTAssertEqual(store.memoryUsed.values, [5_000, 7_000])
        XCTAssertEqual(store.systemCPULoad.values, [10, 20, 30])
    }

    // MARK: 主机信息与运行时长文案

    func testHostSummaryJoinsChipCoresAndBinaryMemory() {
        // 物理内存按二进制 GB 取整(48 GiB 机器显示 48 GB,而非 51.5)。
        XCTAssertEqual(
            PulseFormat.hostSummary(chipName: "Apple M4 Pro", coreCount: 12, physicalMemoryBytes: 51_539_607_552),
            "Apple M4 Pro · 12 核 · 48 GB"
        )
    }

    func testHostSummaryOmitsUnknownChipName() {
        XCTAssertEqual(
            PulseFormat.hostSummary(chipName: nil, coreCount: 8, physicalMemoryBytes: 17_179_869_184),
            "8 核 · 16 GB"
        )
    }

    /// 物理内存取整边界(自 EnvironmentInfoTests 迁入,评审 F1):非 2 的幂
    /// 装机值按最近整 GB——.4 舍 / .6 入,不出现 "12.4 GB" 式小数。
    func testPhysicalMemoryTotalRoundsToNearestGigabyte() {
        XCTAssertEqual(PulseFormat.physicalMemoryTotal(UInt64(12.4 * Double(gib))), "12 GB")
        XCTAssertEqual(PulseFormat.physicalMemoryTotal(UInt64(12.6 * Double(gib))), "13 GB")
    }

    // MARK: 内存构成单表(评审 F5)

    /// 单表键 → 构成字段的映射:键集与中文名固定,字节取值与 MemoryBreakdown
    /// 字段一一对应(统计点与 by-Type 环共用此映射,漂移由本断言拦截)。
    func testMemoryCompositionTableMapsKeysToFields() {
        let breakdown = MemoryBreakdown(
            totalBytes: 40_000_000, appBytes: 1_100, wiredBytes: 2_200,
            compressedBytes: 3_300, cachedBytes: 4_400, pressure: .normal
        )
        XCTAssertEqual(MemoryCompositionKey.allCases.count, 5)
        XCTAssertEqual(MemoryCompositionKey.allCases.map(\.title), ["App", "联动", "压缩", "缓存", "空闲"])
        XCTAssertEqual(breakdown.bytes(for: .app), breakdown.appBytes)
        XCTAssertEqual(breakdown.bytes(for: .wired), breakdown.wiredBytes)
        XCTAssertEqual(breakdown.bytes(for: .compressed), breakdown.compressedBytes)
        XCTAssertEqual(breakdown.bytes(for: .cached), breakdown.cachedBytes)
        XCTAssertEqual(breakdown.bytes(for: .free), breakdown.freeBytes)
    }

    // MARK: 系统 uptime(05 口径:两级单位,不足 1 分钟按 1 分钟)

    func testSystemUptimeUsesTwoLargestUnits() {
        XCTAssertEqual(PulseFormat.systemUptime(seconds: 45), "已运行 1 分钟")
        XCTAssertEqual(PulseFormat.systemUptime(seconds: 25 * 60), "已运行 25 分钟")
        XCTAssertEqual(PulseFormat.systemUptime(seconds: 3 * 3600 + 12 * 60), "已运行 3 小时 12 分")
        XCTAssertEqual(PulseFormat.systemUptime(seconds: 6 * 86_400 + 4 * 3600 + 59), "已运行 6 天 4 小时")
    }

    /// 负时长(时钟回拨)防御:按 0 夹紧,最少显示 1 分钟(迁自 EnvironmentInfoTests)。
    func testSystemUptimeClampsNegative() {
        XCTAssertEqual(PulseFormat.systemUptime(seconds: -5), "已运行 1 分钟")
    }

    func testSystemMemoryFigureUsesBinaryGigabytesWithTwoDecimals() {
        // 系统内存卡与物理总量同一二进制口径:"已用 51.06 GB / 共 64 GB" 不打架。
        let figure = PulseFormat.systemMemoryFigure(54_825_000_000)
        XCTAssertEqual(figure.value, "51.06")
        XCTAssertEqual(figure.unit, "GB")
        XCTAssertEqual(PulseFormat.systemMemory(536_870_912), "512 MB")
        XCTAssertEqual(PulseFormat.physicalMemoryTotal(68_719_476_736), "64 GB")
    }
}
