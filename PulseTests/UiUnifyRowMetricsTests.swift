@testable import Pulse
import XCTest

/// ui-unify/01 防漂移:行两档制(RowMetrics)是全 app 列表行共享值的单一出处,
/// 排行 / 清理两套 metrics 只许委托、不许再私定数值——谁拆台当场红。
/// 2026-11-08 的前一世界:排行 13 / 清理 14.5 / sheet 13.5 / 弹窗 11.5 四套并存。
final class UiUnifyRowMetricsTests: XCTestCase {
    func testRankingMetricsDelegatesToRowMetrics() {
        for compact in [false, true] {
            XCTAssertEqual(RankingListMetrics.nameFontSize(compact: compact), RowMetrics.nameFontSize(compact: compact))
            XCTAssertEqual(
                RankingListMetrics.valueFontSize(compact: compact),
                RowMetrics.valueFontSize(compact: compact)
            )
            XCTAssertEqual(RankingListMetrics.iconSize(compact: compact), RowMetrics.iconSize(compact: compact))
            XCTAssertEqual(RankingListMetrics.meterWidth(compact: compact), RowMetrics.meterWidth(compact: compact))
            XCTAssertEqual(RankingListMetrics.rowInset(compact: compact), RowMetrics.rowInset(compact: compact))
            XCTAssertEqual(RankingListMetrics.spacing(compact: compact), RowMetrics.spacing(compact: compact))
        }
    }

    func testCleanerMetricsSharesComfortableTier() {
        XCTAssertEqual(CleanerListMetrics.titleFontSize, RowMetrics.nameFontSize(compact: false))
        XCTAssertEqual(CleanerListMetrics.valueFontSize, RowMetrics.valueFontSize(compact: false))
        XCTAssertEqual(CleanerListMetrics.subFontSize, RowMetrics.subFontSize(compact: false))
        XCTAssertEqual(CleanerListMetrics.iconSize, RowMetrics.iconSize(compact: false))
        XCTAssertEqual(CleanerListMetrics.meterWidth, RowMetrics.meterWidth(compact: false))
        XCTAssertEqual(CleanerListMetrics.rowInset, RowMetrics.rowInset(compact: false))
        XCTAssertEqual(CleanerListMetrics.rowVerticalPadding, RowMetrics.rowVerticalPadding(compact: false))
    }

    /// 两档语义本身:舒适档行文字大于紧凑档,层级靠字重不靠半号字——
    /// 同档内名称与数值同号(名称 medium / 数值 semibold 由调用方给)。
    func testComfortableTierIsLargerThanCompact() {
        XCTAssertGreaterThan(RowMetrics.nameFontSize(compact: false), RowMetrics.nameFontSize(compact: true))
        XCTAssertGreaterThan(RowMetrics.valueFontSize(compact: false), RowMetrics.valueFontSize(compact: true))
        XCTAssertGreaterThan(RowMetrics.subFontSize(compact: false), RowMetrics.subFontSize(compact: true))
        XCTAssertGreaterThan(RowMetrics.iconSize(compact: false), RowMetrics.iconSize(compact: true))
    }

    /// DESIGN.md v1.1 字号五档(窗口 UI):10.5 / 11 / 12 / 14.5 / 17。
    /// 行两档字必须落在档内。
    func testRowFontSizesAreOnTheFiveStepScale() {
        let allowed: Set<CGFloat> = [10.5, 11, 12, 14.5]
        for compact in [false, true] {
            XCTAssertTrue(allowed.contains(RowMetrics.nameFontSize(compact: compact)))
            XCTAssertTrue(allowed.contains(RowMetrics.valueFontSize(compact: compact)))
            XCTAssertTrue(allowed.contains(RowMetrics.subFontSize(compact: compact)))
        }
    }
}
