import Darwin
import XCTest
@testable import Pulse

/// 工单 01 模块排行(数据层):能耗影响 / 磁盘每进程两个 rusage 差分源 +
/// 共享 rusage 表源之上的系统级求和回退源。缝上纯逻辑合成夹具单测——
/// 表按序注入,零真实采样;核心断言五组:
/// ①能耗差分:首见 pid 记基线不出数、ΔCPU/Δ唤醒/复合分、负差分钳 0、
///   消失 pid 丢弃;
/// ②磁盘每进程差分:速率对两趟墙钟间隔折算(transition-not-tick)、回退钳零;
/// ③可见性门控:关 = 源零调用、隐藏清账重开首轮只记基线;
/// ④求和回退源:消费同一趟 per-pid 表求和,行为同旧全进程循环;
/// ⑤Live 源冒烟:构造 + 一趟真实表(只验可用,不做语义断言)。
final class ProcessRankingSensorTests: XCTestCase {

    // MARK: - 测试替身与夹具

    /// 脚本化 per-pid rusage 表源:按序吐出注入表,耗尽后停在 nil(读失败);
    /// 记录调用次数(门控断言用)。
    private final class ScriptedRusageTableSource: ProcessRusageTableSource, @unchecked Sendable {
        private let lock = NSLock()
        private let tables: [ProcessRusageTable?]
        private var index = 0
        private var reads = 0

        init(_ tables: [ProcessRusageTable?]) {
            self.tables = tables
        }

        func readTable() -> ProcessRusageTable? {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            guard index < tables.count else { return nil }
            defer { index += 1 }
            return tables[index]
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    /// 合成一趟 rusage 表:takenAt 用合成时间轴(seconds),供差分确定性编排。
    private func table(
        at seconds: TimeInterval,
        _ entries: (pid: pid_t, cpu: UInt64, wakeups: UInt64, read: UInt64, write: UInt64)...
    ) -> ProcessRusageTable {
        var samples: [pid_t: ProcessRusageSample] = [:]
        for entry in entries {
            samples[entry.pid] = ProcessRusageSample(
                cpuNanoseconds: entry.cpu,
                wakeups: entry.wakeups,
                diskBytesRead: entry.read,
                diskBytesWritten: entry.write
            )
        }
        return ProcessRusageTable(takenAt: Date(timeIntervalSinceReferenceDate: seconds), samples: samples)
    }

    // MARK: - ① 能耗影响差分

    func testEnergyFirstRoundEstablishesBaselineWithoutNumbers() async {
        // 首见 pid(整表首趟)只记基线:读数 nil,lastGood 也不存。
        let source = ScriptedRusageTableSource([table(at: 0, (100, 1_000, 5, 0, 0))])
        let provider = ProcessEnergyImpactProvider(source: source)
        provider.setVisible(true)

        let first = await provider.snapshot()
        XCTAssertNil(first, "基线轮不出数")
        XCTAssertNil(provider.lastGood)
    }

    func testEnergyDiffsCpuAndWakeupsAndComposesImpact() async {
        // ΔCPU = 1.5s − 1.0s = 0.5s;Δ唤醒 = 12 − 10 = 2;
        // 复合分 = 0.5s + 2 × 50ms = 0.6s。
        let source = ScriptedRusageTableSource([
            table(at: 0, (100, 1_000_000_000, 10, 0, 0)),
            table(at: 5, (100, 1_500_000_000, 12, 0, 0)),
        ])
        let provider = ProcessEnergyImpactProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let second = await provider.snapshot()

        let impact = second?[100]
        XCTAssertEqual(impact?.cpuNanosDelta, 500_000_000)
        XCTAssertEqual(impact?.wakeupsDelta, 2)
        XCTAssertEqual(impact?.impact, 500_000_000 + 2 * ProcessEnergyImpactAccumulator.nanosecondsPerWakeup)
        XCTAssertEqual(provider.lastGood?[100]?.impact, impact?.impact, "成功轮入 lastGood")
    }

    func testEnergyNegativeDeltaClampsToZero() async {
        // 计数回退(回绕/重置):两项负差分都钳 0,复合分随之 0。
        let source = ScriptedRusageTableSource([
            table(at: 0, (100, 5_000, 50, 0, 0)),
            table(at: 5, (100, 100, 7, 0, 0)),
        ])
        let provider = ProcessEnergyImpactProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let second = await provider.snapshot()

        XCTAssertEqual(second?[100]?.cpuNanosDelta, 0)
        XCTAssertEqual(second?[100]?.wakeupsDelta, 0)
        XCTAssertEqual(second?[100]?.impact, 0)
    }

    func testEnergyNewPIDStaysBaselineAndVanishedPIDDrops() async {
        // 新 pid 记基线不出数;消失 pid 丢弃;基线整表以本轮为准——
        // 复现的 pid 按新面孔重记基线(pid 复用安全)。
        let source = ScriptedRusageTableSource([
            table(at: 0, (100, 1_000, 1, 0, 0)),
            table(at: 5, (100, 2_000, 2, 0, 0), (200, 5_000, 1, 0, 0)), // 200 新面孔
            table(at: 10, (200, 6_000, 2, 0, 0)),                       // 100 消失
            table(at: 15, (200, 7_000, 3, 0, 0), (100, 9_000, 9, 0, 0)), // 100 复现
        ])
        let provider = ProcessEnergyImpactProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let second = await provider.snapshot()
        XCTAssertEqual(second.map { Array($0.keys).sorted() }, [100], "新 pid 200 记基线,不出数")
        let third = await provider.snapshot()
        XCTAssertEqual(third.map { Array($0.keys).sorted() }, [200], "消失的 100 丢弃;200 出差分")
        let fourth = await provider.snapshot()
        XCTAssertEqual(fourth.map { Array($0.keys).sorted() }, [200], "复现的 100 重新记基线,不出数")
        XCTAssertEqual(fourth?[200]?.wakeupsDelta, 1)
    }

    // MARK: - ② 磁盘每进程差分

    func testDiskRatesDivideDeltaByWallClockElapsed() async {
        // transition-not-tick:两趟实际间隔 2s(不是标称 30s),
        // Δread 600 / 2s = 300 B/s;Δwrite 300 / 2s = 150 B/s。
        let source = ScriptedRusageTableSource([
            table(at: 0, (100, 0, 0, 400, 200)),
            table(at: 2, (100, 0, 0, 1_000, 500)),
        ])
        let provider = ProcessDiskRateProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let second = await provider.snapshot()

        XCTAssertEqual(second?[100]?.readBytesPerSec ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(second?[100]?.writeBytesPerSec ?? -1, 150, accuracy: 1e-9)
    }

    func testDiskRollbackClampsToZeroAndVanishedPIDDrops() async {
        // 计数回退:速率钳 0(基线以本轮重立);消失 pid 不出现在读数里。
        let source = ScriptedRusageTableSource([
            table(at: 0, (100, 0, 0, 5_000, 5_000), (200, 0, 0, 100, 100)),
            table(at: 2, (100, 0, 0, 100, 200)),
        ])
        let provider = ProcessDiskRateProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let second = await provider.snapshot()

        XCTAssertEqual(second.map { Array($0.keys).sorted() }, [100])
        XCTAssertEqual(second?[100]?.readBytesPerSec ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(second?[100]?.writeBytesPerSec ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: - ③ 可见性门控与隐藏清账

    func testGateClosedSkipsSourceEntirely() async {
        // 门关 = tick 在门口空转:源零调用(采样成本闸门的全部意义)。
        let source = ScriptedRusageTableSource([table(at: 0, (100, 1, 1, 0, 0))])
        let provider = ProcessEnergyImpactProvider(source: source)

        let reading = await provider.snapshot()
        XCTAssertNil(reading)
        XCTAssertEqual(source.callCount, 0, "门关时不碰源")
    }

    func testHideResetsBaselinesSoReopenRoundIsBaselineOnly() async {
        // 隐藏清账:重开首轮重新记基线(不出数),第二轮恢复正常差分——
        // 不出横跨隐藏期的巨差(隐藏期计数照旧累计)。
        let source = ScriptedRusageTableSource([
            table(at: 0, (100, 1_000, 0, 0, 0)),
            table(at: 5, (100, 2_000, 0, 0, 0)),
            table(at: 3600, (100, 3_000, 0, 0, 0)), // 隐藏 1h 后的首轮
            table(at: 3605, (100, 4_000, 0, 0, 0)),
        ])
        let provider = ProcessEnergyImpactProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let beforeHide = await provider.snapshot()
        XCTAssertEqual(beforeHide?[100]?.cpuNanosDelta, 1_000)

        provider.setVisible(false) // 隐藏:清账
        provider.setVisible(true)
        let reopenFirst = await provider.snapshot()
        XCTAssertNil(reopenFirst, "重开首轮只记基线(1h 跨度不出巨差)")
        let reopenSecond = await provider.snapshot()
        XCTAssertEqual(reopenSecond?[100]?.cpuNanosDelta, 1_000, "恢复轮按正常 5s 窗差分")
        XCTAssertEqual(source.callCount, 4, "源调用数 = 快照轮数(隐藏期无 tick 调用)")
    }

    func testCadencesMatchTheTierContract() {
        // 节奏契约(工单 01):能耗/网络 5s,磁盘每进程 30s——调度器按此分档。
        XCTAssertEqual(ProcessEnergyImpactProvider(source: ScriptedRusageTableSource([])).cadence, .every(seconds: 5))
        XCTAssertEqual(ProcessDiskRateProvider(source: ScriptedRusageTableSource([])).cadence, .every(seconds: 30))
    }

    // MARK: - ④ 系统级求和回退源(共享一趟的重构行为)

    func testSumSourceAddsPerPIDBytesAcrossTable() {
        // 求和回退源消费同一趟 per-pid 表:各 pid 磁盘字节逐项相加,
        // 与旧"自己循环一遍"的读数等价。
        let source = RusageSumDiskThroughputSource(processRusage: ScriptedRusageTableSource([
            table(at: 0, (100, 0, 0, 100, 50), (200, 0, 0, 200, 25)),
        ]))
        let counters = source.readCounters()
        XCTAssertEqual(counters?.readBytes, 300)
        XCTAssertEqual(counters?.writeBytes, 75)
    }

    func testSumSourcePropagatesReadFailureAsNil() {
        // 进程列表读不到(nil 表):读失败如实上报(nil → 消费方保 lastGood),
        // 不伪造全零计数。
        let source = RusageSumDiskThroughputSource(processRusage: ScriptedRusageTableSource([nil]))
        XCTAssertNil(source.readCounters())
    }

    // MARK: - ⑤ Live 源冒烟(只验可用,不做语义断言)

    func testLiveRusageTableSweepResponds() {
        // 真机一趟:表非空、自身 pid 在列(受限 pid 跳过不中断的降级路径
        // 由 LiveProcessSourceSmokeTests 同款纪律覆盖)。
        let source = LiveProcessRusageTableSource()
        let table = source.readTable()
        XCTAssertNotNil(table)
        XCTAssertFalse(table?.samples.isEmpty ?? true, "本机应有可读进程")
        XCTAssertNotNil(table?.samples[getpid()], "测试宿主自身应可读")
    }
}
