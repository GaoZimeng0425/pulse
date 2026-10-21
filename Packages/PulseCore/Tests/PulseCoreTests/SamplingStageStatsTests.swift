@testable import PulseCore
import XCTest

/// SamplingStats 分阶段账本(resident-cost/01):单阶段累计、跨账本合并
/// (采样侧 + 主线程侧)、以及空账本语义。管线埋点本身见 SamplerTests
/// "分阶段耗时"用例;报告展示见 DiagnosticReportTests。
final class SamplingStageStatsTests: XCTestCase {
    func testRecordAccumulatesTotalAndCount() {
        var stats = SamplingStats()

        stats.record(stage: .processSnapshot, duration: 0.004)
        stats.record(stage: .processSnapshot, duration: 0.006)

        let timing = stats.stageTimings[.processSnapshot]
        XCTAssertEqual(timing?.sampleCount, 2)
        XCTAssertEqual(timing?.totalDuration ?? 0, 0.010, accuracy: 1e-12)
        XCTAssertEqual(timing?.averageDuration ?? 0, 0.005, accuracy: 1e-12)
    }

    /// 负值时长按 0 计(异常时钟不该把账记负)。
    func testNegativeDurationClampsToZero() {
        var stats = SamplingStats()
        stats.record(stage: .diff, duration: -1)
        XCTAssertEqual(stats.stageTimings[.diff]?.totalDuration, 0)
        XCTAssertEqual(stats.stageTimings[.diff]?.sampleCount, 1)
    }

    /// 合并:采样侧为准的轮数 / 起点 / 轮耗时不动,阶段表按阶段相加、互不覆盖。
    func testMergingUnionsStagesAndKeepsSamplerSideScalars() {
        var samplerSide = SamplingStats()
        samplerSide.record(startedAt: Date(timeIntervalSinceReferenceDate: 0), roundDuration: 0.02, processCount: 10)
        samplerSide.record(stage: .processSnapshot, duration: 0.009)

        var landingSide = SamplingStats()
        landingSide.record(stage: .spineAdvance, duration: 0.004)
        landingSide.record(stage: .spineAdvance, duration: 0.006)
        // 主线程侧即便误记了轮数 / 起点,合并时也不采用(以采样侧为准)。
        landingSide.record(startedAt: Date(timeIntervalSinceReferenceDate: 999), roundDuration: 5, processCount: 1)

        let merged = samplerSide.merging(landingSide)

        XCTAssertEqual(merged.sampleCount, 1)
        XCTAssertEqual(merged.startedAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(merged.totalRoundDuration, 0.02, accuracy: 1e-12)
        XCTAssertEqual(merged.peakProcessCount, 10)
        XCTAssertEqual(merged.stageTimings[.processSnapshot]?.totalDuration ?? 0, 0.009, accuracy: 1e-12)
        XCTAssertEqual(merged.stageTimings[.spineAdvance]?.sampleCount, 2)
        XCTAssertEqual(merged.stageTimings[.spineAdvance]?.averageDuration ?? 0, 0.005, accuracy: 1e-12)
    }

    /// 同一阶段两侧都记(理论不发生,合并语义仍须确定):次数与总时长相加。
    func testMergingSameStageAddsUp() {
        var lhs = SamplingStats()
        lhs.record(stage: .diff, duration: 0.001)
        var rhs = SamplingStats()
        rhs.record(stage: .diff, duration: 0.002)

        let merged = lhs.merging(rhs)
        XCTAssertEqual(merged.stageTimings[.diff]?.totalDuration ?? 0, 0.003, accuracy: 1e-12)
        XCTAssertEqual(merged.stageTimings[.diff]?.sampleCount, 2)
    }

    func testEmptyStageTableStaysEmpty() {
        var stats = SamplingStats()
        stats.record(startedAt: Date(), roundDuration: 1, processCount: 1)
        XCTAssertTrue(stats.stageTimings.isEmpty)
        // 既有账本语义零变化:轮数字段照常。
        XCTAssertEqual(stats.sampleCount, 1)
    }
}
