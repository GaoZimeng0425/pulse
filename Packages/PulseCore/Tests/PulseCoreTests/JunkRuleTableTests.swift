@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 安全白名单规则表与匹配器(p4-cleaner/04;ADR-0008)。
/// 核心命题:①每条内置规则至少被一个正例命中——**登记完整性**,新增规则不补正例必红;
/// ②似是而非的目录绝不出现(未命中不显示 = 不可删);③排除只收窄;④空目录不列、部分扫描照列。
/// 全部打在假家目录上(CleanFixture.homeListings),零真盘。
final class JunkRuleTableTests: XCTestCase {
    private let home = "/Users/test"
    private let engine = SpaceScanEngine()

    /// 每条内置规则的正例(家目录相对路径 → 字节)。**新增规则必须在这里补一条**,否则
    /// `testEveryBuiltinRuleHasAPositiveExample` 红——这就是 ADR-0008 说的"安全边界本体"的护栏。
    private let positiveExamples: [String: (path: String, bytes: Int64)] = [
        "xcode.derivedData": ("Library/Developer/Xcode/DerivedData", 28000),
        "xcode.deviceSupport": ("Library/Developer/Xcode/iOS DeviceSupport", 8000),
        "xcode.caches": ("Library/Caches/com.apple.dt.Xcode", 700),
        "xcode.simulatorCaches": ("Library/Developer/CoreSimulator/Caches", 900),
        "swiftpm.cache": ("Library/Caches/org.swift.swiftpm", 1500),
        "homebrew.cache": ("Library/Caches/Homebrew", 3100),
        "npm.cache": (".npm/_cacache", 1800),
        "npm.npx": (".npm/_npx", 200),
        "pnpm.store": ("Library/pnpm/store", 4600),
        "cocoapods.cache": ("Library/Caches/CocoaPods", 900),
        "gradle.caches": (".gradle/caches", 2300),
        "jetbrains.caches": ("Library/Caches/JetBrains", 5400),
        "vscode.cache": ("Library/Application Support/Code/CachedData", 1200),
        "cursor.cache": ("Library/Application Support/Cursor/CachedData", 600),
        "docker.desktopData": ("Library/Containers/com.docker.docker/Data", 21600),
        // p6-cleaner/01 开发工具补行
        "maven.repository": (".m2/repository", 150),
        "cargo.registry": (".cargo/registry", 1800),
        "uv.cache": (".cache/uv", 1600),
        "go.caches": ("go/pkg/mod", 340),
        "pnpm.metadataCache": ("Library/Caches/pnpm", 800),
        "corepack.cache": (".cache/node/corepack", 30),
        "yarn.cache": ("Library/Caches/Yarn", 40),
        "deno.cache": ("Library/Caches/deno", 50),
        "bun.cache": (".bun/install/cache", 70),
        "electron.toolingCaches": ("Library/Caches/electron", 120),
        "xcode.archives": ("Library/Developer/Xcode/Archives", 400),
        "xcode.testDevices": ("Library/Developer/XCTestDevices", 60),
        // p6-cleaner/01 知识库:浏览器(真机目录名,规范大小写)
        "browser.arc": ("Library/Caches/Arc", 1700),
        "browser.dia": ("Library/Caches/Dia", 900),
        "browser.chrome": ("Library/Caches/Google", 100),
        "browser.chromium": ("Library/Caches/Chromium", 10),
        "browser.edge": ("Library/Caches/com.microsoft.edgemac", 10),
        "browser.brave": ("Library/Caches/com.brave.Browser", 10),
        "browser.firefox": ("Library/Caches/org.mozilla.firefox", 10),
        "browser.opera": ("Library/Caches/com.operasoftware.Opera", 10),
        "browser.zen": ("Library/Caches/Zen", 10),
        "browser.safari": ("Library/Caches/com.apple.Safari", 30),
        // p6-cleaner/01 知识库:应用缓存(含三条 Pulse 自定真案)
        "appcache.cloudkit": ("Library/Caches/CloudKit", 1200),
        "appcache.geoservices": ("Library/Caches/GeoServices", 50),
        "appcache.slack": ("Library/Caches/Slack", 10),
        "appcache.discord": ("Library/Caches/Discord", 10),
        "appcache.zoom": ("Library/Caches/zoom.us", 10),
        "appcache.telegram": ("Library/Caches/Telegram", 10),
        "appcache.whatsapp": ("Library/Caches/WhatsApp", 10),
        "appcache.notion": ("Library/Caches/Notion", 10),
        "appcache.spotify": ("Library/Caches/Spotify", 10),
        "appcache.figma": ("Library/Caches/Figma", 10),
        "appcache.linear": ("Library/Caches/Linear", 10),
        "appcache.raycast": ("Library/Caches/Raycast", 10),
        "appcache.alfred": ("Library/Caches/Alfred", 10),
        "appcache.claude": ("Library/Caches/Claude", 10),
        "appcache.chatgpt": ("Library/Caches/ChatGPT", 10),
        "appcache.iterm2": ("Library/Caches/iTerm2", 10),
        "appcache.warp": ("Library/Caches/Warp", 10),
        "appcache.ghostty": ("Library/Caches/Ghostty", 10),
        "appcache.msAutoUpdate": ("Library/Caches/com.microsoft.autoupdate.fba", 10),
        "appcache.edgeUpdater": ("Library/Caches/com.microsoft.EdgeUpdater", 10),
        "appcache.googleUpdater": ("Library/Caches/com.google.Keystone", 10),
        "appcache.easydict": ("Library/Caches/com.izual.Easydict", 120),
        "appcache.doubaoIme": ("Library/Caches/com.bytedance.inputmethod.doubaoime", 200),
        "appcache.zcodeUpdater": ("Library/Caches/@zcodedesktop-updater", 560),
        "appcache.logs": ("Library/Logs", 100),
    ]

    /// 似是而非:名字像、位置像,但不是规则担保的那个目录。一个都不许出现。
    private let lookalikes: [String] = [
        "Library/Developer/Xcode/DerivedDataBackup",
        "Documents/DerivedData",
        "Library/Developer/Xcode/DeviceSupport",
        ".npm/_cacache-old",
        "Library/Caches/Homebrew-mirror",
        "Library/Application Support/Code/User",
        "Library/Containers/com.docker.docker/Settings",
        "Library/Caches",
        "Library/pnpm",
        // p6-cleaner/01:知识库外的 Caches 目录不列(认不出 = 不碰,ADR-0008 / spec 定案 10);
        // 字面匹配大小写敏感,"arc" ≠ "Arc"。
        "Library/Caches/arc",
        "Library/Caches/MyGo Music",
        "Library/Caches/Citro Labs",
    ]

    private func scanHome(
        _ directories: [String: Int64],
        patch: ((inout [String: FakeCleanDirectoryEnumerator.Listing]) -> Void)? = nil
    ) async -> [SpaceNode] {
        var listings = CleanFixture.homeListings(home: home, directories: directories)
        patch?(&listings)
        let fs = FakeCleanDirectoryEnumerator(listings: listings)
        return await engine.scan(SpaceScanOptions(roots: [home], retainFileNodes: false), using: fs).trees
    }

    private func allExamples() -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: positiveExamples.values.map { ($0.path, $0.bytes) })
    }

    /// 规则表里没被任何候选命中的规则。
    private func rulesWithoutHit(_ rules: [JunkRule], candidates: [JunkCandidate]) -> [String] {
        let hit = Set(candidates.map(\.ruleID))
        return rules.map(\.id).filter { !hit.contains($0) }
    }

    // MARK: 登记完整性

    func testEveryBuiltinRuleHasAPositiveExample() async {
        let trees = await scanHome(allExamples())
        let candidates = JunkMatcher.candidates(in: trees, home: home)

        let missing = rulesWithoutHit(JunkRuleTable.builtin, candidates: candidates)
        XCTAssertEqual(missing, [], "这些规则没有正例命中——新增规则必须在 positiveExamples 补一条:\(missing)")
        let stale = Set(positiveExamples.keys).subtracting(JunkRuleTable.builtin.map(\.id))
        XCTAssertEqual(stale, [], "正例表里有规则表不存在的 id(改名 / 删规则后忘了同步)")
        XCTAssertEqual(Set(JunkRuleTable.builtin.map(\.id)).count, JunkRuleTable.builtin.count, "规则 id 必须唯一")
    }

    /// 票面验收:故意加一条无正例的规则,完整性检查必须把它揪出来(红)。
    func testRuleWithoutPositiveExampleIsCaught() async {
        let bogus = JunkRule(
            id: "bogus.noExample",
            group: .globalToolCache,
            title: "没有正例的规则",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/Bogus")],
            tier: .safe,
            rationale: "",
            source: "test",
            symbolName: "questionmark"
        )
        let trees = await scanHome(allExamples())
        let candidates = JunkMatcher.candidates(in: trees, rules: JunkRuleTable.builtin + [bogus], home: home)

        XCTAssertEqual(rulesWithoutHit(JunkRuleTable.builtin + [bogus], candidates: candidates), ["bogus.noExample"])
    }

    // MARK: 未命中不显示

    func testLookalikeDirectoriesNeverAppear() async {
        var dirs = allExamples()
        for lookalike in lookalikes {
            dirs[lookalike] = 9999
        }
        let trees = await scanHome(dirs)
        let paths = Set(JunkMatcher.candidates(in: trees, home: home).map(\.path))

        for lookalike in lookalikes {
            XCTAssertFalse(paths.contains(home + "/" + lookalike), "似是而非的目录出现在清单里:\(lookalike)")
        }
        XCTAssertEqual(paths.count, positiveExamples.count, "正例一个不少、似是而非一个不多")
    }

    func testHomeMissingFromTreesGivesEmptyList() async {
        let trees = await scanHome(allExamples())
        XCTAssertEqual(JunkMatcher.candidates(in: trees, home: "/Users/someone-else"), [])
        XCTAssertEqual(JunkMatcher.candidates(in: [], home: home), [])
    }

    // MARK: 后缀模式与档位

    func testDeviceSupportVariantsEachBecomeOneUnit() async {
        let trees = await scanHome([
            "Library/Developer/Xcode/iOS DeviceSupport": 8000,
            "Library/Developer/Xcode/watchOS DeviceSupport": 2000,
            "Library/Developer/Xcode/tvOS DeviceSupport": 1000,
            "Library/Developer/Xcode/DerivedData": 500,
        ])
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        let deviceSupport = candidates.filter { $0.ruleID == "xcode.deviceSupport" }

        XCTAssertEqual(
            deviceSupport.map(\.title),
            ["Xcode Device Support · iOS", "Xcode Device Support · watchOS", "Xcode Device Support · tvOS"]
        )
        XCTAssertTrue(deviceSupport.allSatisfy { $0.tier == .checkFirst })
        XCTAssertEqual(candidates.first { $0.ruleID == "xcode.derivedData" }?.tier, .safe)
    }

    /// 票面点名的档位:Docker / JetBrains / DeviceSupport 先检查,DerivedData 等可安全清理。
    func testTicketMandatedTiers() {
        XCTAssertEqual(JunkRuleTable.rule(id: "docker.desktopData")?.tier, .checkFirst)
        XCTAssertTrue(JunkRuleTable.rule(id: "docker.desktopData")?.rationale.contains("镜像、容器与卷——删除后全部丢失") == true)
        XCTAssertEqual(JunkRuleTable.rule(id: "jetbrains.caches")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "xcode.deviceSupport")?.tier, .checkFirst)
        // p6-cleaner/01 点名档位:归档不可重建恒先检查;系统联动类先检查;
        // pnpm 元数据缓存与浏览器缓存可安全清理。
        XCTAssertEqual(JunkRuleTable.rule(id: "xcode.archives")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "appcache.cloudkit")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "appcache.geoservices")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "appcache.doubaoIme")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "pnpm.metadataCache")?.tier, .safe)
        XCTAssertEqual(JunkRuleTable.rule(id: "browser.arc")?.tier, .safe)
        for id in [
            "xcode.derivedData",
            "homebrew.cache",
            "npm.cache",
            "pnpm.store",
            "cocoapods.cache",
            "gradle.caches",
            "vscode.cache",
            "cursor.cache",
        ] {
            XCTAssertEqual(JunkRuleTable.rule(id: id)?.tier, .safe, id)
        }
        XCTAssertTrue(
            JunkRuleTable.builtin.allSatisfy { $0.source.contains("MIT") || $0.source.contains("Pulse 自定") },
            "每条规则注明出处:移植标 MIT 来源,自定标 Pulse 自定"
        )
    }

    /// p6-cleaner/01 组序与归属(spec 定案 8):CaseIterable 序即 UI / 总览品类序。
    func testGroupOrderAndOwnership() {
        XCTAssertEqual(
            JunkGroup.allCases.map(\.title),
            ["开发工具", "浏览器", "应用缓存", "项目产物", "AI 模型", "卸载残留"]
        )
        XCTAssertEqual(JunkGroup.allCases.filter(\.groupsByOwner), [.projectArtifacts, .uninstallLeftovers])
        // AI 模型组规则在 02 票落地——01 阶段该组必须无规则(空组不出段)。
        XCTAssertTrue(JunkRuleTable.builtin.filter { $0.group == .aiModels }.isEmpty)
    }

    // MARK: 空目录 / 部分扫描 / 口径

    func testEmptyDirectoryHiddenButPartialDirectoryShown() async {
        let trees = await scanHome([
            "Library/Developer/Xcode/DerivedData": 0,
            "Library/Caches/Homebrew": 0,
        ]) { listings in
            // Homebrew 下有个读不到的子目录:字节 0 但不等于没有——标部分、照列。
            listings[self.home + "/Library/Caches/Homebrew"] = .entries([CleanFixture.directory("locked", fileID: 77)])
            listings[self.home + "/Library/Caches/Homebrew/locked"] = .failure(.permissionDenied)
        }
        let candidates = JunkMatcher.candidates(in: trees, home: home)

        XCTAssertEqual(candidates.map(\.ruleID), ["homebrew.cache"])
        XCTAssertTrue(candidates[0].isPartial)
        XCTAssertEqual(candidates[0].bytes, 0)
    }

    func testCandidateCarriesNodeAccounting() async {
        let trees = await scanHome(allExamples())
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        let derived = candidates.first { $0.ruleID == "xcode.derivedData" }

        XCTAssertEqual(derived?.bytes, 28000)
        XCTAssertEqual(derived?.fileCount, 1)
        XCTAssertEqual(derived?.path, home + "/Library/Developer/Xcode/DerivedData")
        XCTAssertEqual(derived?.allReclaimableAccounting, true)
        XCTAssertEqual(derived?.group, .globalToolCache)
    }

    // MARK: 排除只收窄

    func testExclusionRemovesCandidatesAndOnlyNarrows() async {
        let trees = await scanHome(allExamples())
        let before = JunkMatcher.candidates(in: trees, home: home)
        let after = JunkMatcher.candidates(in: trees, home: home, excludedPathPrefixes: [home + "/Library/Caches/"])

        let beforePaths = Set(before.map(\.path)), afterPaths = Set(after.map(\.path))
        XCTAssertTrue(afterPaths.isSubset(of: beforePaths), "排除只能让清单变短")
        XCTAssertFalse(afterPaths.contains(home + "/Library/Caches/Homebrew"))
        XCTAssertFalse(afterPaths.contains(home + "/Library/Caches/JetBrains"))
        XCTAssertFalse(afterPaths.contains(home + "/Library/Caches/Arc"), "浏览器目录同样被收走")
        XCTAssertTrue(afterPaths.contains(home + "/Library/Developer/Xcode/DerivedData"), "不在排除前缀下的项不受影响")
        // 正例表按前缀推导期望数——规则表扩,断言跟着自动长,不再写死常数。
        let expectedCachesHits = positiveExamples.values.filter { $0.path.hasPrefix("Library/Caches/") }.count
        XCTAssertEqual(before.count - after.count, expectedCachesHits, "Library/Caches 下的规则命中全部被收走")
    }

    // MARK: 排序

    /// p6-cleaner/01 起正例跨多组:全局断言改为「组序单调不降 + 组内大小降序」。
    func testSortedByGroupOrderThenBytesDescending() async {
        let trees = await scanHome(allExamples())
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        let groupOrder = Dictionary(uniqueKeysWithValues: JunkGroup.allCases.enumerated().map { ($1, $0) })

        let orders = candidates.map { groupOrder[$0.group] ?? 0 }
        XCTAssertEqual(orders, orders.sorted(), "候选按 JunkGroup.allCases 组序分段")
        for (_, items) in Dictionary(grouping: candidates, by: \.group) {
            let bytes = items.map(\.bytes)
            XCTAssertEqual(bytes, bytes.sorted(by: >), "组内按实际占用降序")
        }
        XCTAssertEqual(candidates.first?.ruleID, "xcode.derivedData", "第一组最大者开头")
    }
}
