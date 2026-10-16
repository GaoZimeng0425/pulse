import XCTest
@testable import Pulse

/// 分钟卷积与留存计划(工单 03,纯逻辑 + 注入时间):聚合口径、跨窗冲刷、
/// 空窗不产出(不补零)、时钟回拨防护、按当地日的留存触发。
final class HistoryRollupTests: XCTestCase {
    /// 对齐到分钟边界的基准时刻(整秒 epoch,便于窗口断言)。
    private let minute0 = HistoryWindows.minuteStart(of: Date(timeIntervalSince1970: 1_789_000_000))

    private func seconds(_ n: Int) -> Date {
        minute0.addingTimeInterval(TimeInterval(n))
    }

    private func group(
        _ id: GroupIdentity, cpu: Double, mem: UInt64 = 1, procs: Int = 1
    ) -> GroupSample {
        GroupSample(id: id, cpuPercent: cpu, memoryBytes: mem, processCount: procs)
    }

    private func app(_ name: String) -> GroupIdentity {
        .app(bundlePath: "/Applications/\(name).app")
    }

    // MARK: 分钟卷积

    /// 同一分钟内的多个采样不冲刷——5s 原始值只留在内存缓冲。
    func testSamplesWithinOneMinuteProduceNoAggregate() {
        var buffer = MinuteRollupBuffer()

        XCTAssertNil(buffer.ingest(at: seconds(0), systemLoad: 10, groups: [group(app("A"), cpu: 10)]))
        XCTAssertNil(buffer.ingest(at: seconds(5), systemLoad: 30, groups: [group(app("A"), cpu: 30)]))
        XCTAssertNil(buffer.ingest(at: seconds(55), systemLoad: 20, groups: [group(app("B"), cpu: 5)]))
    }

    /// 跨入新分钟冲刷上一分钟:均值/峰值/进程数峰值逐列对得上。
    func testCrossingMinuteFlushesAggregateWithAveragesAndPeaks() {
        var buffer = MinuteRollupBuffer()
        buffer.ingest(
            at: seconds(0),
            systemLoad: 10,
            groups: [group(app("A"), cpu: 10, mem: 1_000, procs: 2)]
        )
        buffer.ingest(
            at: seconds(20),
            systemLoad: 30,
            groups: [group(app("A"), cpu: 30, mem: 3_000, procs: 4)]
        )

        let aggregate = buffer.ingest(
            at: seconds(60),
            systemLoad: 1,
            groups: []
        )

        let flushed = try? XCTUnwrap(aggregate)
        XCTAssertEqual(flushed?.minuteStart, minute0)
        XCTAssertEqual(flushed?.groups.count, 1)
        XCTAssertEqual(flushed?.groups.first?.identity, app("A"))
        XCTAssertEqual(flushed?.groups.first?.cpuAverage ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(flushed?.groups.first?.cpuPeak ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(flushed?.groups.first?.memoryPeak, 3_000)
        XCTAssertEqual(flushed?.groups.first?.processPeak, 4)
        XCTAssertEqual(flushed?.systemLoadAverage ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(flushed?.systemLoadPeak ?? -1, 30, accuracy: 0.0001)
    }

    /// 所有在场组都被卷积(逐组一行,stableKey 升序);组消失即停记。
    func testEveryPresentGroupIsAggregatedInStableKeyOrder() {
        var buffer = MinuteRollupBuffer()
        buffer.ingest(
            at: seconds(0),
            systemLoad: 5,
            groups: [
                group(.orphan, cpu: 1),
                group(app("Zed"), cpu: 2),
                group(.system, cpu: 3),
                group(.project(root: "/p", worktreeName: nil), cpu: 4),
            ]
        )

        let aggregate = buffer.ingest(at: seconds(60), systemLoad: 5, groups: [])

        let identities = aggregate?.groups.map(\.identity)
        XCTAssertEqual(identities?.count, 4)
        XCTAssertEqual(identities, identities?.sorted()) // stableKey 字典序
    }

    /// 跨过的空分钟不产出任何聚合(不补零);只有采过样的分钟冲刷。
    func testSkippedMinutesProduceNothing() {
        var buffer = MinuteRollupBuffer()
        buffer.ingest(at: seconds(0), systemLoad: 10, groups: [group(app("A"), cpu: 10)])
        let first = buffer.ingest(at: seconds(60), systemLoad: 10, groups: [group(app("A"), cpu: 0)])
        // 分钟 1、2、3 完全无采样;下一个采样直接落在分钟 4。
        let second = buffer.ingest(at: seconds(240), systemLoad: 10, groups: [group(app("A"), cpu: 1)])

        XCTAssertEqual(first?.minuteStart, minute0)
        XCTAssertEqual(second?.minuteStart, seconds(60)) // 只冲刷有样本的 10:01
        XCTAssertEqual(second?.groups.first?.cpuAverage ?? -1, 0, accuracy: 0.0001)
    }

    /// 时钟回拨(乱序迟到样本)被丢弃,不污染已聚合的窗口。
    func testClockRegressionSampleIsDropped() {
        var buffer = MinuteRollupBuffer()
        buffer.ingest(at: seconds(0), systemLoad: 10, groups: [group(app("A"), cpu: 10)])
        _ = buffer.ingest(at: seconds(60), systemLoad: 10, groups: [])
        // 迟到的"上一分钟"样本:当前窗已是 10:01,回拨到 10:00:30 的采样丢弃。
        let late = buffer.ingest(at: seconds(30), systemLoad: 99, groups: [group(app("A"), cpu: 99)])
        let next = buffer.ingest(at: seconds(120), systemLoad: 10, groups: [group(app("A"), cpu: 1)])

        XCTAssertNil(late)
        XCTAssertEqual(next?.minuteStart, seconds(60))
        XCTAssertEqual(next?.systemLoadAverage ?? -1, 10, accuracy: 0.0001) // 99 未混入
    }

    /// 同轮重复的组 id 以最后一条为准(与内存环形缓冲同口径)。
    func testDuplicateGroupSamplesUseTheLastOne() {
        var buffer = MinuteRollupBuffer()
        buffer.ingest(
            at: seconds(0),
            systemLoad: 1,
            groups: [group(app("A"), cpu: 10, procs: 1), group(app("A"), cpu: 50, procs: 7)]
        )

        let aggregate = buffer.ingest(at: seconds(60), systemLoad: 1, groups: [])

        XCTAssertEqual(aggregate?.groups.count, 1)
        XCTAssertEqual(aggregate?.groups.first?.cpuAverage ?? -1, 50, accuracy: 0.0001)
        XCTAssertEqual(aggregate?.groups.first?.processPeak, 7)
    }

    // MARK: 窗口对齐

    /// 分钟/小时起点按整秒 epoch 对齐,写读两端同一份换算。
    func testWindowAlignment() {
        let arbitrary = Date(timeIntervalSince1970: 1_789_001_527) // 非对齐
        XCTAssertEqual(HistoryWindows.epochSeconds(of: arbitrary), 1_789_001_527)
        XCTAssertEqual(
            HistoryWindows.epochSeconds(of: HistoryWindows.minuteStart(of: arbitrary)),
            HistoryWindows.epochSeconds(of: minute0) + 26 * 60 // 落在基准后第 26 分钟
        )
        XCTAssertEqual(
            HistoryWindows.epochSeconds(of: HistoryWindows.hourStart(of: arbitrary)),
            HistoryWindows.epochSeconds(of: HistoryWindows.hourStart(of: minute0))
        )
    }

    // MARK: 留存计划

    /// 留存触发:从未清理或当地日变更才触发;同日不重复触发。
    func testRetentionIsDueOnDayChangeOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day1Noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_789_000_000))!
        let day1Later = calendar.date(byAdding: .hour, value: 3, to: day1Noon)!
        let day2 = calendar.date(byAdding: .day, value: 1, to: day1Later)!
        let day1Start = calendar.startOfDay(for: day1Noon)

        XCTAssertTrue(HistoryRetention.isDue(lastRunDayStart: nil, now: day1Noon, calendar: calendar))
        XCTAssertFalse(HistoryRetention.isDue(lastRunDayStart: day1Start, now: day1Later, calendar: calendar))
        XCTAssertTrue(HistoryRetention.isDue(lastRunDayStart: day1Start, now: day2, calendar: calendar))
    }

    /// 截止口径:分钟 7 天、小时 30 天。
    func testRetentionCutoffs() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertEqual(
            HistoryRetention.minuteCutoff(now: now),
            now.addingTimeInterval(-7 * 24 * 3600)
        )
        XCTAssertEqual(
            HistoryRetention.hourCutoff(now: now),
            now.addingTimeInterval(-30 * 24 * 3600)
        )
    }
}
