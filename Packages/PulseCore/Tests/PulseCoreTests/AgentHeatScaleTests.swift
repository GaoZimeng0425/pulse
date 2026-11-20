@testable import PulseCore
import XCTest

// MARK: - 热力墙色阶与按周聚合(agent-tab/11)

final class AgentHeatScaleTests: XCTestCase {
    private func days(_ values: [Int]) -> [AgentDayTotal] {
        values.enumerated().map { AgentDayTotal(day: String(format: "2026-01-%02d", $0.offset + 1), total: $0.element) }
    }

    // MARK: 色阶

    func testLevelsQuantizeAgainstPeakWithGrayFloor() {
        // 峰 100:8 ≤ 8% 灰;9 → 1;30 → 2;60 → 3;100 → 4
        XCTAssertEqual(AgentHeatScale.levels([0, 8, 9, 30, 60, 100]), [0, 0, 1, 2, 3, 4])
    }

    func testLevelsAllZeroStayGray() {
        XCTAssertEqual(AgentHeatScale.levels([0, 0, 0]), [0, 0, 0])
    }

    // MARK: 按周聚合

    func testWeeksChunkSevenDaysOldestFirst() {
        let weeks = AgentHeatScale.weeks(days(Array(1 ... 14)))
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0], AgentWeekTotal(firstDay: "2026-01-01", lastDay: "2026-01-07", total: 28))
        XCTAssertEqual(weeks[1], AgentWeekTotal(firstDay: "2026-01-08", lastDay: "2026-01-14", total: 77))
    }

    func testWeeksKeepTrailingPartialWeek() {
        let weeks = AgentHeatScale.weeks(days([1, 1, 1, 1, 1, 1, 1, 5, 5]))
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[1], AgentWeekTotal(firstDay: "2026-01-08", lastDay: "2026-01-09", total: 10))
    }

    func testWeeksSumBucketsAcrossDays() {
        let mixed = [
            AgentDayTotal(
                day: "2026-01-01",
                total: 100,
                inputTokens: 30,
                outputTokens: 10,
                cacheReadTokens: 50,
                cacheWriteTokens: 10
            ),
            AgentDayTotal(day: "2026-01-02", total: 40, inputTokens: 10, outputTokens: 10, cacheReadTokens: 20),
            AgentDayTotal(day: "2026-01-03", total: 500), // 回填天,无分桶
        ]
        let weeks = AgentHeatScale.weeks(mixed)
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].total, 640)
        // 列内四桶累加;回填天只进 total 不进四桶(明细照实,不虚补)。
        XCTAssertEqual(weeks[0].breakdown, AgentTokenBreakdown(input: 40, output: 20, cacheRead: 70, cacheWrite: 10))
    }

    func testWeeksAllBackfillDaysHaveNoBreakdown() {
        let weeks = AgentHeatScale.weeks([
            AgentDayTotal(day: "2026-01-01", total: 100),
            AgentDayTotal(day: "2026-01-02", total: 200),
        ])
        XCTAssertNil(weeks[0].breakdown)
    }

    // MARK: 今天折算

    func testDayLevelsProjectTodayToFullDay() {
        // 今天才过 6h:25 折算全天 100,与昨天的峰 100 同档
        let levels = AgentHeatScale.dayLevels(days([100, 25]), todayElapsed: 6 * 3600)
        XCTAssertEqual(levels, [4, 4])
    }

    func testDayLevelsElapsedFloorIsSixHours() {
        // 凌晨 1h:按 6h 下限折算,25 → 100 而不是 600
        let levels = AgentHeatScale.dayLevels(days([400, 25]), todayElapsed: 3600)
        XCTAssertEqual(levels, [4, 1])
    }

    func testWeekLevelsProjectOnlyTodaysShareOfLastWeek() {
        // 第一周 700;末周前 6 天 60×6 = 360 + 今天 25(6h → 100)= 460 → 460/700 = 66% → 3
        let values = Array(repeating: 100, count: 7) + Array(repeating: 60, count: 6) + [25]
        let levels = AgentHeatScale.weekLevels(days(values), todayElapsed: 6 * 3600)
        XCTAssertEqual(levels, [4, 3])
    }

    func testWeekLevelsWithoutTodayElapsedUseRawTotals() {
        let values = Array(repeating: 100, count: 7) + Array(repeating: 10, count: 7)
        XCTAssertEqual(AgentHeatScale.weekLevels(days(values), todayElapsed: nil), [4, 1])
    }
}
