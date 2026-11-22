@testable import Pulse
import XCTest

// battery-energy/02:电池页耗电排行「紧凑引导行 vs 两张完整卡」判定——
// View 形态不进测试,这里钉判定语义:数据说了算,rows 非空即完整卡。
final class BatteryRankingsLayoutTests: XCTestCase {
    func testAnyRowsShowsCards() {
        XCTAssertEqual(
            BatteryRankingsLayout.resolve(gate: .approvedAwaitingReading, allAppsRowCount: 3, agentRowCount: 0),
            .cards
        )
        XCTAssertEqual(
            BatteryRankingsLayout.resolve(gate: .notInstalled, allAppsRowCount: 0, agentRowCount: 1),
            .cards
        )
    }

    func testNoRowsCollapsesToHintCarryingGate() {
        XCTAssertEqual(
            BatteryRankingsLayout.resolve(gate: .awaitingSystemApproval, allAppsRowCount: 0, agentRowCount: 0),
            .hint(.awaitingSystemApproval)
        )
        XCTAssertEqual(
            BatteryRankingsLayout.resolve(gate: .approvedButNotRunning, allAppsRowCount: 0, agentRowCount: 0),
            .hint(.approvedButNotRunning)
        )
    }

    /// gate 态不改变「有数据就出卡」——四态与 rows 正交,展开只认 rows。
    func testGateNeverOverridesRows() {
        XCTAssertEqual(
            BatteryRankingsLayout.resolve(gate: .notInstalled, allAppsRowCount: 2, agentRowCount: 2),
            .cards
        )
    }
}
