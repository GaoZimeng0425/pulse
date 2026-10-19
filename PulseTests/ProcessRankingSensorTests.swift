import Darwin
import XCTest
@testable import Pulse

/// 工单 01 模块排行(数据层)+ 架构审查票 A 高2(rusage 采集通道合一):
/// 能耗影响 / 磁盘每进程两本差分账本直接吃心跳快照(全进程 rusage 循环只剩
/// LiveProcessSource 一处),系统级求和回退源经心跳中继取同一张快照。
/// 合成快照按序喂入,零真实采样;核心断言六组:
/// ①能耗差分:首见 pid 记基线不出数、ΔCPU/Δ唤醒/复合分、负差分钳 0、
///   消失 pid 丢弃;
/// ②满窗出数:未满窗不出数且基线不推进(差分跨整窗),两窗(5s/30s)各自独立;
///   满窗容差;墙钟回拨与心跳断档(睡眠)重立基线;
/// ③磁盘每进程差分:速率对实际墙钟间隔折算(transition-not-tick)、回退钳零;
/// ④清账:reset 后首轮只记基线;
/// ⑤快照 → rusage 表映射(计数读失败的 pid 跳过不填 0)与心跳中继;
/// ⑥求和回退源:消费中继快照求和,计数时刻取发布时刻,首轮前如实 nil。
final class ProcessRankingSensorTests: XCTestCase {

    // MARK: - 夹具

    /// 合成一张心跳快照:takenAt 用合成时间轴(seconds),供差分确定性编排。
    private func snapshot(
        at seconds: TimeInterval,
        _ entries: (pid: pid_t, cpu: UInt64, wakeups: UInt64, read: UInt64, write: UInt64)...
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            takenAt: Date(timeIntervalSinceReferenceDate: seconds),
            processes: entries.map { entry in
                RawProcess(
                    pid: entry.pid,
                    parentPID: 1,
                    cpuTimeNanoseconds: entry.cpu,
                    diskBytesRead: entry.read,
                    diskBytesWritten: entry.write,
                    wakeups: entry.wakeups
                )
            }
        )
    }

    /// 计数读失败的进程(Live 源:TASKINFO / rusage 任一失败,字段记 0)。
    private func unreadable(_ pid: pid_t) -> RawProcess {
        RawProcess(pid: pid, parentPID: 1, countersAvailable: false)
    }

    /// 按序喂入快照,返回逐轮产出。
    private func feed(_ snapshots: [ProcessSnapshot]) -> [ProcessRankingRound] {
        var ledgers = ProcessRankingLedgers()
        return snapshots.map { ledgers.record($0) }
    }

    // MARK: - ① 能耗影响差分

    func testEnergyFirstRoundEstablishesBaselineWithoutNumbers() {
        // 首见 pid(整表首趟)只记基线:两窗都不出数。
        let rounds = feed([snapshot(at: 0, (100, 1_000, 5, 0, 0))])
        XCTAssertEqual(rounds, [.empty], "基线轮不出数")
    }

    func testEnergyDiffsCpuAndWakeupsAndComposesImpact() {
        // ΔCPU = 1.5s − 1.0s = 0.5s;Δ唤醒 = 12 − 10 = 2;
        // 复合分 = 0.5s + 2 × 50ms = 0.6s。
        let rounds = feed([
            snapshot(at: 0, (100, 1_000_000_000, 10, 0, 0)),
            snapshot(at: 5, (100, 1_500_000_000, 12, 0, 0)),
        ])
        let impact = rounds[1].energyImpacts?[100]
        XCTAssertEqual(impact?.cpuNanosDelta, 500_000_000)
        XCTAssertEqual(impact?.wakeupsDelta, 2)
        XCTAssertEqual(impact?.impact, 500_000_000 + 2 * ProcessEnergyImpact.nanosecondsPerWakeup)
    }

    func testEnergyNegativeDeltaClampsToZero() {
        // 计数回退(回绕/重置):两项负差分都钳 0,复合分随之 0。
        let rounds = feed([
            snapshot(at: 0, (100, 5_000, 50, 0, 0)),
            snapshot(at: 5, (100, 100, 7, 0, 0)),
        ])
        let impact = rounds[1].energyImpacts?[100]
        XCTAssertEqual(impact?.cpuNanosDelta, 0)
        XCTAssertEqual(impact?.wakeupsDelta, 0)
        XCTAssertEqual(impact?.impact, 0)
    }

    func testEnergyNewPIDStaysBaselineAndVanishedPIDDrops() {
        // 新 pid 记基线不出数;消失 pid 丢弃;基线整表以满窗轮为准——
        // 复现的 pid 按新面孔重记基线(pid 复用安全)。
        let rounds = feed([
            snapshot(at: 0, (100, 1_000, 1, 0, 0)),
            snapshot(at: 5, (100, 2_000, 2, 0, 0), (200, 5_000, 1, 0, 0)),  // 200 新面孔
            snapshot(at: 10, (200, 6_000, 2, 0, 0)),                        // 100 消失
            snapshot(at: 15, (200, 7_000, 3, 0, 0), (100, 9_000, 9, 0, 0)), // 100 复现
        ])
        XCTAssertEqual(rounds[1].energyImpacts.map { Array($0.keys).sorted() }, [100], "新 pid 200 记基线,不出数")
        XCTAssertEqual(rounds[2].energyImpacts.map { Array($0.keys).sorted() }, [200], "消失的 100 丢弃;200 出差分")
        XCTAssertEqual(rounds[3].energyImpacts.map { Array($0.keys).sorted() }, [200], "复现的 100 重新记基线,不出数")
        XCTAssertEqual(rounds[3].energyImpacts?[200]?.wakeupsDelta, 1)
    }

    // MARK: - ② 满窗出数(心跳 1s/5s 之上的 5s/30s 窗)

    func testEnergyWindowHoldsBaselineUntilFull() {
        // 弹窗开 = 1s 心跳:未满 5s 的轮不出数,且基线不推进——满窗那轮的
        // 差分跨整窗(0 → 5s 的全部增量),不是最后 1s 的增量。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 0, 0)),
            snapshot(at: 1, (100, 100, 0, 0, 0)),
            snapshot(at: 2, (100, 200, 0, 0, 0)),
            snapshot(at: 3, (100, 300, 0, 0, 0)),
            snapshot(at: 4, (100, 400, 0, 0, 0)),
            snapshot(at: 5, (100, 500, 0, 0, 0)),
            snapshot(at: 6, (100, 600, 0, 0, 0)),
        ])
        for index in 1...4 {
            XCTAssertNil(rounds[index].energyImpacts, "第 \(index)s 未满窗不出数")
        }
        XCTAssertEqual(rounds[5].energyImpacts?[100]?.cpuNanosDelta, 500, "满窗差分跨整窗")
        XCTAssertNil(rounds[6].energyImpacts, "满窗后以本轮重立基线,新窗重新计")
    }

    func testEnergyRoundCarriesTheActualWindowLength() {
        // 弹窗开合让心跳在窗中途 1s → 5s 切换:满窗那轮实际跨 8s,不是标称 5s——
        // 能耗读数带上实际窗长,唤醒/秒按它折算(架构审查 arch-review-2026-10-18/01 L1)。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 0, 0)),
            snapshot(at: 3, (100, 100, 4, 0, 0)),
            snapshot(at: 8, (100, 200, 16, 0, 0)),
        ])
        XCTAssertNil(rounds[1].energyWindowSeconds, "未满窗不带窗长")
        XCTAssertEqual(rounds[2].energyWindowSeconds ?? 0, 8, accuracy: 1e-9)
        XCTAssertEqual(rounds[2].energyImpacts?[100]?.wakeupsDelta, 16)
    }

    func testDiskWindowIsIndependentOfEnergyWindow() {
        // 5s 心跳下能耗每轮出数,磁盘 30s 窗只在第 30s 出数,速率按 30s 折算。
        let rounds = feed(stride(from: 0, through: 30, by: 5).map { second in
            snapshot(at: TimeInterval(second), (100, UInt64(second) * 10, 0, UInt64(second) * 100, 0))
        })
        for index in 1...6 {
            XCTAssertNotNil(rounds[index].energyImpacts, "第 \(index * 5)s 能耗满窗")
        }
        for index in 1...5 {
            XCTAssertNil(rounds[index].diskRates, "第 \(index * 5)s 磁盘未满 30s 窗")
        }
        XCTAssertEqual(rounds[6].diskRates?[100]?.readBytesPerSec ?? -1, 100, accuracy: 1e-9)
    }

    func testClockSteppingBackwardsRebaselines() {
        // 墙钟回拨(NTP 校时):间隔为负,两窗以本轮重立基线不出数;
        // 此后按新基线正常满窗。
        let rounds = feed([
            snapshot(at: 100, (100, 1_000, 0, 0, 0)),
            snapshot(at: 50, (100, 2_000, 0, 0, 0)),
            snapshot(at: 55, (100, 2_500, 0, 0, 0)),
        ])
        XCTAssertEqual(rounds[1], .empty, "回拨轮不出数")
        XCTAssertEqual(rounds[2].energyImpacts?[100]?.cpuNanosDelta, 500, "按回拨后的基线差分")
    }

    func testSlightlyShortIntervalStillClosesWindow() {
        // 满窗容差:轮距比窗长短一点(4.9s)仍满窗——5s 心跳下调度抖动不会让
        // 能耗窗翻倍成 10s(唤醒/秒随之腰斩)。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 0, 0)),
            snapshot(at: 4.9, (100, 490, 0, 0, 0)),
        ])
        XCTAssertEqual(rounds[1].energyImpacts?[100]?.cpuNanosDelta, 490)
    }

    func testHeartbeatGapRebaselinesInsteadOfSpanningIt() {
        // 心跳断档(合盖 1h,睡眠后首轮先于唤醒清账通知到达):间隔超出窗长
        // 上限,以本轮重立基线不出数——不把 1h 累计当 5s 能耗显示;下一窗正常。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 0, 0)),
            snapshot(at: 3_600, (100, 900_000_000_000, 0, 9_000_000, 0)),
            snapshot(at: 3_605, (100, 900_000_000_500, 0, 9_000_000, 0)),
        ])
        XCTAssertEqual(rounds[1], .empty, "断档轮不出数(两窗皆然)")
        XCTAssertEqual(rounds[2].energyImpacts?[100]?.cpuNanosDelta, 500, "按断档后的基线差分")
    }

    func testMidWindowCadenceSwitchStillEmits() {
        // 弹窗关闭让心跳在窗中途 1s → 5s:单窗最长约 9s,仍在上限内照常出数。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 0, 0)),
            snapshot(at: 4, (100, 400, 0, 0, 0)),
            snapshot(at: 9.1, (100, 910, 0, 0, 0)),
        ])
        XCTAssertNil(rounds[1].energyImpacts, "4s 未满窗")
        XCTAssertEqual(rounds[2].energyImpacts?[100]?.cpuNanosDelta, 910)
    }

    func testWindowContract() {
        // 节奏契约(工单 01):能耗 5s 一档,磁盘每进程 30s 一档(卡底注脚同口径)。
        XCTAssertEqual(ProcessRankingLedgers.energyWindow, 5)
        XCTAssertEqual(ProcessRankingLedgers.diskWindow, 30)
    }

    // MARK: - ③ 磁盘每进程差分

    func testDiskRatesDivideDeltaByActualElapsed() {
        // transition-not-tick:实际间隔 32s(不是标称 30s),
        // Δread 3_200 / 32s = 100 B/s;Δwrite 1_600 / 32s = 50 B/s。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 400, 200)),
            snapshot(at: 32, (100, 0, 0, 3_600, 1_800)),
        ])
        XCTAssertEqual(rounds[1].diskRates?[100]?.readBytesPerSec ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(rounds[1].diskRates?[100]?.writeBytesPerSec ?? -1, 50, accuracy: 1e-9)
    }

    func testDiskRollbackClampsToZeroAndVanishedPIDDrops() {
        // 计数回退:速率钳 0;消失 pid 不出现在读数里。
        let rounds = feed([
            snapshot(at: 0, (100, 0, 0, 5_000, 5_000), (200, 0, 0, 100, 100)),
            snapshot(at: 30, (100, 0, 0, 100, 200)),
        ])
        XCTAssertEqual(rounds[1].diskRates.map { Array($0.keys).sorted() }, [100])
        XCTAssertEqual(rounds[1].diskRates?[100]?.readBytesPerSec ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(rounds[1].diskRates?[100]?.writeBytesPerSec ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: - ④ 清账

    func testResetMakesNextRoundBaselineOnly() {
        // 隐藏/唤醒清账:重开首轮重新记基线(不出数),再满窗恢复正常差分——
        // 不出横跨隐藏期的巨差(隐藏期计数照旧累计)。
        var ledgers = ProcessRankingLedgers()
        _ = ledgers.record(snapshot(at: 0, (100, 1_000, 0, 0, 0)))
        XCTAssertEqual(ledgers.record(snapshot(at: 5, (100, 2_000, 0, 0, 0))).energyImpacts?[100]?.cpuNanosDelta, 1_000)

        ledgers.reset()
        XCTAssertEqual(ledgers.record(snapshot(at: 3_600, (100, 3_000, 0, 0, 0))), .empty, "重开首轮只记基线")
        XCTAssertEqual(
            ledgers.record(snapshot(at: 3_605, (100, 4_000, 0, 0, 0))).energyImpacts?[100]?.cpuNanosDelta,
            1_000,
            "恢复轮按正常 5s 窗差分"
        )
    }

    // MARK: - ⑤ 快照 → rusage 表与心跳中继

    func testRusageTableMapsSnapshotFields() {
        let table = ProcessRusageTable(snapshot: snapshot(at: 7, (100, 1_234, 56, 789, 10)))
        XCTAssertEqual(table.takenAt, Date(timeIntervalSinceReferenceDate: 7))
        XCTAssertEqual(
            table.samples[100],
            ProcessRusageSample(cpuNanoseconds: 1_234, wakeups: 56, diskBytesRead: 789, diskBytesWritten: 10)
        )
    }

    func testUnreadableCountersAreSkippedNotZeroFilled() {
        // 计数读失败的 pid 不以 0 入表:基线轮失败、满窗轮恢复时,该 pid 按
        // 新面孔记基线不出数——不把进程终身累计(1h CPU)当一窗增量;
        // 下一窗恢复正常差分。
        var ledgers = ProcessRankingLedgers()
        let at0 = ProcessSnapshot(
            takenAt: Date(timeIntervalSinceReferenceDate: 0),
            processes: [unreadable(100)]
        )
        XCTAssertNil(ProcessRusageTable(snapshot: at0).samples[100], "读失败 pid 不入表")
        _ = ledgers.record(at0)
        let recovered = ledgers.record(snapshot(at: 5, (100, 3_600_000_000_000, 0, 0, 0)))
        XCTAssertNil(recovered.energyImpacts?[100], "恢复轮按新面孔记基线,不出终身累计")
        let next = ledgers.record(snapshot(at: 10, (100, 3_600_000_000_500, 0, 0, 0)))
        XCTAssertEqual(next.energyImpacts?[100]?.cpuNanosDelta, 500)
    }

    func testHeartbeatRelayIsEmptyUntilFirstPublish() {
        // 心跳首轮前无快照:如实 nil(消费方保 lastGood / 占位),不伪造全零。
        XCTAssertNil(HeartbeatRusageRelay().latest())
    }

    func testHeartbeatRelayServesLatestPublishedSnapshot() {
        let relay = HeartbeatRusageRelay()
        relay.publish(snapshot(at: 0, (100, 0, 0, 1, 1)), atUptimeNanos: 1)
        relay.publish(snapshot(at: 5, (100, 0, 0, 300, 75)), atUptimeNanos: 2)
        let latest = relay.latest()
        XCTAssertEqual(latest?.snapshot.takenAt, Date(timeIntervalSinceReferenceDate: 5), "取最新一轮")
        XCTAssertEqual(latest?.uptimeNanos, 2)
    }

    // MARK: - ⑥ 系统级求和回退源

    func testSumSourceAddsPerPIDBytesAcrossSnapshot() {
        // 求和回退源消费中继快照:各 pid 磁盘字节逐项相加;读失败 pid 不计。
        let relay = HeartbeatRusageRelay()
        relay.publish(ProcessSnapshot(
            takenAt: Date(timeIntervalSinceReferenceDate: 0),
            processes: snapshot(at: 0, (100, 0, 0, 100, 50), (200, 0, 0, 200, 25)).processes
                + [unreadable(300)]
        ))
        let counters = RusageSumDiskThroughputSource(heartbeat: relay).readCounters()
        XCTAssertEqual(counters?.readBytes, 300)
        XCTAssertEqual(counters?.writeBytes, 75)
    }

    func testSumSourceStampsCountersWithPublishTimeNotReadTime() {
        // 计数时刻 = 心跳采到(发布)的时刻:30s 档读中继时快照最多旧一个
        // 心跳,若按读的时刻折算,速率随相位漂移出 ±17% 锯齿。
        let relay = HeartbeatRusageRelay()
        relay.publish(snapshot(at: 0, (100, 0, 0, 100, 50)), atUptimeNanos: 42)
        XCTAssertEqual(RusageSumDiskThroughputSource(heartbeat: relay).readCounters()?.atUptimeNanos, 42)
    }

    func testSumSourceReportsNilBeforeFirstHeartbeat() {
        // 心跳首轮前:读失败如实上报(nil → 消费方保 lastGood),不伪造全零计数。
        XCTAssertNil(RusageSumDiskThroughputSource(heartbeat: HeartbeatRusageRelay()).readCounters())
    }
}
