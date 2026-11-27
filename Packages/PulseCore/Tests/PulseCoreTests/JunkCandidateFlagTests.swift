@testable import PulseCore
import XCTest

/// 候选的条目标志(p7-cleaner/01;GLOSSARY「条目标志」):清单行、确认清单、清理历史三处
/// 共用同一份标志清单与文案。标志只陈述事实(「需要管理员权限」「未识别」),不是安全档,
/// 也不参与自动勾选判定。候选上标志只有这一份清单(唯一出处):构造时给什么顺序、有没有
/// 重复,存下来都是规范形。
final class JunkCandidateFlagTests: XCTestCase {
    private func candidate(_ flags: [JunkCandidateFlag] = []) -> JunkCandidate {
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
            flags: flags
        )
    }

    /// 默认无标志:不带标志的候选,清单上不多出任何小标。
    func testCandidatesDefaultToNoFlags() {
        XCTAssertTrue(candidate().flags.isEmpty)
    }

    func testRequiresAuthorizationFlag() {
        let flags = candidate([.requiresAuthorization]).flags
        XCTAssertEqual(flags, [.requiresAuthorization])
        XCTAssertEqual(flags.map(\.title), ["需要管理员权限"])
        XCTAssertFalse(JunkCandidateFlag.requiresAuthorization.help.isEmpty, "标志自带悬停说明")
    }

    func testUnidentifiedFlag() {
        let flags = candidate([.unidentified]).flags
        XCTAssertEqual(flags, [.unidentified])
        XCTAssertEqual(flags.map(\.title), ["未识别"])
        XCTAssertFalse(JunkCandidateFlag.unidentified.help.isEmpty, "标志自带悬停说明")
    }

    /// 固定序:需授权在前——它决定「点了会发生什么」,比「认不认识」更要紧。倒着给也一样,
    /// 所以乱序给出来的两个候选相等(注释里的承诺在这里落成断言)。
    func testFlagsStoredInFixedOrder() {
        let forward = candidate([.requiresAuthorization, .unidentified])
        let reversed = candidate([.unidentified, .requiresAuthorization])

        XCTAssertEqual(reversed.flags, [.requiresAuthorization, .unidentified])
        XCTAssertEqual(forward, reversed)
    }

    /// 重复给出同一个标志,存下来只有一份(小标不重复出)。
    func testDuplicateFlagsCollapse() {
        XCTAssertEqual(candidate([.unidentified, .unidentified]).flags, [.unidentified])
    }

    /// 登记面(全 case 遍历):每个标志都有小标文案与悬停说明,文案互不相同——新增标志
    /// 漏写文案在这里兜底。
    func testEveryFlagHasDistinctTitleAndHelp() {
        let all = JunkCandidateFlag.allCases
        XCTAssertEqual(all, [.requiresAuthorization, .unidentified])
        for flag in all {
            XCTAssertFalse(flag.title.isEmpty, "\(flag) 缺小标文案")
            XCTAssertFalse(flag.help.isEmpty, "\(flag) 缺悬停说明")
        }
        XCTAssertEqual(Set(all.map(\.title)).count, all.count, "标志文案互不相同")
    }

    /// 占用重算会逐字段重建候选:标志必须跟着过去,不能静默回落成「无标志」。
    func testAccountingRebuildKeepsFlags() {
        let rebuilt = candidate([.requiresAuthorization, .unidentified])
            .withAccounting(bytes: 9, fileCount: 2, allReclaimable: false, note: "按整目录兜底")

        XCTAssertEqual(rebuilt.flags, [.requiresAuthorization, .unidentified])
        XCTAssertEqual(rebuilt.bytes, 9)
    }
}
