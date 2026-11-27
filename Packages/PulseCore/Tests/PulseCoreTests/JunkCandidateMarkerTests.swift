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

    /// 登记面(全 case 遍历):每个标记都有小标文案与悬停说明,文案互不相同——新增标记
    /// 漏写文案在这里兜底。
    func testEveryMarkerHasDistinctTitleAndHelp() {
        let all = JunkCandidateMarker.allCases
        XCTAssertEqual(all, [.requiresAuthorization, .unidentified])
        for marker in all {
            XCTAssertFalse(marker.title.isEmpty, "\(marker) 缺小标文案")
            XCTAssertFalse(marker.help.isEmpty, "\(marker) 缺悬停说明")
        }
        XCTAssertEqual(Set(all.map(\.title)).count, all.count, "标记文案互不相同")
    }

    /// 占用重算会逐字段重建候选:标记必须跟着过去,不能静默回落成「无标记」。
    func testAccountingRebuildKeepsMarkers() {
        let rebuilt = candidate(requiresAuthorization: true, unidentified: true)
            .withAccounting(bytes: 9, fileCount: 2, allReclaimable: false, note: "按整目录兜底")

        XCTAssertEqual(rebuilt.markers, [.requiresAuthorization, .unidentified])
        XCTAssertEqual(rebuilt.bytes, 9)
    }
}
