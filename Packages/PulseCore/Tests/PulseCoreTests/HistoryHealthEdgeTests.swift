import XCTest
@testable import PulseCore

/// 历史库健康状态沿(arch-review-2026-10-18/03 乙6):落库 / 累计 / 历史页查询共用一面旗,
/// 只在翻转时记日志——失败进入记一条、持续失败静默、恢复记一条,平时安静。
final class HistoryHealthEdgeTests: XCTestCase {
    func testOnlyTransitionsAreLogged() {
        var edge = HistoryHealthEdge()

        XCTAssertFalse(edge.recordSuccess(), "健康时成功不记")
        XCTAssertTrue(edge.recordFailure(), "首次失败记进入边")
        XCTAssertFalse(edge.recordFailure(), "持续失败静默")
        XCTAssertFalse(edge.recordFailure())
        XCTAssertTrue(edge.recordSuccess(), "恢复记一条")
        XCTAssertFalse(edge.recordSuccess())
        XCTAssertTrue(edge.recordFailure(), "再坏再记")
    }
}
