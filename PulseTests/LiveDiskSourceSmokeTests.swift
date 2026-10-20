import XCTest
@testable import Pulse
@testable import PulseCore

/// 接缝:LiveDisk 两源冒烟(spec 测试决策:OS 边界只证明真实可用,不深测——
/// 纯逻辑已在 DiskSensorTests 钉死)。只读观察,真机走查/对照用;print 出的
/// 容量数值与 Finder 同刻对照即工单 05 验收锚点(探针①方法)。
final class LiveDiskSourceSmokeTests: XCTestCase {

    func testLiveCapacityReadsFinderCompatibleReconciliation() async throws {
        guard let raw = LiveDiskCapacitySource().read() else {
            throw XCTSkip("根卷读不到(非典型环境):容量卡整卡占位口径,跳过真读冒烟")
        }
        guard let reading = DiskCapacity.make(from: raw) else {
            throw XCTSkip("非现代 APFS 系统/数据卷组:容量读数 nil 口径,跳过")
        }
        print("[smoke] disk 容量: 卷名=\(reading.volumeName ?? "—")"
            + " 总量=\(PulseFormat.diskCapacity(reading.containerTotalBytes))"
            + " 已用=\(PulseFormat.diskCapacity(reading.containerUsedBytes))"
            + " 实际可用=\(reading.availableForImportantUsageBytes.map { PulseFormat.diskCapacity(UInt64(max(0, $0))) } ?? "—")"
            + " 可清除=\(reading.purgeableBytes.map { PulseFormat.diskCapacity(UInt64($0)) } ?? "—")")
        print("[smoke] disk 明细: " + ([reading.dataVolume] + reading.otherVolumes + [reading.unaccounted].compactMap { $0 })
            .map { "\($0.label)=\(PulseFormat.diskCapacity($0.usedBytes))" }.joined(separator: " "))
        // 核心不变式在真实数据上成立(petal 同款断言)。
        XCTAssertEqual(reading.accountedBytes, reading.containerUsedBytes, "各卷之和 + 其他卷 == 容器总量(真机)")
        // 实际可用必须为正(Finder「可用」口径)。
        let available = try XCTUnwrap(reading.availableForImportantUsageBytes)
        XCTAssertGreaterThan(available, 0)
        // 每卷已用均非零(密封系统卷/Preboot 等至少有元数据)。
        XCTAssertTrue((reading.otherVolumes).allSatisfy { $0.usedBytes > 0 })
    }

    func testLiveSnapshotListingIsHonest() throws {
        // 快照语义冒烟:unavailable 或 listing(含空)。探针②结论:免 root 可列,
        // 判成败看返回值不看 errno;本机当前无 TM 快照 → listing([]) 为常见真态。
        guard let raw = LiveDiskCapacitySource().read() else {
            throw XCTSkip("根卷读不到:容量卡整卡占位口径,跳过")
        }
        switch raw.snapshots {
        case .listing:
            break // 空列表 = 真无快照;非空 = 真有,皆合法
        case .unavailable:
            break // 读不到 = 占位口径,不伪造
        }
    }

    func testLiveThroughputDeliversMonotoneCounters() async throws {
        // 吞吐源冒烟:两次读,计数器单调不减(回退即防护钳零——回退源口径不同)。
        // 回退档取心跳中继(票 A 高2):每次读前发布一张新的真实心跳快照——
        // 否则两次读同一张,单调断言恒真,回退档等于没测。
        let relay = HeartbeatRusageRelay()
        let heartbeat = LiveProcessSource()
        let source = LiveDiskThroughputSource.adoptingBestPath(fallbackHeartbeat: relay)
        print("[smoke] disk 吞吐路径: cadence=\(source.cadenceSeconds)s (5=IORegistry 主路径 / 30=rusage 回退)")
        relay.publish(heartbeat.snapshot())
        let first = source.readCounters()
        relay.publish(heartbeat.snapshot())
        guard let first, let second = source.readCounters() else {
            throw XCTSkip("吞吐源读不到(非典型栈):rusage 回退也不可用,跳过")
        }
        XCTAssertGreaterThanOrEqual(second.readBytes, first.readBytes, "计数器应单调不减")
        XCTAssertGreaterThanOrEqual(second.writeBytes, first.writeBytes, "计数器应单调不减")
        // 差分一次(读数含走势点)。
        let accumulator = DiskThroughputAccumulator()
        let rates = accumulator.record(second)
        XCTAssertEqual(rates.trend.count, 1)
        XCTAssertGreaterThanOrEqual(rates.current.readBytesPerSecond, 0)
    }
}
