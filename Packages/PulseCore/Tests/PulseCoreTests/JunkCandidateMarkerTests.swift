@testable import PulseCore
import XCTest

/// 候选的客观标记(p7-cleaner/01):清单行、确认清单、清理历史三处共用同一份标记清单与
/// 文案。标记只陈述事实(「需要管理员权限」「未识别」),不是安全档,也不参与自动勾选判定。
/// 候选上标记只有这一份清单(唯一出处):构造时给什么顺序、有没有重复,存下来都是规范形。
final class JunkCandidateMarkerTests: XCTestCase {
    private func candidate(_ markers: [JunkCandidateMarker] = []) -> JunkCandidate {
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
            markers: markers
        )
    }

    /// 默认无标记:不带标记的候选,清单上不多出任何小标。
    func testCandidatesDefaultToNoMarkers() {
        XCTAssertTrue(candidate().markers.isEmpty)
    }

    func testRequiresAuthorizationMarker() {
        let markers = candidate([.requiresAuthorization]).markers
        XCTAssertEqual(markers, [.requiresAuthorization])
        XCTAssertEqual(markers.map(\.title), ["需要管理员权限"])
        XCTAssertFalse(JunkCandidateMarker.requiresAuthorization.help.isEmpty, "标记自带悬停说明")
    }

    func testUnidentifiedMarker() {
        let markers = candidate([.unidentified]).markers
        XCTAssertEqual(markers, [.unidentified])
        XCTAssertEqual(markers.map(\.title), ["未识别"])
        XCTAssertFalse(JunkCandidateMarker.unidentified.help.isEmpty, "标记自带悬停说明")
    }

    /// 固定序:需授权在前——它决定「点了会发生什么」,比「认不认识」更要紧。倒着给也一样。
    func testMarkersStoredInFixedOrder() {
        XCTAssertEqual(
            candidate([.unidentified, .requiresAuthorization]).markers,
            [.requiresAuthorization, .unidentified]
        )
    }

    /// 重复给出同一个标记,存下来只有一份(小标不重复出)。
    func testDuplicateMarkersCollapse() {
        XCTAssertEqual(candidate([.unidentified, .unidentified]).markers, [.unidentified])
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
        let rebuilt = candidate([.requiresAuthorization, .unidentified])
            .withAccounting(bytes: 9, fileCount: 2, allReclaimable: false, note: "按整目录兜底")

        XCTAssertEqual(rebuilt.markers, [.requiresAuthorization, .unidentified])
        XCTAssertEqual(rebuilt.bytes, 9)
    }
}
