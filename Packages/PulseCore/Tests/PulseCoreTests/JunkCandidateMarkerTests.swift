@testable import PulseCore
import XCTest

/// 候选的客观标记(p7-cleaner/01):清单行、确认清单、清理历史三处共用同一份标记清单与
/// 文案。标记只陈述事实(「需要管理员权限」「未识别」),不是安全档,也不参与自动勾选判定。
final class JunkCandidateMarkerTests: XCTestCase {
    private func candidate(
        requiresAuthorization: Bool = false,
        unidentified: Bool = false
    ) -> JunkCandidate {
        JunkCandidate(
            ruleID: "fixture",
            group: .systemLevel,
            title: "x.ips",
            path: "/Library/Logs/DiagnosticReports/x.ips",
            tier: .checkFirst,
            bytes: 1,
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: true,
            rationale: "夹具",
            symbolName: "folder",
            requiresAuthorization: requiresAuthorization,
            unidentified: unidentified
        )
    }

    /// 默认无标记:不带这两个开关的候选,清单上不多出任何小标。
    func testCandidatesDefaultToNoMarkers() {
        XCTAssertTrue(candidate().markers.isEmpty)
    }

    func testRequiresAuthorizationMarker() {
        let markers = candidate(requiresAuthorization: true).markers
        XCTAssertEqual(markers, [.requiresAuthorization])
        XCTAssertEqual(markers.map(\.title), ["需要管理员权限"])
        XCTAssertFalse(JunkCandidateMarker.requiresAuthorization.help.isEmpty, "标记自带悬停说明")
    }

    func testUnidentifiedMarker() {
        let markers = candidate(unidentified: true).markers
        XCTAssertEqual(markers, [.unidentified])
        XCTAssertEqual(markers.map(\.title), ["未识别"])
        XCTAssertFalse(JunkCandidateMarker.unidentified.help.isEmpty, "标记自带悬停说明")
    }

    /// 两个标记同时带:需授权在前——它决定「点了会发生什么」,比「认不认识」更要紧。
    func testBothMarkersInFixedOrder() {
        XCTAssertEqual(
            candidate(requiresAuthorization: true, unidentified: true).markers,
            [.requiresAuthorization, .unidentified]
        )
    }

    /// 标记不改变档位:带标记的候选仍按自己的档位走,自动勾选资格不被标记单独否决。
    func testMarkersDoNotChangeTier() {
        let marked = candidate(requiresAuthorization: true)
        XCTAssertEqual(marked.tier, .checkFirst)
    }
}
