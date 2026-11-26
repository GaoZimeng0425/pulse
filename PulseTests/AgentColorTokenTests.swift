@testable import Pulse
import PulseCore
import SwiftUI
import XCTest

// 智能体页配色令牌的钉子。期望值是 DESIGN.md 令牌表的原文(文档 = 独立事实源):
// 页面强调色、来源色、模型色的浅深数值逐项钉死,且都是借来的指标色(与总览同一套
// 颜色);清理页强调色与指标色互异;两个 tab 条的取色口。

@MainActor
final class AgentColorTokenTests: XCTestCase {
    /// 令牌表原文:智能体页强调色 = 内存靛紫。
    func testAgentsAccentMatchesTokenTable() {
        XCTAssertEqual(Surface.agentsAccentToken, MetricAccentToken(light: 0x4A3AA7, dark: 0x9085E9))
        XCTAssertEqual(Surface.agentsAccentToken, Metric.memory.accent, "强调色是内存色的别名,不另抄一份")
    }

    /// 令牌表原文:Claude = 传感器赤陶,ZCode = CPU 蓝。
    func testSourceTintsMatchTokenTable() {
        XCTAssertEqual(AgentPartitionTint.sourceToken(.claude), MetricAccentToken(light: 0xD96A4E, dark: 0xE07B5F))
        XCTAssertEqual(AgentPartitionTint.sourceToken(.zcode), MetricAccentToken(light: 0x2A78D6, dark: 0x3987E5))
    }

    /// 令牌表原文:模型三档 = 网络绿 / GPU 粉 / 磁盘琥珀。
    func testModelTintsMatchTokenTable() {
        XCTAssertEqual(AgentPartitionTint.modelTokens, [
            MetricAccentToken(light: 0x1BAF7A, dark: 0x199E70),
            MetricAccentToken(light: 0xE87BA4, dark: 0xD55181),
            MetricAccentToken(light: 0xEDA100, dark: 0xC98500),
        ])
    }

    /// 同屏的分区色(两家来源 + 模型三档)互不相同,也都不撞页面强调色。
    func testPartitionTintsDistinctFromEachOtherAndAccent() {
        let tokens = [AgentUsageSource.claude, .zcode].map(AgentPartitionTint.sourceToken)
            + AgentPartitionTint.modelTokens + [Surface.agentsAccentToken]
        XCTAssertEqual(Set(tokens.map(\.light)).count, tokens.count)
        XCTAssertEqual(Set(tokens.map(\.dark)).count, tokens.count)
    }

    /// 六个新令牌每个浅深互异(相同即退化为单套)。
    func testLightAndDarkDifferPerToken() {
        for token in Self.newTokens {
            XCTAssertNotEqual(token.light, token.dark, "\(token) 的浅深两套应互异")
        }
    }

    /// 清理页强调色不与任何指标色相同;智能体页强调色是借来的内存色(用户拍板的例外,
    /// 见上),两个页面强调色之间仍不同。指标色套内互异由 MetricAccentTests 钉。
    func testCleanAccentDistinctFromMetricAccents() {
        let clean = Surface.cleanAccentToken
        XCTAssertFalse(Metric.allCases.map(\.accent.light).contains(clean.light), "清理页强调色的浅色撞了指标色")
        XCTAssertFalse(Metric.allCases.map(\.accent.dark).contains(clean.dark), "清理页强调色的深色撞了指标色")
        XCTAssertNotEqual(Surface.agentsAccentToken, clean)
    }

    /// 模型取色越界:往低端收第一档、往高端收第三档——再多模型也只有三档。
    func testModelTintClampsToTiers() {
        XCTAssertEqual(hex(AgentPartitionTint.model(at: -1), .dark), 0x199E70)
        XCTAssertEqual(hex(AgentPartitionTint.model(at: 0), .dark), 0x199E70)
        XCTAssertEqual(hex(AgentPartitionTint.model(at: 7), .dark), 0xC98500)
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
        XCTAssertEqual(hex(MetricTab.agents.tintColor, .dark), 0x9085E9)
        XCTAssertEqual(hex(MetricTab.agents.tintColor, .light), 0x4A3AA7)
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

    /// 智能体页的六个令牌:页面强调色、两个来源色、三档模型色。
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
