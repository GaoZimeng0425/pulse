@testable import Pulse
@testable import PulseCore
import XCTest

/// 指标强调色令牌表(工单 P0.6-02):色值唯一出处是
/// docs/ui/vitals-style-reference.md §1.1(Vitals 官网 CSS :root)。
/// 这里把文档逐项抄成字面量钉死(文档 = 独立事实源,非同义反复),
/// 并保障"每指标浅深双套、浅深互异、指标间互异"三条令牌前提。
final class MetricAccentTests: XCTestCase {
    /// 令牌表逐项对文档:浅/深双套 hex 一字不差。
    func testAccentHexValuesMatchReferenceDoc() {
        XCTAssertEqual(Metric.cpu.accent, MetricAccentToken(light: 0x2A78D6, dark: 0x3987E5))
        XCTAssertEqual(Metric.memory.accent, MetricAccentToken(light: 0x4A3AA7, dark: 0x9085E9))
        XCTAssertEqual(Metric.disk.accent, MetricAccentToken(light: 0xEDA100, dark: 0xC98500))
        XCTAssertEqual(Metric.network.accent, MetricAccentToken(light: 0x1BAF7A, dark: 0x199E70))
        // 电池(工单 02):§1.1 Battery 行 = Surface.positive 同源的"正常态绿"。
        XCTAssertEqual(Metric.battery.accent, MetricAccentToken(light: 0x008300, dark: 0x2FA83A))
        // 声音/蓝牙(p2-sensors/05):§1.1 Sound/Bluetooth 现成行,外设页取 Bluetooth 青。
        XCTAssertEqual(Metric.sound.accent, MetricAccentToken(light: 0xC2379B, dark: 0xD955B3))
        XCTAssertEqual(Metric.bluetooth.accent, MetricAccentToken(light: 0x0891B2, dark: 0x22A8CC))
        // 容器(p2-sensors/07):§1.1 Projects 行(服务负载语义相邻)。
        XCTAssertEqual(Metric.containers.accent, MetricAccentToken(light: 0xEB6834, dark: 0xD95926))
    }

    /// "双套"的前提:同一指标的浅色与深色必须互异(相同即退化为单套)。
    func testLightAndDarkDifferPerMetric() {
        for metric in Metric.allCases {
            XCTAssertNotEqual(
                metric.accent.light, metric.accent.dark,
                "\(metric) 的浅深两套应互异"
            )
        }
    }

    /// 指标间互异:浅色一套内互不相同、深色一套内互不相同——
    /// 每指标一色可辨识的最低保障(Neural 与 Memory 同色故不入表,表内全互异)。
    func testVariantsPairwiseDistinctWithinEachAppearance() {
        let lights = Metric.allCases.map(\.accent.light)
        let darks = Metric.allCases.map(\.accent.dark)
        XCTAssertEqual(Set(lights).count, lights.count, "浅色套内应互异")
        XCTAssertEqual(Set(darks).count, darks.count, "深色套内应互异")
    }
}
