import AppKit
@testable import Pulse
@testable import PulseCore
import XCTest

/// agent-usage-redesign/03:项目榜单数值列定宽——各列的现实最宽读数都要装进自己的
/// 定宽列,否则又会撑宽 / 截断(先例 RankingListMetricsTests)。
final class AgentProjectRankingMetricsTests: XCTestCase {
    /// 消耗列现实最宽读数(各单位的最高位形态)。
    private let tokenReadings = ["999.9B", "999.9M", "999k", "999"]
    /// 占比列现实最宽读数(整数百分比)。
    private let shareReadings = ["100%", "99%", "0%"]
    /// 环比列现实最宽读数(三位数涨跌、持平)。
    private let deltaReadings = ["▲ +999%", "▼ -999%", "持平"]

    private func width(_ reading: String, fontSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        return (reading as NSString).size(withAttributes: [.font: font]).width
    }

    func testEveryRealisticReadingFitsItsColumnInBothDensities() {
        for compact in [false, true] {
            let tier = compact ? "紧凑" : "全尺寸"
            let fontSize = RowMetrics.valueFontSize(compact: compact)
            for reading in tokenReadings {
                XCTAssertLessThanOrEqual(
                    width(reading, fontSize: fontSize, weight: .semibold),
                    AgentProjectRankingMetrics.tokensWidth(compact: compact),
                    "\(reading) 撑出\(tier)消耗列"
                )
            }
            for reading in shareReadings {
                XCTAssertLessThanOrEqual(
                    width(reading, fontSize: fontSize, weight: .semibold),
                    AgentProjectRankingMetrics.shareWidth(compact: compact),
                    "\(reading) 撑出\(tier)占比列"
                )
            }
            for reading in deltaReadings {
                XCTAssertLessThanOrEqual(
                    width(reading, fontSize: 10.5, weight: .regular),
                    AgentProjectRankingMetrics.deltaWidth,
                    "\(reading) 撑出\(tier)环比列"
                )
            }
        }
    }
}
