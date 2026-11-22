@testable import Pulse
import PulseCore
import XCTest

/// 能耗指数 → 排行行折算(battery-energy/01):占比主值 + 指数副文,两卡同源。
/// 口径拍板:用户要「耗了多少电、占多少百分比」——主值 = 占全机合计百分比。
final class EnergyImpactTableTests: XCTestCase {
    // MARK: 占比文案

    func testPercentTextOneDecimal() {
        XCTAssertEqual(EnergyImpactTable.percentText(250, total: 1000), "25.0%")
        XCTAssertEqual(EnergyImpactTable.percentText(1, total: 1000), "0.1%")
    }

    func testPercentTextHonestLowerBound() {
        // 有消耗但不足 0.05%:如实标下限,不出 0.0% 假精度。
        XCTAssertEqual(EnergyImpactTable.percentText(0.4, total: 1000), "<0.1%")
    }

    func testPercentTextZeroTotalIsHonestDash() {
        XCTAssertEqual(EnergyImpactTable.percentText(10, total: 0), "—")
    }

    // MARK: 指数副文(沿用 AgentEnergyTable 同口径)

    func testIndexTextBoundaryAt100() {
        XCTAssertEqual(EnergyImpactTable.indexText(99.96), "100.0")
        XCTAssertEqual(EnergyImpactTable.indexText(100), "100")
        XCTAssertEqual(EnergyImpactTable.indexText(0.34), "0.3")
    }

    // MARK: 全部应用行

    func testAllAppsRowsPercentPrimaryAndLeaderMeter() {
        let rows = EnergyImpactTable.allAppsRows(
            [
                EnergyImpactReading.Row(name: "ZCode", impact: 2409.65),
                EnergyImpactReading.Row(name: "Music", impact: 33.67),
            ],
            totalImpact: 2443.32 + 0.03 // 让两行合计约 100%,手算口径清楚
        )
        XCTAssertEqual(rows.map(\.id), ["ei:ZCode", "ei:Music"]) // top 已降序,原序保留
        XCTAssertEqual(rows[0].primaryText, EnergyImpactTable.percentText(2409.65, total: 2443.35))
        XCTAssertEqual(rows[0].subtitle, "指数 \(EnergyImpactTable.indexText(2409.65))")
        XCTAssertEqual(rows[0].meterFraction, 1, accuracy: 0.0001) // 榜首满条
        XCTAssertEqual(rows[1].meterFraction, 33.67 / 2409.65, accuracy: 0.0001)
    }

    func testAllAppsRowsZeroTotalYieldsEmpty() {
        // 合计 ≤ 0 交空:调用方走「等待读数」空态,不出全零假行。
        XCTAssertTrue(EnergyImpactTable.allAppsRows(
            [EnergyImpactReading.Row(name: "X", impact: 0)], totalImpact: 0
        ).isEmpty)
    }

    // MARK: AI 助手行

    func testAgentRowsPercentWithProcessCountSubtitle() {
        let rows = EnergyImpactTable.agentRows(
            [
                AgentEnergyEntry(agent: "ZCode", impact: 2409.65, processCount: 3),
                AgentEnergyEntry(agent: "zap", impact: 33.67, processCount: 1),
            ],
            totalImpact: 3000
        )
        XCTAssertEqual(rows[0].id, "agent:ZCode")
        XCTAssertEqual(rows[0].primaryText, EnergyImpactTable.percentText(2409.65, total: 3000))
        XCTAssertEqual(rows[0].subtitle, "3 个进程 · 指数 \(EnergyImpactTable.indexText(2409.65))")
        XCTAssertEqual(rows[1].subtitle, "1 个进程 · 指数 33.7")
        XCTAssertEqual(rows[0].meterFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(rows[1].meterFraction, 33.67 / 2409.65, accuracy: 0.0001)
    }
}

// MARK: - 门槛四态融合(energy-gate-fix)

final class EnergyHelperGateTests: XCTestCase {
    func testResolveFourStates() {
        XCTAssertEqual(EnergyHelperGate.resolve(status: .notRegistered, fetchFailing: false), .notInstalled)
        XCTAssertEqual(EnergyHelperGate.resolve(status: .notRegistered, fetchFailing: true), .notInstalled)
        XCTAssertEqual(
            EnergyHelperGate.resolve(status: .requiresApproval, fetchFailing: false),
            .awaitingSystemApproval
        )
        // status 说谎实案:系统报 enabled,但拉取持续失败 → 如实判「没在运行」。
        XCTAssertEqual(EnergyHelperGate.resolve(status: .enabled, fetchFailing: true), .approvedButNotRunning)
        XCTAssertEqual(EnergyHelperGate.resolve(status: .enabled, fetchFailing: false), .approvedAwaitingReading)
    }
}
