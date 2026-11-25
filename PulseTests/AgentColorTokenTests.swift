@testable import Pulse
import PulseCore
import SwiftUI
import XCTest

// agent-usage-redesign/01:智能体页配色令牌的钉子。期望值是 DESIGN.md 令牌表的原文
// (文档 = 独立事实源):页面强调色、来源色、模型色的浅深数值逐项钉死;页面强调色与
// 全部指标色互异;两个 tab 条的取色口。

@MainActor
final class AgentColorTokenTests: XCTestCase {
    /// 令牌表原文:智能体页强调色。
    func testAgentsAccentMatchesTokenTable() {
        XCTAssertEqual(Surface.agentsAccentToken, MetricAccentToken(light: 0x5A921A, dark: 0xA6D94A))
    }

    /// 令牌表原文:Claude 与 ZCode 的来源色。
    func testSourceTintsMatchTokenTable() {
        XCTAssertEqual(AgentPartitionTint.sourceToken(.claude), MetricAccentToken(light: 0xC9622F, dark: 0xE8946A))
        XCTAssertEqual(AgentPartitionTint.sourceToken(.zcode), MetricAccentToken(light: 0x6A4FE0, dark: 0x8F7CF5))
    }

    /// 令牌表原文:模型三档。
    func testModelTintsMatchTokenTable() {
        XCTAssertEqual(AgentPartitionTint.modelTokens, [
            MetricAccentToken(light: 0x1A78BD, dark: 0x58A8E8),
            MetricAccentToken(light: 0xBD3A7C, dark: 0xE070A8),
            MetricAccentToken(light: 0x93730F, dark: 0xCFAB4A),
        ])
    }

    /// 六个新令牌每个浅深互异(相同即退化为单套)。
    func testLightAndDarkDifferPerToken() {
        for token in Self.newTokens {
            XCTAssertNotEqual(token.light, token.dark, "\(token) 的浅深两套应互异")
        }
    }

    /// 页面强调色(智能体、清理)不与任何指标色相同,两个页面强调色之间也不同:
    /// tab 条上每个 tab 都认得出来。指标色套内互异由 MetricAccentTests 钉,这里不重复。
    func testPageAccentsDistinctFromMetricAccents() {
        let metricLights = Set(Metric.allCases.map(\.accent.light))
        let metricDarks = Set(Metric.allCases.map(\.accent.dark))
        let pageTokens = [Surface.agentsAccentToken, Surface.cleanAccentToken]
        XCTAssertEqual(Set(pageTokens.map(\.light)).count, pageTokens.count, "两个页面强调色的浅色应互异")
        XCTAssertEqual(Set(pageTokens.map(\.dark)).count, pageTokens.count, "两个页面强调色的深色应互异")
        for token in pageTokens {
            XCTAssertFalse(metricLights.contains(token.light), "\(token) 的浅色撞了指标色")
            XCTAssertFalse(metricDarks.contains(token.dark), "\(token) 的深色撞了指标色")
        }
    }

    /// 模型取色越界:往低端收第一档、往高端收第三档——再多模型也只有三档。
    func testModelTintClampsToTiers() {
        XCTAssertEqual(hex(AgentPartitionTint.model(at: -1), .dark), 0x58A8E8)
        XCTAssertEqual(hex(AgentPartitionTint.model(at: 0), .dark), 0x58A8E8)
        XCTAssertEqual(hex(AgentPartitionTint.model(at: 7), .dark), 0xCFAB4A)
    }

    /// 每个 tab 恰好一种色源:页面强调色或指标族归属,不会两个都有、也不会都没有。
    func testEveryTabHasExactlyOneColorSource() {
        for tab in MetricTab.allCases {
            XCTAssertNotEqual(tab.pageAccent == nil, tab.accent == nil, "\(tab) 应恰好一种色源")
        }
    }

    /// 两个 tab 条的取色口:有页面强调色的 tab 取页强调色,其余每个 tab 都取自己的指标色。
    /// 比的是各外观下实际画出来的颜色,不是 Color 实例。
    func testTabTintResolvesToPageAccentOrMetricAccent() {
        XCTAssertEqual(hex(MetricTab.agents.tintColor, .dark), 0xA6D94A)
        XCTAssertEqual(hex(MetricTab.agents.tintColor, .light), 0x5A921A)
        XCTAssertEqual(hex(MetricTab.cleaner.tintColor, .dark), 0x35C4B5)
        XCTAssertEqual(hex(MetricTab.cleaner.tintColor, .light), 0x0D9488)
        for tab in MetricTab.allCases where tab != .agents && tab != .cleaner {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(
                    hex(tab.tintColor, scheme),
                    hex(tab.accent?.accentColor, scheme),
                    "\(tab) 应取自己的指标色(\(scheme))"
                )
            }
        }
    }

    // MARK: 夹具

    /// 本票新增的六个令牌:页面强调色、两个来源色、三档模型色。
    private static var newTokens: [MetricAccentToken] {
        [Surface.agentsAccentToken]
            + [AgentUsageSource.claude, .zcode].map(AgentPartitionTint.sourceToken)
            + AgentPartitionTint.modelTokens
    }

    /// 颜色在指定外观下实际画出的 sRGB hex(解析不出定值 = nil,断言自己会挂)。
    private func hex(_ color: Color?, _ scheme: ColorScheme) -> UInt32? {
        guard let color, let resolved = color.resolved(for: scheme),
              let components = NSColor(resolved).usingColorSpace(.sRGB) else {
            return nil
        }
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((Double(value) * 255).rounded())
        }
        return channel(components.redComponent) << 16 | channel(components.greenComponent) << 8
            | channel(components.blueComponent)
    }
}
