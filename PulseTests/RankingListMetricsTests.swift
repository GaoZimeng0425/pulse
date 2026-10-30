import AppKit
@testable import Pulse
@testable import PulseCore
import XCTest

/// 排行列表数值列定宽(2026-10-20 用户反馈:网络排行各行名称区长短不一,CPU 排行却齐)。
/// 数值列曾是最小宽度,速率文案(53–70pt)撑宽了列、把 meter 推得每行不同;改为按最宽
/// 现实读数定宽后,各指标的现实读数都必须装得下,否则又会撑宽 / 截断。
final class RankingListMetricsTests: XCTestCase {
    /// 各排行的现实最宽读数:CPU(组可超 100%)、内存、能耗 CPU 时间、磁盘 / 网络速率。
    private let widestReadings = ["999%", "99.9 GB", "99.9 秒", "999.9 MB/s", "999.9 KB/s"]

    func testEveryRealisticValueFitsTheFixedColumnInBothDensities() {
        for compact in [false, true] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: compact ? 11.5 : 13, weight: .semibold)
            let column = RankingListMetrics.valueWidth(compact: compact)
            for reading in widestReadings {
                let width = (reading as NSString).size(withAttributes: [.font: font]).width
                XCTAssertLessThanOrEqual(width, column, "\(reading) 撑出\(compact ? "紧凑" : "全尺寸")数值列")
            }
        }
    }
}
