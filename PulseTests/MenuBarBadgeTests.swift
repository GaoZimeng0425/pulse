import XCTest
@testable import Pulse

/// 菜单栏徽标槽位配置 → 渲染输入的映射(spec 测试决策钉死的纯函数缝):
/// 默认态与现状逐像素一致、四选一槽位、顺序可调、读数缺失占位不伪造、
/// 网络紧凑上下行与"放不下只显示下载"降级、缓存键随配置变化。
final class MenuBarBadgeTests: XCTestCase {
    // MARK: - 槽位配置

    /// 默认配置 = CPU + RAM(Round-2 共识:默认不变)。
    func testDefaultConfigurationIsCPURAM() {
        XCTAssertEqual(MenuBarBadgeConfiguration.default.slots, [.cpu, .ram])
        XCTAssertEqual(MenuBarBadgeConfiguration.default.rawValue, "cpu,ram")
    }

    /// 1–3 槽边界:空与超 3 槽按"非法配置回落默认"处置。
    func testInvalidSlotCountFallsBackToDefault() {
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: []).slots, [.cpu, .ram])
        XCTAssertEqual(
            MenuBarBadgeConfiguration(slots: [.cpu, .ram, .diskRemaining, .networkRate]).slots,
            [.cpu, .ram]
        )
    }

    /// rawValue 解码:未知指标 / 非法数量 → nil(调用方 `?? .default` 回默认)。
    func testInvalidRawValueDecodesToNil() {
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "bogus"))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: ""))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "cpu,ram,cpu,ram"))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "cpu,network,foo"))
    }

    /// 合法配置 rawValue 往返:设置页写什么,重启读回就是什么。
    func testRawValueRoundTrip() {
        let configuration = MenuBarBadgeConfiguration(slots: [.ram, .diskRemaining, .networkRate])
        XCTAssertEqual(MenuBarBadgeConfiguration(rawValue: configuration.rawValue)?.slots,
                       [.ram, .diskRemaining, .networkRate])
    }

    // MARK: - 配置 → 渲染输入(顺序 = 菜单栏从左到右)

    /// 顺序可调:RAM 在前 CPU 在后,输出顺序跟随槽位。
    func testComposeOrderFollowsSlots() {
        let contents = MenuBarBadgeComposer.compose(
            MenuBarBadgeConfiguration(slots: [.ram, .cpu]),
            data: Self.sampleData
        )
        XCTAssertEqual(contents.map(\.caption), ["RAM", "CPU"])
    }

    /// 默认态(工单验收①):与改动前逐像素一致的同源输入——
    /// CPU 文案走 PulseFormat.cpuPercent、超 70% 变红,RAM 占比 + 压力变色,
    /// 标签字面量 "CPU"/"RAM" 与旧双徽标逐字相同。
    func testComposeDefaultMatchesCurrentBadgeInputs() {
        let contents = MenuBarBadgeComposer.compose(
            .default,
            data: Self.sampleData
        )
        XCTAssertEqual(
            contents,
            [
                MenuBarBadgeContent(caption: "CPU", text: "43%", emphasis: .normal),
                MenuBarBadgeContent(caption: "RAM", text: "50%", emphasis: .normal),
            ]
        )
    }

    /// CPU 变红边界与菜单栏红线同口径:> 70% 红,恰好 70% 不红。
    func testCPUThresholdBoundaries() {
        XCTAssertEqual(MenuBarBadgeComposer.cpuContent(load: 70).emphasis, .normal)
        XCTAssertEqual(MenuBarBadgeComposer.cpuContent(load: 70.1).emphasis, .critical)
        XCTAssertEqual(MenuBarBadgeComposer.cpuContent(load: 100).emphasis, .critical)
    }

    /// 阈值字面量与 SystemMonitor.redThreshold 保持同一出处语义
    /// (字面量直写绕开 MainActor 隔离,漂移由本断言拦截)。
    @MainActor
    func testCPURedThresholdMatchesMenuBarRedLine() {
        XCTAssertEqual(MenuBarBadgeComposer.cpuRedThreshold, SystemMonitor.redThreshold)
    }

    /// RAM 读数缺失:占位 "–"(沿用旧双徽标的占位字面量),不伪造。
    func testRAMPlaceholderWhenMemoryMissing() {
        let content = MenuBarBadgeComposer.ramContent(memory: nil)
        XCTAssertEqual(content.text, "–")
        XCTAssertEqual(content.emphasis, .normal)
    }

    /// RAM 压力联动:偏高橙(warning)/ 紧张红(critical)。
    func testRAMPressureDrivesEmphasis() {
        let base = Self.sampleData.memory!
        let warning = MenuBarBadgeComposer.ramContent(memory: Self.memory(total: base.totalBytes,
                                                                          used: base.usedBytes,
                                                                          pressure: .warning))
        let critical = MenuBarBadgeComposer.ramContent(memory: Self.memory(total: base.totalBytes,
                                                                           used: base.usedBytes,
                                                                           pressure: .critical))
        XCTAssertEqual(warning.emphasis, .warning)
        XCTAssertEqual(critical.emphasis, .critical)
    }

    // MARK: - 磁盘剩余槽

    /// 磁盘剩余 = 实际可用(important 口径),十进制 GB 整数——与
    /// PulseFormat 磁盘卡同口径不同精度;二进制口径在此必须分得出
    /// (1.0737e12 字节:十进制 1074 GB,二进制恰好 1000 GB)。
    func testDiskRemainingUsesDecimalGB() {
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: 182_350_000_000).text, "182 GB")
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: 1_073_741_824_000).text, "1074 GB")
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: 0).text, "0 GB")
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: -5).text, "0 GB")
    }

    /// 磁盘容量读数未到(首轮前 lastGood 为 nil):占位 "—" 不伪造。
    func testDiskRemainingPlaceholderWhenNoReading() {
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: nil).text, "—")
    }

    // MARK: - 网络速率槽(工单 09 只做壳,数据由工单 06 填充)

    /// 网络徽标主形态:紧凑上下行 "↓下载 ↑上传",MB/s 口径与磁盘速率一致。
    func testNetworkBadgeCompactDualFormat() {
        let content = MenuBarBadgeComposer.networkContent(
            rate: NetworkRateReading(downloadBytesPerSecond: 12_400_000, uploadBytesPerSecond: 1_200_000)
        )
        XCTAssertEqual(content.caption, "网络")
        XCTAssertEqual(content.text, "↓12.4 MB/s ↑1.2 MB/s")
        XCTAssertEqual(content.emphasis, .normal)
    }

    /// 网络字段未填充(工单 06 之前恒 nil):占位 "—" 不伪造。
    func testNetworkBadgePlaceholderWhenNoData() {
        XCTAssertEqual(MenuBarBadgeComposer.networkContent(rate: nil).text, "—")
    }

    /// 放不下降级:紧凑双行超宽度预算 → 只显示下载。
    func testNetworkBadgeDegradesToDownloadOnlyWhenTooWide() {
        let content = MenuBarBadgeComposer.networkContent(
            rate: NetworkRateReading(downloadBytesPerSecond: 888_800_000, uploadBytesPerSecond: 888_800_000)
        )
        XCTAssertEqual(content.text, "↓888.8 MB/s")
    }

    /// 宽度预算策略锚点:典型双行装得下、超宽数字装不下——字号度量若随
    /// 系统版本漂移,先在此暴露而不是默默翻转降级行为。
    func testNetworkWidthBudgetSplitsRealisticAndPathological() {
        let realistic = MenuBarBadgeComposer.estimatedWidth(of: "↓12.4 MB/s ↑1.2 MB/s")
        let pathological = MenuBarBadgeComposer.estimatedWidth(of: "↓888.8 MB/s ↑888.8 MB/s")
        XCTAssertLessThanOrEqual(realistic, MenuBarBadgeComposer.networkWidthBudget)
        XCTAssertGreaterThan(pathological, MenuBarBadgeComposer.networkWidthBudget)
    }

    // MARK: - 渲染缓存键(位图缓存只在内容/外观变化时失效)

    @MainActor
    func testCacheKeyChangesWithContentsAndScheme() {
        let cpu = MenuBarBadgeContent(caption: "CPU", text: "43%", emphasis: .normal)
        let ram = MenuBarBadgeContent(caption: "RAM", text: "50%", emphasis: .normal)
        let cpuFirst = [cpu, ram]
        let ramFirst = [ram, cpu]

        // 同内容同外观 → 同键(缓存命中);槽位顺序变 → 键变;
        // 外观变 → 键变;数值/强调级任一变化 → 键变。
        XCTAssertEqual(MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .dark),
                       MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .dark))
        XCTAssertNotEqual(MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .dark),
                          MenuBarBadgeRenderer.cacheKey(for: ramFirst, colorScheme: .dark))
        XCTAssertNotEqual(MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .dark),
                          MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .light))
        XCTAssertNotEqual(
            MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .dark),
            MenuBarBadgeRenderer.cacheKey(
                for: [cpu, MenuBarBadgeContent(caption: "RAM", text: "51%", emphasis: .normal)],
                colorScheme: .dark
            )
        )
        XCTAssertNotEqual(
            MenuBarBadgeRenderer.cacheKey(for: cpuFirst, colorScheme: .dark),
            MenuBarBadgeRenderer.cacheKey(
                for: [cpu, MenuBarBadgeContent(caption: "RAM", text: "50%", emphasis: .critical)],
                colorScheme: .dark
            )
        )
    }

    // MARK: - 夹具

    /// 合成数据(单测不制造真实负载):CPU 42.6% → "43%",RAM 恰好 50%。
    static let sampleData = MenuBarBadgeData(
        cpuLoadPercent: 42.6,
        memory: memory(total: 48_000_000_000, used: 24_000_000_000, pressure: .normal),
        diskAvailableBytes: 182_350_000_000,
        networkRate: nil
    )

    private static func memory(total: UInt64, used: UInt64, pressure: MemoryPressure) -> MemoryBreakdown {
        MemoryBreakdown(
            totalBytes: total,
            appBytes: used,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedBytes: 0,
            pressure: pressure
        )
    }
}
