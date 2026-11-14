@testable import PulseCore
import XCTest

// MARK: - token 短型(agent-tab/08:≥1000M 进 B)

final class AgentTokenFormatTests: XCTestCase {
    func testSmallCountsStayRaw() {
        XCTAssertEqual(AgentTokenFormat.short(0), "0")
        XCTAssertEqual(AgentTokenFormat.short(999), "999")
    }

    func testThousandsUseLowercaseK() {
        XCTAssertEqual(AgentTokenFormat.short(1000), "1k")
        XCTAssertEqual(AgentTokenFormat.short(556_400), "556k")
    }

    func testMillionsKeepOneDecimal() {
        XCTAssertEqual(AgentTokenFormat.short(1_000_000), "1.0M")
        XCTAssertEqual(AgentTokenFormat.short(6_940_000), "6.9M")
        XCTAssertEqual(AgentTokenFormat.short(999_940_000), "999.9M")
    }

    func testBillionsSwitchToB() {
        XCTAssertEqual(AgentTokenFormat.short(1_000_000_000), "1.0B")
        XCTAssertEqual(AgentTokenFormat.short(1_940_000_000), "1.9B")
        XCTAssertEqual(AgentTokenFormat.short(3_950_200_000), "4.0B")
    }

    func testRoundingUpToThousandMillionPromotesToB() {
        // 999.96M 四舍五入成 "1000.0M" 不可读——进位后直接换 B。
        XCTAssertEqual(AgentTokenFormat.short(999_960_000), "1.0B")
    }

    func testFigureSplitsValueAndUnit() {
        XCTAssertEqual(AgentTokenFormat.figure(2_400_000_000).value, "2.4")
        XCTAssertEqual(AgentTokenFormat.figure(2_400_000_000).unit, "B")
        XCTAssertEqual(AgentTokenFormat.figure(320_000_000).unit, "M")
        XCTAssertEqual(AgentTokenFormat.figure(12).unit, "")
    }
}
