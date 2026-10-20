import XCTest
@testable import Pulse
@testable import PulseCore

/// 菜单栏徽标槽位配置 → 渲染输入的映射(spec 测试决策钉死的纯函数缝):
/// 默认态与现状逐像素一致、四项指标可同时上屏、顺序可调、读数缺失占位不伪造、
/// 磁盘剩余百分比、网络上下行叠两行、缓存键随配置变化。
final class MenuBarBadgeTests: XCTestCase {
    // MARK: - 槽位配置

    /// 默认配置 = CPU + RAM(Round-2 共识:默认不变)。
    func testDefaultConfigurationIsCPURAM() {
        XCTAssertEqual(MenuBarBadgeConfiguration.default.slots, [.cpu, .ram])
        XCTAssertEqual(MenuBarBadgeConfiguration.default.rawValue, "cpu,ram")
    }

    /// 槽位上限 = 指标总数(四项可同时上屏,2026-10-20 用户要求);空与超上限按
    /// "非法配置回落默认"处置。
    func testAllFourMetricsFitAtOnceAndBeyondFallsBackToDefault() {
        let all: [MenuBarBadgeMetric] = [.cpu, .ram, .diskRemaining, .networkRate]
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: all).slots, all)
        XCTAssertEqual(MenuBarBadgeConfiguration(rawValue: "cpu,ram,diskRemaining,networkRate")?.slots, all)
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: []).slots, [.cpu, .ram])
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: all + [.cpu]).slots, [.cpu, .ram])
    }

    /// rawValue 解码:未知指标 / 非法数量 → nil(调用方 `?? .default` 回默认)。
    func testInvalidRawValueDecodesToNil() {
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "bogus"))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: ""))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "cpu,ram,cpu,ram,cpu"))
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

    /// 默认态(工单验收①):与改动前同源同文案——CPU 文案走
    /// PulseFormat.cpuPercent、超 70% 变红,RAM 占比 + 压力变色,标签字面量
    /// "CPU"/"RAM" 与旧双徽标逐字相同;槽位定宽按同一参考串("100%")取值。
    func testComposeDefaultMatchesCurrentBadgeInputs() {
        let contents = MenuBarBadgeComposer.compose(
            .default,
            data: Self.sampleData
        )
        XCTAssertEqual(
            contents,
            [
                MenuBarBadgeContent(
                    caption: "CPU", text: "43%", emphasis: .normal,
                    slotWidth: MenuBarBadgeComposer.slotWidth(for: "100%")
                ),
                MenuBarBadgeContent(
                    caption: "RAM", text: "50%", emphasis: .normal,
                    slotWidth: MenuBarBadgeComposer.slotWidth(for: "100%")
                ),
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

    /// 磁盘剩余 = 实际可用(important 口径)占容器总容量的百分比(2026-10-20 用户
    /// 拍板:剩余百分比,不再显示 GB):182.35 / 500 GB = 36.47% → "36%"。
    func testDiskRemainingShowsPercentOfContainerTotal() {
        XCTAssertEqual(
            MenuBarBadgeComposer.diskContent(availableBytes: 182_350_000_000, totalBytes: 500_000_000_000).text,
            "36%"
        )
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: 0, totalBytes: 500_000_000_000).text, "0%")
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: -5, totalBytes: 500_000_000_000).text, "0%")
    }

    /// 可用或总容量读不到(首轮前 / 非 APFS)、总容量为 0:占位 "—" 不伪造。
    func testDiskRemainingPlaceholderWhenAnyPartIsMissing() {
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: nil, totalBytes: 500_000_000_000).text, "—")
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: 1, totalBytes: nil).text, "—")
        XCTAssertEqual(MenuBarBadgeComposer.diskContent(availableBytes: 1, totalBytes: 0).text, "—")
    }

    // MARK: - 网络速率槽:上下行叠两行(2026-10-20 用户拍板)

    /// 上行在上、下行在下,各占一行,不带小标签;口径与磁盘速率一致。
    func testNetworkBadgeStacksUploadOverDownload() {
        let content = MenuBarBadgeComposer.networkContent(
            rate: NetworkRates(upBytesPerSecond: 1_200_000, downBytesPerSecond: 12_400_000)
        )
        XCTAssertEqual(content.layout, .stacked)
        XCTAssertEqual(content.caption, "网络")
        XCTAssertEqual(content.text, "↑1.2 MB/s\n↓12.4 MB/s")
        XCTAssertEqual(content.emphasis, .normal)
    }

    /// 不再降级:数字再长也两行都显示(以前超宽只显示下载)。
    func testNetworkBadgeNeverDropsUpload() {
        let content = MenuBarBadgeComposer.networkContent(
            rate: NetworkRates(upBytesPerSecond: 888_800_000, downBytesPerSecond: 888_800_000)
        )
        XCTAssertEqual(content.text, "↑888.8 MB/s\n↓888.8 MB/s")
    }

    /// 读数未到:两行各占位 "—",版式不变(首轮前后不变形)。
    func testNetworkBadgePlaceholderWhenNoData() {
        let content = MenuBarBadgeComposer.networkContent(rate: nil)
        XCTAssertEqual(content.layout, .stacked)
        XCTAssertEqual(content.text, "↑—\n↓—")
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

    // MARK: - 渲染缓存 LRU(评审修复:徽标文案逐轮变新键,缓存必须有界)

    /// 容量上界:插入超过容量,最旧键被淘汰,条数不再增长。
    func testLRUCacheEvictsOldestBeyondCapacity() {
        var cache = LRUBoundedCache<String, Int>(capacity: 3)
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            cache.insert(index, forKey: key)
        }
        XCTAssertEqual(cache.order, ["b", "c", "d"], "容量 3 时最旧的 a 被挤出")
        XCTAssertNil(cache.hit("a"))
        XCTAssertEqual(cache.hit("d"), 3)
    }

    /// 命中即续命:被访问的键挪到最新,淘汰顺位让给真正最旧的键。
    func testLRUCacheHitRefreshesRecency() {
        var cache = LRUBoundedCache<String, Int>(capacity: 3)
        for (index, key) in ["a", "b", "c"].enumerated() {
            cache.insert(index, forKey: key)
        }
        XCTAssertEqual(cache.hit("a"), 0, "命中返回值")
        cache.insert(9, forKey: "d")
        XCTAssertEqual(cache.order, ["c", "a", "d"], "a 因命中续命,b 成为最旧被挤出")
        XCTAssertNil(cache.hit("b"))
        XCTAssertEqual(cache.hit("a"), 0)
        XCTAssertEqual(cache.hit("c"), 2, "c 未被命中过但仍未到淘汰顺位")
    }

    /// 重复插入同键:更新值且不产生重复序位。
    func testLRUCacheReinsertUpdatesWithoutDuplicates() {
        var cache = LRUBoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(3, forKey: "a")
        XCTAssertEqual(cache.order, ["b", "a"])
        XCTAssertEqual(cache.hit("a"), 3, "同键再插更新值")
    }

    /// 渲染器容量锚点:策略常量(~20)与"网络速率几秒窗内来回切换仍命中"
    /// 的量级一致——改这个数等于改新旧键命中率,先在此暴露。
    @MainActor
    func testRendererCacheCapacityIsBounded() {
        XCTAssertEqual(MenuBarBadgeRenderer.cacheCapacity, 20)
    }

    // MARK: - 槽位定宽(2026-10-17 用户反馈:数字位数变化带动状态项宽度抖动)

    /// 四种槽都定宽(网络按两行里最宽的现实读数 "999.9 KB/s" 量)——状态项宽度
    /// 不随读数抖动;占位读数同在定宽槽内。
    func testEverySlotIsPinnedToAFixedWidth() {
        for slot in MenuBarBadgeMetric.allCases {
            let content = MenuBarBadgeComposer.compose(
                MenuBarBadgeConfiguration(slots: [slot]),
                data: Self.sampleData
            )[0]
            XCTAssertNotNil(content.slotWidth, "\(slot) 槽应定宽")
        }
    }

    /// 定宽覆盖最大现实读数:CPU/RAM 三位数 "100%"、磁盘三位数 GB 不得溢出
    /// 定宽槽(monospacedDigit 同字数同宽,槽宽取参考串 + 2pt 余量)。
    func testSlotWidthCoversWidestRealisticReading() {
        let widest = MenuBarBadgeContent(caption: "CPU", text: "100%", emphasis: .normal)
        let reference = MenuBarBadgeComposer.slotWidth(for: "100%")
        XCTAssertGreaterThanOrEqual(
            reference,
            ceil(MenuBarBadgeComposer.estimatedWidth(of: widest.text)),
            "参考串本身必须装得下"
        )
        // 位图宽由渲染器落实,此处钉住纯函数缝:同参考串必得同槽宽(确定性)。
        XCTAssertEqual(reference, MenuBarBadgeComposer.slotWidth(for: "100%"))
    }

    /// 最大现实读数不折行、不撑宽(2026-10-19 用户反馈:CPU 100% 时菜单栏文字
    /// 变两行)——走真实渲染器断言位图尺寸:最宽读数与个位数读数同高(单行)
    /// 同宽(定宽不抖)。上一条只拿估算器自证,量不出绘制字重(medium + 等宽
    /// 数字)比估算字体宽 ~3pt 的差,"100%" 因此溢出定宽槽被折成两行。
    @MainActor
    func testWidestReadingsRenderSingleLineWithinPinnedWidth() {
        let pairs: [(narrow: MenuBarBadgeContent, widest: MenuBarBadgeContent)] = [
            (MenuBarBadgeComposer.cpuContent(load: 5), MenuBarBadgeComposer.cpuContent(load: 100)),
            (
                MenuBarBadgeComposer.ramContent(memory: Self.memory(total: 100, used: 5, pressure: .normal)),
                MenuBarBadgeComposer.ramContent(memory: Self.memory(total: 100, used: 100, pressure: .normal))
            ),
            (
                MenuBarBadgeComposer.diskContent(availableBytes: 5_000_000_000, totalBytes: 500_000_000_000),
                MenuBarBadgeComposer.diskContent(availableBytes: 500_000_000_000, totalBytes: 500_000_000_000)
            ),
            (
                MenuBarBadgeComposer.networkContent(rate: NetworkRates(upBytesPerSecond: 0, downBytesPerSecond: 0)),
                MenuBarBadgeComposer.networkContent(
                    rate: NetworkRates(upBytesPerSecond: 999_900, downBytesPerSecond: 999_900)
                )
            ),
        ]
        for (narrow, widest) in pairs {
            let narrowImage = MenuBarBadgeRenderer.image(for: [narrow], colorScheme: .light)
            let widestImage = MenuBarBadgeRenderer.image(for: [widest], colorScheme: .light)
            XCTAssertEqual(widestImage.size.height, narrowImage.size.height, "\(widest.text) 折行")
            XCTAssertEqual(widestImage.size.width, narrowImage.size.width, "\(widest.text) 撑宽")
        }
    }

    /// 叠两行的网络徽标不比「小标签 + 数字」的徽标高:菜单栏高度装得下。
    @MainActor
    func testStackedNetworkBadgeIsNoTallerThanCaptionedBadges() {
        let network = MenuBarBadgeRenderer.image(
            for: [MenuBarBadgeComposer.networkContent(rate: NetworkRates(upBytesPerSecond: 1, downBytesPerSecond: 1))],
            colorScheme: .light
        )
        let cpu = MenuBarBadgeRenderer.image(for: [MenuBarBadgeComposer.cpuContent(load: 5)], colorScheme: .light)
        XCTAssertLessThanOrEqual(network.size.height, cpu.size.height)
    }

    // MARK: - 夹具

    /// 合成数据(单测不制造真实负载):CPU 42.6% → "43%",RAM 恰好 50%。
    static let sampleData = MenuBarBadgeData(
        cpuLoadPercent: 42.6,
        memory: memory(total: 48_000_000_000, used: 24_000_000_000, pressure: .normal),
        diskAvailableBytes: 182_350_000_000,
        diskTotalBytes: 500_000_000_000,
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
