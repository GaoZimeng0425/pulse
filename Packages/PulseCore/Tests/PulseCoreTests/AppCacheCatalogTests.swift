@testable import PulseCore
import XCTest

/// 应用缓存知识库完整性(p6-cleaner/01 建;p7-cleaner/09 自 purge-app 全量搬运):条目良构 +
/// 跨条目不撞名 + 不与开发工具规则的 Caches 目录撞名(撞名 = 同路径两张卡、重复计数);
/// 每个目录名都有正例、相似名不被认领、不碰保护名单、苹果自家的恒「先检查」;
/// 搬运前被通用发现标「未识别」的目录,搬运后按规则表档位出现。
/// 全部打在假家目录上(`JunkCacheScanFixture`),零真盘。
final class AppCacheCatalogTests: XCTestCase {
    // MARK: 条目良构

    func testEntriesAreWellFormed() {
        for entry in AppCacheCatalog.entries {
            XCTAssertFalse(entry.key.isEmpty, "key 不能为空")
            XCTAssertFalse(entry.names.isEmpty, "\(entry.key):至少一个目录名")
            XCTAssertTrue(
                entry.names.allSatisfy { !$0.isEmpty && !$0.contains("/") },
                "\(entry.key):names 是 Caches 一级目录名,不含路径分隔符"
            )
            XCTAssertTrue(entry.group == .browserCache || entry.group == .appCache, "\(entry.key):知识库只进浏览器/应用缓存两组")
            XCTAssertFalse(entry.title.isEmpty, "\(entry.key):标题非空")
            XCTAssertFalse(entry.rationale.isEmpty, "\(entry.key):rationale 非空(确认清单靠它说话)")
            // 出处要么是上游说明库(MIT,可移植),要么以「Pulse 自定」开头并写清缘由。写别的等于没写。
            XCTAssertTrue(
                entry.source == JunkRuleTable.purgeAppExplanations || entry.source.hasPrefix(JunkRuleTable.pulseCustom),
                "\(entry.key):出处必须是上游说明库或 Pulse 自定,现在是「\(entry.source)」"
            )
        }
    }

    func testNoDuplicateDirectoryNamesAcrossEntries() {
        let names = AppCacheCatalog.entries.flatMap(\.names)
        XCTAssertEqual(names.count, Set(names).count, "目录名跨条目重复:先到的规则吃掉后到的,后条目变死规则")
    }

    func testKeysAreUnique() {
        let keys = AppCacheCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "key 重复会让规则 id 撞车")
    }

    /// 知识库目录名不得与开发工具规则的 `Library/Caches/<名>` 一级名相同
    /// (Homebrew / JetBrains / pnpm / electron 等——撞名 = 一条路径两张卡)。
    func testCatalogNamesDoNotCollideWithToolCacheRules() {
        let toolCachesNames = Set(
            JunkRuleTable.globalToolCacheRules.flatMap { rule in
                rule.patterns.compactMap { pattern -> String? in
                    guard pattern.components.count == 3,
                          case let .literal(first) = pattern.components[0], first == "Library",
                          case let .literal(second) = pattern.components[1], second == "Caches",
                          case let .literal(third) = pattern.components[2]
                    else { return nil }
                    return third
                }
            }
        )
        XCTAssertFalse(toolCachesNames.isEmpty, "解剖 pattern 的写法失效了——护栏在空转")

        for entry in AppCacheCatalog.entries {
            for name in entry.names {
                XCTAssertFalse(
                    toolCachesNames.contains(name),
                    "\(entry.key) 的目录名「\(name)」与开发工具规则撞名,应二选一"
                )
            }
        }
    }

    /// 知识库规则全部指向 ~/Library/Caches 下的字面目录(不越域);规则 id 由条目自己给出。
    func testRulesStayInsideCachesDomainAndFollowTheirEntries() {
        XCTAssertEqual(AppCacheCatalog.rules.map(\.id), AppCacheCatalog.entries.map(\.ruleID))
        for rule in AppCacheCatalog.rules {
            XCTAssertTrue(rule.id.hasPrefix("browser.") || rule.id.hasPrefix("appcache."), rule.id)
            for pattern in rule.patterns {
                XCTAssertEqual(pattern.components.count, 3, "\(rule.id):只允许 Library/Caches/<名> 三段")
                guard case let .literal(first) = pattern.components.first else {
                    XCTFail("\(rule.id):首段必须是字面 Library")
                    continue
                }
                XCTAssertEqual(first, "Library", "\(rule.id):只允许 Library 域")
            }
        }
    }

    // MARK: 登记完整性(p7-cleaner/09)

    /// 每个目录名一个正例:一次扫描里把知识库登记的全部目录名都摆进假家目录,一个目录名出一条
    /// 候选,规则、档位、分组、标题、说明、图标都与条目一致,不带任何条目标志。目录名取自条目
    /// 本身,新增条目不必另写用例。
    func testEveryDirectoryNameYieldsOneCandidateAtTheEntryTier() async {
        let home = JunkCacheScanFixture.home
        let allNames = AppCacheCatalog.entries.flatMap(\.names)
        let byPath = await Dictionary(uniqueKeysWithValues: JunkCacheScanFixture.candidates(cachesNames: allNames).map {
            ($0.path, $0)
        })

        XCTAssertEqual(byPath.count, allNames.count, "一个目录名一条,不多不少")
        for entry in AppCacheCatalog.entries {
            for name in entry.names {
                let candidate = byPath[home + "/Library/Caches/" + name]
                XCTAssertNotNil(candidate, "\(entry.key) 的目录名「\(name)」没有被规则表认领")
                XCTAssertEqual(candidate?.ruleID, entry.ruleID, name)
                XCTAssertEqual(candidate?.tier, entry.tier, name)
                XCTAssertEqual(candidate?.group, entry.group, name)
                XCTAssertEqual(candidate?.title, entry.title, name)
                XCTAssertEqual(candidate?.rationale, entry.rationale, name)
                XCTAssertEqual(candidate?.symbolName, entry.symbolName, name)
                XCTAssertEqual(candidate?.flags, [], "\(name):规则表候选不带条目标志")
            }
        }
    }

    /// 相似名不被认领:每个目录名加后缀(-old、.old、Backup)或只改大小写,都不是知识库担保的
    /// 那个目录,规则表一条都不出(名单外的另由通用发现以「先检查」列出)。字面精确匹配,所以
    /// 只差大小写的写法不算;同一条目自己登记了另一种大小写的(「Zen」与「zen」)照认。
    func testLookalikeNamesAreNotClaimed() async {
        let registered = Set(AppCacheCatalog.entries.flatMap(\.names))
        var lookalikes = Set<String>()
        for name in registered {
            lookalikes.insert(name + "-old")
            lookalikes.insert(name + ".old")
            lookalikes.insert(name + " Backup")
            lookalikes.insert(name.lowercased())
            lookalikes.insert(name.uppercased())
        }
        lookalikes.subtract(registered)

        let claimed = await JunkCacheScanFixture.candidates(cachesNames: lookalikes.sorted())

        XCTAssertEqual(claimed.map(\.path), [], "相似名被规则表认领了")
    }

    // MARK: 安全闸(p7-cleaner/09)

    /// 知识库的规则命中不经通用发现那道保护名单的闸(规则表先认领),所以名单上的东西这里一条
    /// 都不能有——判定直接用保护名单自己的 `isProtected`,不在测试里另写一遍匹配。
    /// 例外逐个点名,各有缘由:
    ///   · 苹果的目录名(`isSystemOwned` 在保护名单里也算受保护):它们走知识库逐条担保,
    ///     「不进安全档」由 `testAppleOwnedEntriesAreNeverAutoSelected` 另管;
    ///   · Safari 条目的「Safari」:p6 登记的缓存目录名,与个人数据名单里的 `~/Library/Safari`
    ///     资料目录同名不同处——名单按整名相等拦的是资料目录;
    ///   · 名字里带「google」的九个:保护名单里的词片段「google」是通用发现「不认识却整个
    ///     扫走」时的硬跳过(对齐对象的事故:Chrome 在跑),管不到知识库逐条担保的条目。
    ///     新加带 google 的目录名要有意识地在这里加一行。
    func testCatalogNeverClaimsProtectedNames() {
        let exempt: Set<[String]> = [ // [条目 key, 目录名]
            ["safari", "Safari"],
            ["chrome", "Google"], ["chrome", "com.google.Chrome"],
            ["iterm2", "com.googlecode.iterm2"],
            ["googleUpdater", "com.google.Keystone"], ["googleUpdater", "com.google.GoogleUpdater"],
            ["googleUpdater", "com.google.antigravity.ShipIt"],
            ["google-drive", "com.google.GoogleDrive"], ["google-drive", "Google Drive"],
            ["google-sdks-events", "google-sdks-events"],
        ]
        let catalogPairs = Set(AppCacheCatalog.entries.flatMap { entry in
            entry.names.map { [entry.key, $0] }
        })

        var checked = 0
        for pair in catalogPairs {
            if exempt.contains(pair) || DiscoveryProtectionList.isSystemOwned(name: pair[1]) {
                continue
            }
            checked += 1
            XCTAssertFalse(
                DiscoveryProtectionList.isProtected(name: pair[1]),
                "\(pair[0]) 的目录名「\(pair[1])」命中保护名单"
            )
        }
        XCTAssertGreaterThan(checked, 0, "护栏在空转")

        // 点名的例外都得还在、且确实命中保护名单,免得例外名单烂在这里。
        for pair in exempt.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            XCTAssertTrue(catalogPairs.contains(pair), "点名的例外 \(pair) 已不在知识库里,把这一行删掉")
            XCTAssertTrue(
                DiscoveryProtectionList.isProtected(name: pair[1]),
                "点名的例外 \(pair) 现在并不命中保护名单,这一行多余了"
            )
        }
    }

    /// 苹果自家的缓存恒「先检查」:守护进程常驻,没有可靠的「在运行」信号;上游把其中不少
    /// 标成安全,我们一律不自动勾。按目录名判归属(`com.apple.` 前缀,加保护名单里那批不带
    /// 前缀的守护进程缓存)。例外只有 Safari——浏览器一组同档是 p6 的既有决定,本票不动。
    func testAppleOwnedEntriesAreNeverAutoSelected() {
        var offenders: [String] = []
        var appleNames: [String] = []
        for entry in AppCacheCatalog.entries {
            for name in entry.names where DiscoveryProtectionList.isSystemOwned(name: name) {
                appleNames.append(name)
                if entry.key != "safari", entry.tier == .safe {
                    offenders.append("\(entry.key):\(name)")
                }
            }
        }
        XCTAssertFalse(appleNames.isEmpty, "护栏在空转:知识库里一个苹果的目录名都没有")
        XCTAssertTrue(AppCacheCatalog.entries.contains { $0.key == "safari" }, "例外里的条目 safari 已不存在,把例外删掉")
        XCTAssertEqual(offenders, [], "苹果自家的缓存不能进「可安全清理」")
    }

    /// 票面验收:搬运前被通用发现标「未识别」的样例目录,搬运后按规则表档位出现、不再带
    /// 「未识别」;苹果的样例搬运前根本不列(通用发现不列苹果自家的),搬运后带着说明出现在
    /// 「先检查」。名单外的目录,前后都只在通用发现里。
    func testPortedDirectoriesMoveFromUnidentifiedToRuleTier() async {
        let home = JunkCacheScanFixture.home
        let samples: [(name: String, tier: CleanSafetyTier, group: JunkGroup)] = [
            ("ai.perplexity.CometUpdater", .safe, .appCache),
            ("Yab", .checkFirst, .browserCache),
            ("com.apple.helpd", .checkFirst, .appCache),
        ]
        let unknown = "SomeUnknownTool"
        let scanned = await JunkCacheScanFixture.trees(cachesNames: samples.map(\.name) + [unknown])

        // 搬运前:规则表里去掉知识库的目录规则,其余规则照旧。
        let catalogRuleIDs = Set(AppCacheCatalog.rules.map(\.id))
        let before = JunkMatcher.candidates(
            in: scanned,
            rules: JunkRuleTable.builtin.filter { !catalogRuleIDs.contains($0.id) },
            home: home
        )
        let beforeGeneric = GenericDiscovery.detect(
            in: scanned,
            home: home,
            claimedBy: before,
            excludedPathPrefixes: []
        )
        XCTAssertEqual(
            Set(beforeGeneric.map(\.path)),
            Set([samples[0].name, samples[1].name, unknown].map { home + "/Library/Caches/" + $0 })
        )
        XCTAssertTrue(beforeGeneric.allSatisfy { $0.flags == [.unidentified] && $0.tier == .checkFirst })

        // 搬运后。
        let after = JunkMatcher.candidates(in: scanned, home: home)
        let afterGeneric = GenericDiscovery.detect(in: scanned, home: home, claimedBy: after, excludedPathPrefixes: [])
        XCTAssertEqual(afterGeneric.map(\.path), [home + "/Library/Caches/" + unknown], "样例都被知识库认领,通用发现只剩名单外的")
        for sample in samples {
            let candidate = after.first { $0.path == home + "/Library/Caches/" + sample.name }
            XCTAssertNotNil(candidate, "\(sample.name):搬运后规则表不认它")
            XCTAssertEqual(candidate?.tier, sample.tier, sample.name)
            XCTAssertEqual(candidate?.group, sample.group, sample.name)
            XCTAssertEqual(candidate?.flags, [], "\(sample.name):不再带「未识别」")
        }
    }
}
