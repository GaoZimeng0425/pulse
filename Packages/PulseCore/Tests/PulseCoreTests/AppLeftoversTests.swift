@testable import PulseCore
import XCTest

/// 残留候选引擎(p4-uninstaller/02):两把键展开、平台域形状、GC 后缀谓词、
/// zap 并集去重与家域过滤、无 bundle id 空清单。全合成,不查盘。
final class AppLeftoversTests: XCTestCase {
    private let home = NSHomeDirectory()

    private func fixedPaths(_ probes: [LeftoverProbe]) -> [String] {
        probes.compactMap(\.fixedPath)
    }

    // MARK: 两把键

    func testPlainNameSitesUseBothKeys() {
        let probes = AppLeftovers.probes(bundleID: "com.bitwarden.desktop", appName: "Bitwarden")
        let paths = fixedPaths(probes)
        for site in ["Application Support", "Caches", "WebKit", "Logs"] {
            XCTAssertTrue(paths.contains("\(home)/Library/\(site)/com.bitwarden.desktop"), site)
            XCTAssertTrue(paths.contains("\(home)/Library/\(site)/Bitwarden"), site)
        }
    }

    func testPlatformDomainSitesUseBundleIDOnly() {
        let probes = AppLeftovers.probes(bundleID: "com.bitwarden.desktop", appName: "Bitwarden")
        let paths = fixedPaths(probes)
        XCTAssertEqual(
            paths.filter { $0.contains("/Preferences/") },
            ["\(home)/Library/Preferences/com.bitwarden.desktop.plist"]
        )
        XCTAssertEqual(
            paths.filter { $0.contains("/Containers/") },
            ["\(home)/Library/Containers/com.bitwarden.desktop"]
        )
        XCTAssertEqual(
            paths.filter { $0.contains("/Saved Application State/") },
            ["\(home)/Library/Saved Application State/com.bitwarden.desktop.savedState"]
        )
        XCTAssertEqual(
            paths.filter { $0.contains("/HTTPStorages/") },
            [
                "\(home)/Library/HTTPStorages/com.bitwarden.desktop",
                "\(home)/Library/HTTPStorages/com.bitwarden.desktop.binarycookies",
            ]
        )
        XCTAssertEqual(
            paths.filter { $0.contains("/Application Scripts/") },
            ["\(home)/Library/Application Scripts/com.bitwarden.desktop"]
        )
    }

    func testLaunchAgentsAlwaysCheckFirstAndBothKeys() {
        let probes = AppLeftovers.probes(bundleID: "com.bitwarden.desktop", appName: "Bitwarden")
        let launchAgents = probes.filter {
            if case let .path(_, site, _, _, _, _) = $0 {
                return site == .launchAgents
            }
            return false
        }
        XCTAssertEqual(launchAgents.count, 2)
        for probe in launchAgents {
            guard case let .path(path, _, _, isFile, checkFirst, _) = probe else {
                return XCTFail("非固定路径")
            }
            XCTAssertTrue(path.hasSuffix(".plist"))
            XCTAssertTrue(isFile)
            XCTAssertTrue(checkFirst, "LaunchAgents 恒「先检查」(spec)")
        }
    }

    func testNoBundleIDYieldsEmptyProbes() {
        // 02 票拍板:只剩应用名一把键时误中风险高于收益,不硬猜。
        XCTAssertTrue(AppLeftovers.probes(bundleID: nil, appName: "Something").isEmpty)
        XCTAssertTrue(AppLeftovers.probes(bundleID: "", appName: "Something").isEmpty)
    }

    func testDuplicateKeyNameCollapsesToSingleKey() {
        // 显示名与 bundle id 相同(罕见但合法):键集合去重,不重复探测。
        let probes = AppLeftovers.probes(bundleID: "com.x", appName: "com.x")
        XCTAssertEqual(fixedPaths(probes).filter { $0.contains("/Caches/") }.count, 1)
    }

    // MARK: Group Containers 谓词

    func testGroupContainerSuffixMatchesWithTeamIDPrefix() {
        XCTAssertTrue(
            AppLeftovers.matchesGroupContainer(
                directoryName: "LTZ2PFU5D6.com.bitwarden.desktop",
                bundleID: "com.bitwarden.desktop"
            )
        )
    }

    func testGroupContainerRejectsBadShapes() {
        let bid = "com.bitwarden.desktop"
        // 无团队 id 前缀
        XCTAssertFalse(AppLeftovers.matchesGroupContainer(directoryName: bid, bundleID: bid))
        // 前缀不是团队 id 形状(小写 / 长度不对)
        XCTAssertFalse(AppLeftovers.matchesGroupContainer(directoryName: "teamid1234.\(bid)", bundleID: bid))
        XCTAssertFalse(AppLeftovers.matchesGroupContainer(directoryName: "ABC12.\(bid)", bundleID: bid))
        // 尾巴不精确 = 姐妹 bid,不算命中
        XCTAssertFalse(AppLeftovers.matchesGroupContainer(directoryName: "LTZ2PFU5D6.\(bid).helper", bundleID: bid))
        XCTAssertFalse(AppLeftovers.matchesGroupContainer(
            directoryName: "LTZ2PFU5D6.com.bitwarden.desktop.helper",
            bundleID: bid
        ))
        // 带数字的团队 id 必须过(数字无大小写,isUppercase 谓词坑)
        XCTAssertTrue(AppLeftovers.matchesGroupContainer(directoryName: "5D6LTZ2PFU.\(bid)", bundleID: bid))
    }

    // MARK: PrivilegedHelperTools 永不出现

    // MARK: 路径越界(cleaner-hardening/01):键来自第三方 Info.plist,不可信

    func testAppNameWithTraversalIsDropped() {
        let probes = AppLeftovers.probes(bundleID: "com.evil.app", appName: "../../Documents")
        let paths = fixedPaths(probes)
        XCTAssertFalse(paths.contains { $0.contains("..") }, "\(paths)")
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("\(home)/Library/") }, "\(paths)")
        XCTAssertTrue(paths.contains("\(home)/Library/Caches/com.evil.app"), "bundle id 键照常")
    }

    func testAppNameWithSlashIsDropped() {
        let paths = fixedPaths(AppLeftovers.probes(bundleID: "com.evil.app", appName: "a/b"))
        XCTAssertFalse(paths.contains { $0.hasSuffix("/a/b") }, "\(paths)")
    }

    func testUnsafeBundleIDYieldsEmptyProbes() {
        XCTAssertTrue(AppLeftovers.probes(bundleID: "../..", appName: "X").isEmpty)
        XCTAssertTrue(AppLeftovers.probes(bundleID: "com/evil", appName: "X").isEmpty)
        XCTAssertTrue(AppLeftovers.probes(bundleID: "..", appName: "X").isEmpty)
    }

    func testZapPathEscapingHomeViaDotDotFiltered() {
        let probes = AppLeftovers.probes(
            bundleID: "com.x.app",
            appName: "X",
            brewZapPaths: ["~/Library/../../../etc/hosts", "~/Library/Caches/../Application Support/X-zap"]
        )
        let paths = fixedPaths(probes)
        XCTAssertFalse(paths.contains { $0.contains("..") }, "\(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/etc/hosts") }, "\(paths)")
        XCTAssertTrue(paths.contains("\(home)/Library/Application Support/X-zap"), "规范化后仍在家域的照收")
    }

    func testPrivilegedHelperToolsNeverProbed() {
        let probes = AppLeftovers.probes(bundleID: "com.any.thing", appName: "Any", brewZapPaths: [
            "\(home)/Library/PrivilegedHelperTools/com.any.thing",
        ])
        let paths = fixedPaths(probes)
        XCTAssertFalse(paths.contains { $0.contains("/PrivilegedHelperTools/") }, "root 域不碰(ADR-0009):连探测都不做")
    }

    // MARK: brew zap 段

    func testZapPathsMergedDedupedWithGeneric() {
        let zapPath = "~/Library/Application Support/Bitwarden" // 与通用(应用名)行同路径
        let extraPath = "~/Library/Application Support/Bitwarden Profiles" // 通用覆盖不到
        let probes = AppLeftovers.probes(
            bundleID: "com.bitwarden.desktop",
            appName: "Bitwarden",
            brewZapPaths: [zapPath, extraPath]
        )
        func source(of path: String) -> LeftoverSource? {
            for probe in probes {
                if case let .path(p, _, _, _, _, source) = probe, p == path {
                    return source
                }
            }
            return nil
        }
        let support = "\(home)/Library/Application Support"
        // 通用覆盖到的路径不重复成行(各只一条),同路径以收据声明为准。
        XCTAssertEqual(fixedPaths(probes).filter { $0 == "\(support)/Bitwarden" }.count, 1)
        XCTAssertEqual(source(of: "\(support)/Bitwarden"), .caskZap, "同路径以收据声明为准")
        XCTAssertEqual(source(of: "\(support)/Bitwarden Profiles"), .caskZap, "未覆盖处 zap 独立成行")
        XCTAssertEqual(source(of: "\(support)/com.bitwarden.desktop"), .generic, "bid 键通用行不受影响")
    }

    func testZapPathsOutsideHomeDomainFiltered() {
        let probes = AppLeftovers.probes(bundleID: "com.x", appName: "X", brewZapPaths: [
            "/Library/LaunchAgents/com.x.plist", // /Library 层 v1 不碰
            "~/Library/Caches/com.x",
        ])
        let paths = fixedPaths(probes)
        XCTAssertFalse(paths.contains("/Library/LaunchAgents/com.x.plist"))
        XCTAssertTrue(paths.contains("\(home)/Library/Caches/com.x"))
    }

    func testGroupContainersProbeCarriedForEachApp() {
        let probes = AppLeftovers.probes(bundleID: "com.bitwarden.desktop", appName: "Bitwarden")
        XCTAssertTrue(
            probes
                .contains {
                    if case let .groupContainers(bundleID) = $0 {
                        return bundleID == "com.bitwarden.desktop"
                    } else {
                        return false
                    }
                }
        )
    }

    // MARK: 人话映射(Q4 信任三件套)

    func testPlainLanguageCoverageForEverySite() {
        for site in LeftoverSite.allCases {
            XCTAssertFalse(site.plainTitle.isEmpty, "\(site) 缺人话副标")
            XCTAssertFalse(site.consequenceNote.isEmpty, "\(site) 缺「删了会怎样」")
        }
    }

    func testPlainLanguageContainsNoImplementationTerms() {
        // 副标是给不看路径的用户读的:路径段 / 家目录 / 目录名一律不得出现。
        for site in LeftoverSite.allCases {
            for text in [site.plainTitle, site.consequenceNote] {
                XCTAssertFalse(text.contains("/"), "\(site):\(text) 混入路径段")
                XCTAssertFalse(text.contains("~"), "\(site):\(text) 混入家目录")
                XCTAssertFalse(text.lowercased().contains("library"), "\(site):\(text) 混入实现目录名")
            }
        }
    }
}
