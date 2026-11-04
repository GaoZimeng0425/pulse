@testable import PulseCore
import XCTest

/// 应用清单域(p4-uninstaller/01):排除口径、灰行态、运行判定边界、徽标、排序。
/// 全部合成夹具,不碰真盘(测试纪律:不起宿主、不占真机负载)。
final class AppCatalogTests: XCTestCase {
    private func candidate(
        _ name: String,
        path: String? = nil,
        bundleID: String? = "com.example.app",
        displayName: String? = nil,
        apple: Bool = false,
        unverifiable: Bool = false,
        deletable: Bool = true
    ) -> AppCatalogCandidate {
        AppCatalogCandidate(
            path: path ?? "/Applications/\(name)",
            directoryName: name,
            bundleID: bundleID,
            displayName: displayName,
            isAppleSigned: apple,
            signatureUnverifiable: unverifiable,
            isDeletable: deletable
        )
    }

    // MARK: 排除口径

    func testAppleSignedAppsNeverAppearAndAreCounted() {
        let output = AppCatalog.build(
            candidates: [
                candidate("Safari.app", apple: true),
                candidate("Bitwarden.app"),
            ]
        )
        XCTAssertEqual(output.entries.map(\.path), ["/Applications/Bitwarden.app"])
        XCTAssertEqual(output.ledger.excludedAppleSigned, 1)
        XCTAssertEqual(output.ledger.excludedUnverifiableSignature, 0)
    }

    func testUnverifiableSignatureAppsExcludedAndCounted() {
        // 「验证了且非 Apple」必须照常列出;只有验证本身失败才排除。
        let output = AppCatalog.build(
            candidates: [
                candidate("Broken.app", unverifiable: true),
                candidate("Unsigned.app", apple: false, unverifiable: false),
            ]
        )
        XCTAssertEqual(output.entries.map(\.name), ["Unsigned"])
        XCTAssertEqual(output.ledger.excludedUnverifiableSignature, 1)
    }

    // MARK: 灰行态

    func testNoPermissionOutranksRunning() {
        // 无权限更根本(退出了也删不了),并存时以 noPermission 示人。
        let output = AppCatalog.build(
            candidates: [candidate("Stuck.app", deletable: false)],
            runningExecutablePaths: ["/Applications/Stuck.app/Contents/MacOS/Stuck"]
        )
        XCTAssertEqual(output.entries.single?.rowState, .noPermission)
    }

    func testRunningAppGetsQuitState() {
        let output = AppCatalog.build(
            candidates: [candidate("Ghostty.app")],
            runningExecutablePaths: ["/Applications/Ghostty.app/Contents/MacOS/ghostty"]
        )
        XCTAssertEqual(output.entries.single?.rowState, .running)
    }

    func testSiblingAppNamePrefixDoesNotFalsePositiveRunning() {
        // 裸字符串 hasPrefix 会把 "Foo.app Helper.app" 误中在 "Foo.app" 上——
        // 必须比到目录分隔符(路径组件前缀)。
        let output = AppCatalog.build(
            candidates: [candidate("Foo.app")],
            runningExecutablePaths: ["/Applications/Foo.app Helper.app/Contents/MacOS/helper"]
        )
        XCTAssertEqual(output.entries.single?.rowState, .normal)
    }

    // MARK: 显示名与排序

    func testDisplayNameFallsBackToDirectoryNameStem() {
        let output = AppCatalog.build(
            candidates: [
                candidate("Named.app", displayName: "好名字"),
                candidate("Plain.app"),
                candidate(".app", path: "/Applications/.app"),
            ]
        )
        // 排序另有专测;这里只看显示名集合(顺序无关)。
        XCTAssertEqual(Set(output.entries.map(\.name)), ["好名字", "Plain", ".app"])
    }

    func testEntriesSortedByNameCaseInsensitively() {
        let output = AppCatalog.build(
            candidates: [candidate("zeta.app"), candidate("Alpha.app"), candidate("beta.app")]
        )
        XCTAssertEqual(output.entries.map(\.name), ["Alpha", "beta", "zeta"])
    }

    // MARK: 徽标与大小

    func testBrewBadgeMatchesDirectoryNameExactly() {
        let output = AppCatalog.build(
            candidates: [candidate("Bitwarden.app", displayName: "Bitwarden")],
            brewAppNames: ["Bitwarden.app": "bitwarden"]
        )
        XCTAssertEqual(output.entries.single?.brewCaskName, "bitwarden")
    }

    func testBrewBadgeAbsentWhenReceiptDoesNotMatch() {
        let output = AppCatalog.build(
            candidates: [candidate("BitWarden.app")], // 大小写不同 ≠ 全等
            brewAppNames: ["Bitwarden.app": "bitwarden"]
        )
        XCTAssertNil(output.entries.single?.brewCaskName)
    }

    func testSizeInjectionAndPartialPropagation() {
        let output = AppCatalog.build(
            candidates: [candidate("A.app"), candidate("B.app")],
            appSizes: [
                "/Applications/A.app": (bytes: 4096, partial: true),
                "/Applications/B.app": (bytes: 8192, partial: false),
            ]
        )
        let a = output.entries.first { $0.name == "A" }
        XCTAssertEqual(a?.sizeBytes, 4096)
        XCTAssertEqual(a?.isPartial, true)
        let b = output.entries.first { $0.name == "B" }
        XCTAssertEqual(b?.sizeBytes, 8192)
        XCTAssertEqual(b?.isPartial, false)
    }

    func testBundleIDCarriesThroughForLeftoverEngine() {
        let output = AppCatalog.build(
            candidates: [candidate("NoPlist.app", bundleID: nil)]
        )
        XCTAssertNil(output.entries.single?.bundleID, "02 票残留引擎按「无 bundle id」处理")
    }

    // MARK: 展示层纯值(2026-11-04 Q5:默认占用降序 + 搜索)

    func testSortSizeDescendingPutsUnknownLast() {
        let entries = [
            UninstallAppEntry(name: "Small", path: "/A", sizeBytes: 100),
            UninstallAppEntry(name: "Unknown", path: "/B"), // 大小未知不伪造 0
            UninstallAppEntry(name: "Big", path: "/C", sizeBytes: 900),
        ]
        XCTAssertEqual(
            AppCatalog.sorted(entries, by: .sizeDescending).map(\.name),
            ["Big", "Small", "Unknown"]
        )
    }

    func testSortByNameCaseInsensitive() {
        let entries = [
            UninstallAppEntry(name: "beta", path: "/1"),
            UninstallAppEntry(name: "Zeta", path: "/2"),
            UninstallAppEntry(name: "alpha", path: "/3"),
        ]
        XCTAssertEqual(
            AppCatalog.sorted(entries, by: .name).map(\.name),
            ["alpha", "beta", "Zeta"]
        )
    }

    func testFilterMatchesNameOrPathCaseInsensitive() {
        let entries = [
            UninstallAppEntry(name: "Bitwarden", path: "/Applications/Bitwarden.app"),
            UninstallAppEntry(name: "Ghostty", path: "/Applications/Ghostty.app"),
        ]
        XCTAssertEqual(AppCatalog.filtered(entries, query: "bitwarden").map(\.name), ["Bitwarden"], "名字命中")
        XCTAssertEqual(AppCatalog.filtered(entries, query: "ghostty.app").map(\.name), ["Ghostty"], "路径命中")
        XCTAssertEqual(AppCatalog.filtered(entries, query: "  ").count, 2, "空白查询原样返回")
        XCTAssertEqual(AppCatalog.filtered(entries, query: "不存在").count, 0)
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
