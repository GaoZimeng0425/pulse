import AppKit
@testable import Pulse
@testable import PulseCore
import XCTest

/// 排行列表数值列定宽(2026-10-20 用户反馈:网络排行各行名称区长短不一,CPU 排行却齐)。
/// 数值列曾是最小宽度,速率文案(53–70pt)撑宽了列、把 meter 推得每行不同;改为按最宽
/// 现实读数定宽后,各指标的现实读数都必须装得下,否则又会撑宽 / 截断。
final class RankingListMetricsTests: XCTestCase {
    /// 标准列(组排行)现实最宽读数:CPU(组可超 100%,十余核满载 4 位)、内存。
    private let standardReadings = ["9999%", "99.9 GB", "999 MB"]
    /// 速率列(模块排行)现实最宽读数:能耗 CPU 时间、磁盘 / 网络速率。
    private let rateReadings = ["99.9 秒", "999.9 MB/s", "999.9 KB/s"]

    func testEveryRealisticValueFitsItsFixedColumnInBothDensities() {
        for compact in [false, true] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: compact ? 11.5 : 13, weight: .semibold)
            let cases: [(RankingValueColumn, [String])] = [(.standard, standardReadings), (.rate, rateReadings)]
            for (column, readings) in cases {
                let width = RankingListMetrics.valueWidth(compact: compact, column: column)
                for reading in readings {
                    let measured = (reading as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertLessThanOrEqual(measured, width, "\(reading) 撑出\(compact ? "紧凑" : "全尺寸")\(column)数值列")
                }
            }
        }
    }

    /// 2026-10-30 用户反馈:CPU 读数短、按速率量宽的列右对齐后 meter 与数字隔一大截。
    /// 标准列必须明显窄于速率列,省下的宽度让给名称与最忙进程 chip。
    func testStandardColumnIsNarrowerThanRateColumn() {
        for compact in [false, true] {
            XCTAssertLessThan(
                RankingListMetrics.valueWidth(compact: compact, column: .standard),
                RankingListMetrics.valueWidth(compact: compact, column: .rate) - 10
            )
        }
    }
}
