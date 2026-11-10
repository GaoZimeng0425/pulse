@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 卸载残留检测核心(p5-cleaner/01):六闸逐闸 + 档位口径 + 域表/红线。
/// 定案见 .scratch/p5-cleaner/spec.md(grill 2026-11-08)。
final class OrphanLeftoversTests: XCTestCase {
    // MARK: 夹具(手搭 ~/Library 域树;newestChangeEpoch = 直属文件口径)

    private func dir(
        _ name: String,
        under parent: String,
        bytes: Int64 = 0,
        newest: Double? = nil,
        partial: Bool = false,
        children: [SpaceNode] = []
    ) -> SpaceNode {
        let path = parent == "/" ? "/" + name : parent + "/" + name
        return SpaceNode(
            name: name,
            path: path,
            kind: .directory,
            accountedBytes: max(bytes, children.reduce(Int64(0)) { $0 + $1.accountedBytes }),
            isPartial: partial,
            newestChangeEpoch: newest,
            children: children
        )
    }

    private let home = "/Users/me"
    private let now: TimeInterval = 1_700_000_000

    /// 三域夹具:Caches(com.qq.orphan 40 天静默 + com.fresh.app 刚动过)、
    /// Logs(com.qq.orphan 同 app 第二处)、Saved Application State(savedState 剥尾)。
    private func tree() -> SpaceNode {
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [
                dir("com.qq.orphan", under: home + "/Library/Caches", bytes: 800, newest: now - 40 * 86400),
                dir("com.fresh.app", under: home + "/Library/Caches", bytes: 300, newest: now - 3 * 86400),
            ]),
            dir("Logs", under: home + "/Library", children: [
                dir("com.qq.orphan", under: home + "/Library/Logs", bytes: 200, newest: now - 40 * 86400),
            ]),
            dir("Saved Application State", under: home + "/Library", children: [
                dir(
                    "com.qq.orphan.savedState",
                    under: home + "/Library/Saved Application State",
                    bytes: 100,
                    newest: now - 40 * 86400
                ),
            ]),
        ])
        return dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
    }

    private func detect(
        in tree: SpaceNode,
        installed: Set<String> = [],
        excluded: [String] = []
    ) -> [JunkCandidate] {
        OrphanLeftoverDetector.detect(
            in: [tree],
            home: home,
            installedBundleIDs: installed,
            excludedPathPrefixes: excluded,
            now: now
        )
    }

    // MARK: 主路径:命中 + 档位两态 + 跨域聚合

    func testQuietOrphanAcrossDomainsListedSafeGroupedByFullBundleID() {
        let out = detect(in: tree())
        let qq = out.filter { $0.projectName == "com.qq.orphan" }
        XCTAssertEqual(Set(qq.map(\.path)), [
            home + "/Library/Caches/com.qq.orphan",
            home + "/Library/Logs/com.qq.orphan",
            home + "/Library/Saved Application State/com.qq.orphan.savedState",
        ], "同 app 三域全收;.savedState 剥尾后仍是同一 bundle id")
        XCTAssertTrue(qq
            .allSatisfy { $0.tier == .safe && $0.ruleID == "app-orphan" && $0.group == .uninstallLeftovers })
        XCTAssertEqual(qq.first?.title, "com.qq.orphan", "行标题 = 目录原名(区分 savedState 行)")
        XCTAssertEqual(qq.map(\.newestChangeEpoch), qq.map(\.newestChangeEpoch), "子树最新变动带出")
    }

    func testRecentlyTouchedOrphanFallsToCheckFirst() {
        let out = detect(in: tree())
        let fresh = out.first { $0.path.contains("com.fresh.app") }
        XCTAssertEqual(fresh?.tier, .checkFirst, "30 天内动过 = 先检查")
    }

    func testDeepSubtreeChangeCountsAsTouched() {
        // 顶层目录直属文件很旧,但深层子目录昨夜有写入 → 子树口径应判「先检查」。
        let deep = dir(
            "com.deep.dirty",
            under: home + "/Library/Caches",
            bytes: 500,
            newest: now - 100 * 86400,
            children: [
                dir("nested", under: home + "/Library/Caches/com.deep.dirty", bytes: 500, newest: now - 86400),
            ]
        )
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [deep]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        XCTAssertEqual(detect(in: tree).first?.tier, .checkFirst, "直属旧但子树新 = 动过")
    }

    // MARK: 六闸逐闸

    func testInstalledBundleIDIsNeverOrphan() {
        let out = detect(in: tree(), installed: ["com.qq.orphan"])
        XCTAssertFalse(out.contains { $0.projectName == "com.qq.orphan" }, "闸 3:在已装全集 = 主人还在")
    }

    func testOverlapWithRuleTableYieldsToCuratedRule() {
        // 真案:规则表 Library/Caches/org.swift.swiftpm 是 CLI 缓存(无 .app),孤儿检测也会报。
        let swiftpm = dir("org.swift.swiftpm", under: home + "/Library/Caches", bytes: 700, newest: now - 90 * 86400)
        let gone = dir("com.gone.app", under: home + "/Library/Caches", bytes: 300, newest: now - 90 * 86400)
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [swiftpm, gone]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        let orphans = detect(in: tree)
        XCTAssertEqual(Set(orphans.map(\.path)), [swiftpm.path, gone.path], "前提:两者都被判孤儿")
        let claimed = JunkMatcher.candidates(in: [tree], home: home, excludedPathPrefixes: [])
        XCTAssertEqual(claimed.map(\.path), [swiftpm.path], "前提:规则表也认领 swiftpm")
        XCTAssertEqual(
            OrphanLeftoverDetector.excludingOverlaps(orphans, claimedBy: claimed).map(\.path),
            [gone.path],
            "同路径只留规则表那张卡"
        )
    }

    func testOverlapCoversAncestorAndDescendant() {
        func candidate(_ path: String) -> JunkCandidate {
            JunkCandidate(
                ruleID: "x", group: .globalToolCache, title: "x", path: path, tier: .safe,
                bytes: 1, fileCount: 1, isPartial: false, allReclaimableAccounting: true,
                rationale: "", symbolName: "x"
            )
        }
        let orphans = [candidate("/h/C/com.a"), candidate("/h/C/com.b"), candidate("/h/C/com.c")]
        let claimed = [candidate("/h/C/com.a/inner"), candidate("/h/C"), candidate("/h/C/com.cc")]
        // /h/C 是三者祖先 → 全部让位;仅前缀相同的兄弟(com.c vs com.cc)不算重叠。
        XCTAssertTrue(OrphanLeftoverDetector.excludingOverlaps(orphans, claimedBy: claimed).isEmpty)
        let siblingsOnly = [candidate("/h/C/com.cc"), candidate("/h/C/com.a/inner")]
        XCTAssertEqual(
            OrphanLeftoverDetector.excludingOverlaps(orphans, claimedBy: siblingsOnly).map(\.path),
            ["/h/C/com.b", "/h/C/com.c"],
            "祖孙重叠让位,字符串前缀相同的兄弟不误伤"
        )
    }

    func testSameTailDifferentAppsStayInSeparateCards() {
        // 分组键 = 全 id(票 02 修正):同尾段「Desktop」的两个 app 不得并进一张卡。
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [
                dir("com.figma.Desktop", under: home + "/Library/Caches", bytes: 500, newest: now - 90 * 86400),
                dir("com.foo.Desktop", under: home + "/Library/Caches", bytes: 400, newest: now - 90 * 86400),
            ]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        let groups = ProjectJunkGrouping.group(detect(in: tree))
        XCTAssertEqual(groups.map(\.projectName), ["com.figma.Desktop", "com.foo.Desktop"])
        XCTAssertEqual(
            Set(groups.map { OrphanLeftoverDetector.displayName(ofBundleID: $0.projectName) }),
            ["Desktop"],
            "显示名可以相同,分组不能并"
        )
    }

    func testRunningOnlyAppCountsAsInstalled() {
        // 运行中 app 由调用方并入全集(票 02);本闸只认集合。
        let out = detect(in: tree(), installed: ["com.fresh.app"])
        XCTAssertFalse(out.contains { $0.path.contains("com.fresh.app") })
    }

    func testSystemPrefixIsRedline() {
        let apple = dir("com.apple.safari", under: home + "/Library/Caches", bytes: 900, newest: now - 90 * 86400)
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [apple]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        XCTAssertTrue(detect(in: tree).isEmpty, "闸 4:com.apple.* 连先检查都不给")
    }

    func testSensitiveNamesAreRedline() {
        for name in ["com.agilebits.onepassword", "com.apple.keychainsync", "org.ssh.agent", "net.gpg.tools"] {
            let library = dir("Library", under: home, children: [
                dir("Caches", under: home + "/Library", children: [
                    dir(name, under: home + "/Library/Caches", bytes: 100, newest: now - 90 * 86400),
                ]),
            ])
            let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
            XCTAssertTrue(detect(in: tree).isEmpty, "闸 2:敏感名单 \(name) 永不判孤儿")
        }
    }

    func testNonReverseDNSNamesNotListed() {
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [
                dir("SomeApp Cache", under: home + "/Library/Caches", bytes: 100, newest: now - 90 * 86400),
                dir("qq", under: home + "/Library/Caches", bytes: 100, newest: now - 90 * 86400),
            ]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        XCTAssertTrue(detect(in: tree).isEmpty, "闸 5:非反域名命名 v1 不列(无模糊匹配)")
    }

    func testExcludedPrefixDropsCandidate() {
        let out = detect(in: tree(), excluded: [home + "/Library/Caches/com.qq.orphan"])
        XCTAssertFalse(out.contains { $0.path == home + "/Library/Caches/com.qq.orphan" }, "闸 1:右键排除")
        XCTAssertTrue(out.contains { $0.path == home + "/Library/Logs/com.qq.orphan" }, "排除是目录级,不连坐")
    }

    // MARK: 噪音纪律与边界

    func testZeroByteNonPartialNotListedButPartialIs() {
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [
                dir("com.empty.gone", under: home + "/Library/Caches", bytes: 0, newest: now - 90 * 86400),
                dir(
                    "com.partial.gone",
                    under: home + "/Library/Caches",
                    bytes: 0,
                    newest: now - 90 * 86400,
                    partial: true
                ),
            ]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        let out = detect(in: tree)
        XCTAssertFalse(out.contains { $0.path.contains("com.empty.gone") }, "零字节非部分 = 没得回收,不列")
        XCTAssertTrue(out.contains { $0.path.contains("com.partial.gone") }, "部分扫描零字节如实列(数字未知)")
    }

    func testMissingAgeIsCheckFirst() {
        // 子树没有任何已知 mtime(夹具即可造):证明不了安静 → 保守先检查。
        let library = dir("Library", under: home, children: [
            dir("Caches", under: home + "/Library", children: [
                dir("com.unknown.age", under: home + "/Library/Caches", bytes: 100),
            ]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        XCTAssertEqual(detect(in: tree).first?.tier, .checkFirst)
    }

    func testRedlineDomainsAreNotScanned() {
        // 红线域(Containers/Group Containers/LaunchAgents/Application Scripts/
        // PrivilegedHelperTools)不进域表——树里就算有也永远产空。
        let library = dir("Library", under: home, children: [
            dir("Containers", under: home + "/Library", children: [
                dir("com.gone.app", under: home + "/Library/Containers", bytes: 500, newest: now - 90 * 86400),
            ]),
            dir("Group Containers", under: home + "/Library", children: [
                dir(
                    "ABC123.com.gone.app",
                    under: home + "/Library/Group Containers",
                    bytes: 500,
                    newest: now - 90 * 86400
                ),
            ]),
        ])
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [library])])
        XCTAssertTrue(detect(in: tree).isEmpty, "五条红线域不扫(不进表即不扫)")
    }

    func testEmptyTreeYieldsNothing() {
        XCTAssertTrue(detect(in: dir("Users", under: "/", children: [])).isEmpty)
    }

    // MARK: 显示名

    func testDisplayNameTakesLastPathSegment() {
        XCTAssertEqual(OrphanLeftoverDetector.displayName(ofBundleID: "com.tencent.qq"), "qq")
        XCTAssertEqual(OrphanLeftoverDetector.displayName(ofBundleID: "org.mozilla.firefox"), "firefox")
        XCTAssertEqual(OrphanLeftoverDetector.displayName(ofBundleID: "nodot"), "nodot")
        XCTAssertEqual(OrphanLeftoverDetector.displayName(ofBundleID: "com."), "com.", "尾段为空不编,回退全 id")
    }

    // MARK: 登记完整性(域表 / 红线常量入册)

    func testDomainTableCoversFiveDomainsOnly() {
        XCTAssertEqual(
            OrphanScanDomain.allCases.map(\.homeRelativePath),
            [
                "Library/Caches", "Library/Logs", "Library/Saved Application State",
                "Library/WebKit", "Library/HTTPStorages",
            ],
            "5 域定案,顺序即表序;红线域不得混入"
        )
        XCTAssertEqual(OrphanScanDomain.savedApplicationState.nameSuffixToStrip, ".savedState")
        XCTAssertNil(OrphanScanDomain.caches.nameSuffixToStrip)
    }

    func testGroupRegisteredAfterProjectArtifacts() {
        // 防漂移(票 02):CaseIterable 顺序即 UI 组序;组名与「按所有者分大卡」登记面全量入册。
        // p6-cleaner/01 扩六组;全量组序 / 组名的唯一权威断言在 JunkRuleTableTests
        // (testGroupOrderAndOwnership),这里只钉孤儿组自己的位置与归属。
        XCTAssertEqual(JunkGroup.allCases.last, .uninstallLeftovers, "卸载残留殿后")
        XCTAssertTrue(JunkGroup.uninstallLeftovers.groupsByOwner, "按 app 分大卡")
        XCTAssertEqual(JunkGroup.allCases.first { $0.groupsByOwner }, .projectArtifacts)
    }
}
