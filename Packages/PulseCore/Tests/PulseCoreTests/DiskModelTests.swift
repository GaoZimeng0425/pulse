import XCTest
@testable import PulseCore

/// 工单 05 磁盘卡:核心层 DiskModel 的合成夹具单测(spec 测试决策)。核心断言四组:
/// ①容器对账不变式——各卷已用之和 + 其他卷 == 容器总量(petal 同款断言);
/// ②purgeable 两 key 差值与缺失占位;③快照记录解析(合成 packed 字节,petal
/// 同款负例)+ TM 前缀识别;④吞吐差分三件防护(首读置零/计数回退/elapsed 有限)。
/// Provider 与 Live 源在 PulseTests/DiskSensorTests。
final class DiskModelTests: XCTestCase {
    // MARK: - 容量对账夹具(合成,不读真实卷)

    /// 合成原始读数:root = disk3 的 APFS 容器,含 Data/macOS/VM/Preboot 四卷
    /// (已用合计 accounted),外加一个 disk5 异容器卷、一个非 apfs 卷、一个
    /// getattrlist 失败(nil usedBytes)的同容器卷——后三者必须被过滤/跳过。
    private func raw(
        containerUsed: UInt64 = 300_000_000_000,
        dataUsed: UInt64 = 240_000_000_000,
        macOSUsed: UInt64 = 15_000_000_000,
        vmUsed: UInt64 = 25_000_000_000,
        prebootUsed: UInt64 = 10_000_000_000,
        unmountedRemainder: UInt64 = 10_000_000_000,
        important: Int64? = 209_550_000_000,
        free: Int64? = 202_940_000_000,
        rootDevice: String = "/dev/disk3s1s1",
        includeDataVolume: Bool = true
    ) -> DiskCapacityRawReading {
        func volume(_ mount: String, _ device: String, fs: String = "apfs", used: UInt64?) -> MountedVolumeRaw {
            MountedVolumeRaw(mountPoint: mount, device: device, fileSystem: fs, usedBytes: used)
        }
        var mounted: [MountedVolumeRaw] = [
            volume("/", rootDevice, used: macOSUsed),
            volume("/System/Volumes/VM", "/dev/disk3s3", used: vmUsed),
            volume("/System/Volumes/Preboot", "/dev/disk3s2", used: prebootUsed),
            volume("/Volumes/外置", "/dev/disk5s1", used: 999),        // 异容器:过滤
            volume("/opt/homebrew", "map auto_home", fs: "autofs", used: nil), // 非 apfs:过滤
            volume("/System/Volumes/Update", "/dev/disk3s4", used: nil), // 同容器读失败:跳过
        ]
        if includeDataVolume {
            mounted.insert(volume("/System/Volumes/Data", "/dev/disk3s5", used: dataUsed), at: 0)
        }
        return DiskCapacityRawReading(
            rootDevice: rootDevice,
            containerTotalBytes: containerUsed + unmountedRemainder + 500_000_000_000,
            containerUsedBytes: containerUsed,
            availableForImportantUsage: important,
            availableCapacity: free,
            volumeName: "Macintosh HD",
            mountedVolumes: mounted,
            snapshots: .listing([
                DiskSnapshot(name: "com.apple.os.update-26.1", createdEpoch: 1_760_000_000),
                DiskSnapshot(
                    name: "com.apple.TimeMachine.2026-10-15-030000.local",
                    createdEpoch: 1_760_500_000
                ),
            ])
        )
    }

    // MARK: - ① 容器对账不变式(petal 同款断言)

    func testContainerReconciliationInvariantVolumesSumToContainer() {
        // 核心不变式:各卷已用之和 + 其他卷 == 容器总量(240+15+25+10 + 兜底 10)。
        let reading = DiskCapacity.make(from: raw())!
        XCTAssertEqual(reading.accountedBytes, reading.containerUsedBytes)
        XCTAssertEqual(reading.dataVolume.usedBytes, 240_000_000_000)
        // 有差额 → "其他卷"行 = 未挂载卷 + 容器元数据。
        XCTAssertEqual(reading.unaccounted?.usedBytes, 10_000_000_000)
        XCTAssertEqual(reading.unaccounted?.label, "其他卷")
        XCTAssertEqual(reading.otherVolumes.map(\.label), ["macOS", "虚拟内存", "Preboot"])
    }

    func testReconciliationWithoutRemainderOmitsOtherVolumesRow() {
        // 各卷之和恰等于容器已用:不造"其他卷"行,不变式仍成立。
        let reading = DiskCapacity.make(from: raw(containerUsed: 290_000_000_000))!
        XCTAssertNil(reading.unaccounted)
        XCTAssertEqual(reading.accountedBytes, reading.containerUsedBytes)
    }

    func testReconciliationWhenVolumesExceedContainerMakesNoNegativeRow() {
        // 超额(计时缝隙可致 accounted > used):不造负行(petal 只在
        // container_used > accounted 时兜底),不变式锚点如实反映超额。
        let reading = DiskCapacity.make(from: raw(containerUsed: 100_000_000_000))!
        XCTAssertNil(reading.unaccounted)
        XCTAssertGreaterThan(reading.accountedBytes, reading.containerUsedBytes)
    }

    func testReconciliationFiltersForeignFilesystemsAndFailedVolumes() {
        // 异容器 apfs 卷、非 apfs 挂载、同容器 getattrlist 失败卷:全部不入明细
        // (999 字节与 map auto_home 不出现;失败卷不伪造 0)。
        let reading = DiskCapacity.make(from: raw())!
        XCTAssertFalse(reading.otherVolumes.contains { $0.mountPoint == "/Volumes/外置" })
        XCTAssertFalse(reading.otherVolumes.contains { $0.mountPoint == "/opt/homebrew" })
        XCTAssertFalse(reading.otherVolumes.contains { $0.mountPoint == "/System/Volumes/Update" })
    }

    func testReconciliationReturnsNilWithoutDataVolume() {
        // Data 卷缺席(非现代 APFS 系统/数据卷组):整读数 nil,不伪造。
        XCTAssertNil(DiskCapacity.make(from: raw(includeDataVolume: false)))
    }

    func testReconciliationReturnsNilWhenContainerCannotBeReduced() {
        // 根设备归约不出容器(map auto_home 当根):nil。
        XCTAssertNil(DiskCapacity.make(from: raw(rootDevice: "map auto_home")))
    }

    func testContainerOfReducesBSDNames() {
        // petal 同款用例:disk3s1s1 → disk3;disk12s5 → disk12;非 /dev/ 设备 → nil。
        XCTAssertEqual(DiskCapacity.containerOf(device: "/dev/disk3s1s1"), "disk3")
        XCTAssertEqual(DiskCapacity.containerOf(device: "/dev/disk12s5"), "disk12")
        XCTAssertEqual(DiskCapacity.containerOf(device: "/dev/disk3"), "disk3")
        XCTAssertNil(DiskCapacity.containerOf(device: "map auto_home"))
        XCTAssertNil(DiskCapacity.containerOf(device: "rdisk3s1"))
    }

    func testVolumeLabelsUseFixedTableThenBasename() {
        // 已知挂载点固定标签(petal 表),其余取 basename。
        XCTAssertEqual(DiskCapacity.label(forMountPoint: "/"), "macOS")
        XCTAssertEqual(DiskCapacity.label(forMountPoint: DiskCapacity.dataVolumeMountPoint), "数据卷")
        XCTAssertEqual(DiskCapacity.label(forMountPoint: "/System/Volumes/VM"), "虚拟内存")
        XCTAssertEqual(DiskCapacity.label(forMountPoint: "/System/Volumes/Update"), "系统更新")
        XCTAssertEqual(DiskCapacity.label(forMountPoint: "/Volumes/Backup"), "Backup")
    }

    // MARK: - ② 可清除(purgeable 两 key 差值)

    func testPurgeableIsImportantMinusFreeClampedAtZero() {
        // petal disk.rs:158-161:important − free,max(0)。
        let reading = DiskCapacity.make(from: raw(important: 6_610_000_000, free: 0))!
        XCTAssertEqual(reading.purgeableBytes, 6_610_000_000)
        // free > important(瞬时口径翻转):钳 0,不出负可清除。
        let clamped = DiskCapacity.make(from: raw(important: 100, free: 500))!
        XCTAssertEqual(clamped.purgeableBytes, 0)
    }

    func testPurgeableIsNilWhenEitherCapacityKeyMissing() {
        // 任一 key 读不到:可清除未知 → nil 占位,不伪造 0。
        XCTAssertNil(DiskCapacity.make(from: raw(important: nil, free: 100))?.purgeableBytes)
        XCTAssertNil(DiskCapacity.make(from: raw(important: 100, free: nil))?.purgeableBytes)
    }

    // MARK: - ③ 快照记录解析(petal 合成记录同款负例)

    /// 合成一条 fs_snapshot_list 记录(布局:u32 总长 | attribute_set_t 20B |
    /// attrreference_t 8B(名称相对偏移+长度含 NUL)| timespec 16B | 名称字节)。
    private func record(name: String, created: Int64) -> [UInt8] {
        let nameRef = 4 + MemoryLayout<attribute_set_t>.size
        let timeOffset = nameRef + MemoryLayout<attrreference_t>.size
        let nameBytes = Array(name.utf8) + [0] // 内核含结尾 NUL
        var bytes = [UInt8](repeating: 0, count: timeOffset + 16 + nameBytes.count)
        let length = UInt32(bytes.count)
        bytes.replaceSubrange(0..<4, with: withUnsafeBytes(of: length) { Array($0) })
        // attrreference_t:offset(i32,相对 attrreference_t 起始)+ length(u32)。
        let offset = Int32(timeOffset + 16 - nameRef)
        bytes.replaceSubrange(
            nameRef..<nameRef + 4,
            with: withUnsafeBytes(of: offset) { Array($0) }
        )
        bytes.replaceSubrange(
            nameRef + 4..<nameRef + 8,
            with: withUnsafeBytes(of: UInt32(nameBytes.count)) { Array($0) }
        )
        // timespec 16B:秒(i64)+ 纳秒(i64,置 0)——只写 8 字节会把数组缩掉一半。
        var timespec = withUnsafeBytes(of: created) { Array($0) }
        timespec.append(contentsOf: [UInt8](repeating: 0, count: 8))
        bytes.replaceSubrange(timeOffset..<timeOffset + 16, with: timespec)
        bytes.replaceSubrange((timeOffset + 16)..<bytes.count, with: nameBytes)
        return bytes
    }

    func testSnapshotRecordParsesNameAndCreationTime() {
        let snapshot = DiskSnapshotRecord.parse(
            record(name: "com.apple.TimeMachine.2026-10-15-030000.local", created: 1_760_500_000)
        )
        XCTAssertEqual(snapshot?.name, "com.apple.TimeMachine.2026-10-15-030000.local")
        XCTAssertEqual(snapshot?.createdEpoch, 1_760_500_000)
        XCTAssertEqual(snapshot?.isTimeMachine, true)
    }

    func testSnapshotRecordRejectsTruncatedAndMalformed() {
        let full = record(name: "com.apple.os.update-1", created: 42)
        // 截断记录跳过不误读(petal 同款负例);最短合法长度之下直接 nil。
        XCTAssertNil(DiskSnapshotRecord.parse(full.prefix(DiskSnapshotRecord.minimumLength - 1)))
        XCTAssertNil(DiskSnapshotRecord.parse([]))
        // 名称长度指向越界:拒绝。
        var escaping = record(name: "x", created: 1)
        let nameRef = 4 + MemoryLayout<attribute_set_t>.size
        let bogus = UInt32(1 << 30)
        escaping.replaceSubrange(
            nameRef + 4..<nameRef + 8, with: withUnsafeBytes(of: bogus) { Array($0) }
        )
        XCTAssertNil(DiskSnapshotRecord.parse(escaping))
    }

    func testSnapshotBufferParsesMultipleRecordsOldestFirst() {
        // 两条背靠背记录:按创建时间升序(旧 → 新,petal 排序口径)。
        let old = record(name: "com.apple.TimeMachine.2026-10-14-030000.local", created: 1_760_000_000)
        let new = record(name: "com.apple.TimeMachine.2026-10-15-030000.local", created: 1_760_500_000)
        let buffer = new + old // 故意倒序注入,断言重排
        let snapshots = DiskSnapshotRecord.parseBuffer(buffer, count: 2)
        XCTAssertEqual(snapshots.map(\.createdEpoch), [1_760_000_000, 1_760_500_000])
        XCTAssertTrue(snapshots.allSatisfy(\.isTimeMachine))
    }

    func testSnapshotBufferIgnoresCountBeyondContent() {
        // count 谎报大于实际内容:越界读在缓冲边界截停,不崩。
        let one = record(name: "a", created: 1)
        XCTAssertEqual(DiskSnapshotRecord.parseBuffer(one, count: 99).count, 1)
        XCTAssertEqual(DiskSnapshotRecord.parseBuffer([], count: 3), [])
    }

    func testSnapshotKindRecognition() {
        // TM 前缀识别(petal disk.rs:55-57)+ 其余来源映射。
        XCTAssertEqual(
            DiskSnapshot(name: "com.apple.TimeMachine.2026-10-15-030000.local", createdEpoch: 0).kindTitle,
            "Time Machine"
        )
        XCTAssertEqual(
            DiskSnapshot(name: "com.apple.os.update-26.1", createdEpoch: 0).kindTitle,
            "macOS 更新"
        )
        XCTAssertEqual(
            DiskSnapshot(name: "com.bombich.ccc.sentinel", createdEpoch: 0).kindTitle,
            "Carbon Copy Cloner"
        )
        XCTAssertEqual(DiskSnapshot(name: "com.example.snapshot", createdEpoch: 0).kindTitle, "其他应用")
    }

    // MARK: - ④ 吞吐差分(stats ActivityReader 同款防护)

    private func counters(read: UInt64, write: UInt64, uptime: UInt64) -> DiskIOCounters {
        DiskIOCounters(readBytes: read, writeBytes: write, atUptimeNanos: uptime)
    }

    func testThroughputFirstReadEstablishesBaselineAtZeroRates() {
        // 首读置零(只立基线,不出速率)。
        XCTAssertEqual(
            DiskThroughputDiffer.rates(previous: nil, current: counters(read: 1000, write: 500, uptime: 1_000_000_000)),
            .zero
        )
    }

    func testThroughputRatesDivideDeltaByElapsedSeconds() {
        // 正常差分:Δread=600B / 2s = 300 B/s;Δwrite=300B / 2s = 150 B/s。
        let rates = DiskThroughputDiffer.rates(
            previous: counters(read: 400, write: 200, uptime: 3_000_000_000),
            current: counters(read: 1_000, write: 500, uptime: 5_000_000_000)
        )
        XCTAssertEqual(rates.readBytesPerSecond, 300, accuracy: 1e-9)
        XCTAssertEqual(rates.writeBytesPerSecond, 150, accuracy: 1e-9)
    }

    func testThroughputCounterRollbackClampsToZeroAndResetsBaseline() {
        // 计数回退/重置:本轮 0(不把回退当巨大 IO);基线以本轮为准,
        // 下一轮自动恢复速率(Accumulator.record 语义,见下)。
        let rates = DiskThroughputDiffer.rates(
            previous: counters(read: 5_000, write: 5_000, uptime: 1_000_000_000),
            current: counters(read: 100, write: 200, uptime: 6_000_000_000)
        )
        XCTAssertEqual(rates, .zero)
    }

    func testThroughputZeroElapsedClampsToZero() {
        // uptime 未前进(elapsed = 0):除零防护钳 0。
        XCTAssertEqual(
            DiskThroughputDiffer.rates(
                previous: counters(read: 100, write: 100, uptime: 5),
                current: counters(read: 200, write: 200, uptime: 5)
            ),
            .zero
        )
    }

    func testThroughputIdenticalCountersYieldZeroRatesWithoutBaselineReset() {
        // 计数原地(无 IO):速率 0,基线照常推进(与回退不同路径)。
        let rates = DiskThroughputDiffer.rates(
            previous: counters(read: 1_000, write: 1_000, uptime: 1_000_000_000),
            current: counters(read: 1_000, write: 1_000, uptime: 6_000_000_000)
        )
        XCTAssertEqual(rates, .zero)
    }

    func testThroughputJumpBeyondPhysicalCapIsDroppedNotCounted() {
        // 求和回退档:某进程上轮计数缺席、本轮带着终身累计进账,和值一轮跳上百 GB——
        // 超过单轮上限(20 GB/s × 实际间隔)整轮作废为 0,不出尖峰、不进记账
        // (arch-review-2026-10-18/03 甲8,参照网络差分的跳变防护)。
        let jump = DiskThroughputDiffer.rates(
            previous: counters(read: 0, write: 0, uptime: 1_000_000_000),
            current: counters(read: 900_000_000_000, write: 0, uptime: 31_000_000_000)
        )
        XCTAssertEqual(jump, .zero)

        // 上限以内的大流量照常出数:30s 里读 150 GB = 5 GB/s。
        let heavy = DiskThroughputDiffer.rates(
            previous: counters(read: 0, write: 0, uptime: 1_000_000_000),
            current: counters(read: 150_000_000_000, write: 0, uptime: 31_000_000_000)
        )
        XCTAssertEqual(heavy.readBytesPerSecond, 5_000_000_000, accuracy: 1)
    }

    func testAccumulatorBooksNoIncrementForADroppedJump() {
        // 作废轮的记账增量同为 0(速率与增量同真同零),基线照常推进到本轮。
        let accumulator = DiskThroughputAccumulator()
        _ = accumulator.record(counters(read: 0, write: 0, uptime: 1_000_000_000))
        let dropped = accumulator.record(counters(read: 900_000_000_000, write: 0, uptime: 31_000_000_000))
        let next = accumulator.record(counters(read: 900_000_003_000, write: 0, uptime: 32_000_000_000))

        XCTAssertEqual(dropped.readBytesDelta, 0)
        XCTAssertEqual(next.readBytesDelta, 3_000, "基线已推进到跳变后的计数")
    }

    // MARK: - 吞吐 Accumulator(基线推进 + 走势环形窗)

    func testAccumulatorRecoversRatesAfterRollback() {
        // 回退后基线已重立:下一轮差分从新基线起算(stats samples 同款)。
        let accumulator = DiskThroughputAccumulator()
        _ = accumulator.record(counters(read: 5_000, write: 0, uptime: 1_000_000_000)) // 首读
        _ = accumulator.record(counters(read: 100, write: 0, uptime: 2_000_000_000))   // 回退 → 0
        let recovered = accumulator.record(counters(read: 1_100, write: 0, uptime: 3_000_000_000))
        XCTAssertEqual(recovered.current.readBytesPerSecond, 1_000, accuracy: 1e-9)
        // 走势三点齐全(首读 0 / 回退 0 / 恢复 1000)。
        XCTAssertEqual(recovered.trend.count, 3)
        XCTAssertEqual(recovered.trend.last?.read ?? -1, 1_000, accuracy: 1e-9)
    }

    func testAccumulatorTrendCapsAtCapacityAndKeepsNewest() {
        // 走势窗 60 点:超过容量丢最旧(环形),时间序保持旧 → 新。
        let accumulator = DiskThroughputAccumulator()
        for tick in 0...70 {
            _ = accumulator.record(counters(read: UInt64(tick) * 1_000, write: 0, uptime: UInt64(tick) * 1_000_000_000))
        }
        let reading = accumulator.record(counters(read: 72_000, write: 0, uptime: 72_000_000_000))
        XCTAssertEqual(reading.trend.count, DiskThroughputAccumulator.trendCapacity)
        XCTAssertEqual(reading.trend.last?.read ?? -1, 1_000, accuracy: 1e-9) // 第 72 点:Δ1000/1s
    }

    // MARK: - 吞吐记账增量(评审接线:历史落库消费,与网络增量同口径)

    func testAccumulatorCarriesByteDeltasOnSuccessAndZeroOnDroppedRounds() {
        // 成功轮:速率非零时增量 = 计数差(600B/300B)。
        let accumulator = DiskThroughputAccumulator()
        _ = accumulator.record(counters(read: 400, write: 200, uptime: 1_000_000_000)) // 首读
        let good = accumulator.record(counters(read: 1_000, write: 500, uptime: 6_000_000_000))
        XCTAssertEqual(good.readBytesDelta, 600)
        XCTAssertEqual(good.writeBytesDelta, 300)

        // 回退轮:速率钳零,增量同轮为 0(不把回退记成负数或巨大 IO)。
        let rolledBack = accumulator.record(counters(read: 100, write: 100, uptime: 7_000_000_000))
        XCTAssertEqual(rolledBack.readBytesDelta, 0)
        XCTAssertEqual(rolledBack.writeBytesDelta, 0)

        // 恢复轮从新基线起算:增量与速率同真。
        let recovered = accumulator.record(counters(read: 1_100, write: 600, uptime: 8_000_000_000))
        XCTAssertEqual(recovered.readBytesDelta, 1_000)
        XCTAssertEqual(recovered.writeBytesDelta, 500)

        // 真无 IO 轮:速率为 0 且增量如实为 0(与丢弃轮同形,语义都正确)。
        let idle = accumulator.record(counters(read: 1_100, write: 600, uptime: 9_000_000_000))
        XCTAssertEqual(idle.readBytesDelta, 0)
        XCTAssertEqual(idle.writeBytesDelta, 0)
    }

    func testAccumulatorFirstReadingCarriesZeroDeltas() {
        let accumulator = DiskThroughputAccumulator()
        let first = accumulator.record(counters(read: 9_999, write: 9_999, uptime: 1_000_000_000))
        XCTAssertEqual(first.readBytesDelta, 0, "首读只立基线,增量 0")
        XCTAssertEqual(first.writeBytesDelta, 0)
    }

    // MARK: - 格式化(Finder 同刻对照的口径基础)

    func testDiskCapacityFormatsDecimalGigabytes() {
        // 十进制 GB 两位小数(Finder 口径,探针①"209.55 GB"同款)。
        XCTAssertEqual(PulseFormat.diskCapacity(209_550_000_000), "209.55 GB")
        XCTAssertEqual(PulseFormat.diskCapacityFigure(284_700_123_456).value, "284.70")
        XCTAssertEqual(PulseFormat.diskCapacityFigure(284_700_123_456).unit, "GB")
    }

    func testDiskRateFormatsHumanReadableTiers() {
        XCTAssertEqual(PulseFormat.diskRate(300), "0.3 KB/s")
        XCTAssertEqual(PulseFormat.diskRate(12_400_000), "12.4 MB/s")
        XCTAssertEqual(PulseFormat.diskRate(1_234_000_000), "1.2 GB/s")
        XCTAssertEqual(PulseFormat.diskRate(0), "0.0 KB/s")
        XCTAssertEqual(PulseFormat.diskRate(-5), "0.0 KB/s", "负值钳 0")
    }
}
