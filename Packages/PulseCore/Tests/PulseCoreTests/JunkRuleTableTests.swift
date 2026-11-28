@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 安全白名单规则表与匹配器(p4-cleaner/04;ADR-0008)。
/// 核心命题:①每条内置规则至少被一个正例命中——**登记完整性**,新增规则不补正例必红;
/// ②似是而非的目录绝不因本表出现(未命中 = 本表不出它;名单外的目录另由通用发现以
/// 「先检查」列出,不在本表);③排除只收窄;④空目录不列、部分扫描照列。
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
        // p6-cleaner/01 知识库:应用缓存(含三条 Pulse 自定真案)。
        // CloudKit 那条 p7-cleaner/09 撤了(iCloud 同步的元数据库,不是可丢弃缓存;
        // 「谁都不列它」由 AppCacheCatalogPortLedgerTests 钉住)。
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
        // p7-cleaner/09:自 purge-app 搬来的知识库条目,一条规则一行正例
        "browser.yab": ("Library/Caches/Yab", 49),
        "appcache.perplexity-updater": ("Library/Caches/ai.perplexity.CometUpdater", 22),
        "appcache.claude-updater": ("Library/Caches/com.anthropic.claudefordesktop.ShipIt", 27),
        "appcache.todesktop-shipit": ("Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt", 40),
        "appcache.shipit-updater-cache": ("Library/Caches/ShipIt", 28),
        "appcache.google-sdks-events": ("Library/Caches/google-sdks-events", 16),
        "appcache.adobe-media-cache-files": ("Library/Caches/Adobe Media Cache Files", 13),
        "appcache.adobe-media-cache": ("Library/Caches/Adobe Media Cache", 24),
        "appcache.adobe-camera-raw": ("Library/Caches/Adobe Camera Raw", 60),
        "appcache.blender": ("Library/Caches/Blender", 26),
        "appcache.sketch": ("Library/Caches/com.bohemiancoding.sketch3", 29),
        "appcache.affinity-designer": ("Library/Caches/com.seriflabs.affinitydesigner2", 34),
        "appcache.affinity-photo": ("Library/Caches/com.seriflabs.affinityphoto2", 34),
        "appcache.effectcraft": ("Library/Caches/EffectCraft", 11),
        "appcache.microsoft-teams": ("Library/Caches/com.microsoft.teams2", 32),
        "appcache.microsoft-word": ("Library/Caches/com.microsoft.Word", 54),
        "appcache.microsoft-excel": ("Library/Caches/com.microsoft.Excel", 43),
        "appcache.grammarly": ("Library/Caches/com.grammarly.ProjectLlama", 11),
        "appcache.loom": ("Library/Caches/com.loom.desktop", 46),
        "appcache.dropbox": ("Library/Caches/com.dropbox.DropboxMacFileHelper", 38),
        "appcache.google-drive": ("Library/Caches/com.google.GoogleDrive", 25),
        "appcache.onedrive": ("Library/Caches/com.microsoft.OneDrive", 35),
        "appcache.openai-codex": ("Library/Caches/com.openai.codex", 57),
        "appcache.granola": ("Library/Caches/com.granola.app", 52),
        "appcache.spokenly": ("Library/Caches/app.spokenly", 52),
        "appcache.ollama": ("Library/Caches/com.ollama.Ollama", 54),
        "appcache.claude-cli-cache": ("Library/Caches/claude-cli-nodejs", 23),
        "appcache.revenuecat": ("Library/Caches/RevenueCat", 16),
        "appcache.proxyman": ("Library/Caches/com.proxyman.NSProxy", 22),
        "appcache.insomnia": ("Library/Caches/com.insomnia.app", 44),
        "appcache.paw-rapi": ("Library/Caches/com.luckymarmot.Paw", 48),
        "appcache.tableplus": ("Library/Caches/com.tinyapp.TablePlus", 46),
        "appcache.postico": ("Library/Caches/at.eggerapps.Postico", 28),
        "appcache.fork-git": ("Library/Caches/com.DanPristupov.Fork", 14),
        "appcache.sourcetree": ("Library/Caches/com.torusknot.SourceTreeNotMAS", 48),
        "appcache.tower-git": ("Library/Caches/com.fournova.Tower3", 39),
        "appcache.jna-libraries": ("Library/Caches/JNA", 43),
        "appcache.screenflow": ("Library/Caches/net.telestream.screenflow", 57),
        "appcache.cleanshot": ("Library/Caches/pl.maketheweb.cleanshotx", 26),
        "appcache.xnapper": ("Library/Caches/com.xnapper.xnapper", 45),
        "appcache.cleanmymac": ("Library/Caches/com.macpaw.CleanMyMac4", 19),
        "appcache.lungo": ("Library/Caches/com.sindresorhus.Lungo", 30),
        "appcache.bartender": ("Library/Caches/com.surteesstudios.Bartender", 40),
        "appcache.codexbar-cache": ("Library/Caches/com.steipete.codexbar", 55),
        "appcache.codexbar-usage-history": ("Library/Caches/CodexBar", 58),
        "appcache.purge-app": ("Library/Caches/io.getpurge.app", 49),
        "appcache.sentry": ("Library/Caches/io.sentry", 31),
        "appcache.datadog": ("Library/Caches/com.datadoghq", 11),
        "appcache.segment": ("Library/Caches/segment", 29),
        "appcache.nt-ware-smartclient": ("Library/Caches/com.nt-ware.SmartClient", 36),
        "appcache.amp-library-agent": ("Library/Caches/com.apple.AMPLibraryAgent", 58),
        "appcache.amsengagementd": ("Library/Caches/com.apple.amsengagementd", 24),
        "appcache.adprivacyd": ("Library/Caches/com.apple.ap.adprivacyd", 27),
        "appcache.apple-media-services": ("Library/Caches/com.apple.AppleMediaServices", 25),
        "appcache.appstoreagent": ("Library/Caches/com.apple.appstoreagent", 34),
        "appcache.assistantd": ("Library/Caches/com.apple.assistantd", 57),
        "appcache.beta-enrollment": ("Library/Caches/com.apple.betaenrollmentagent", 60),
        "appcache.bird": ("Library/Caches/com.apple.bird", 17),
        "appcache.businessservicesd": ("Library/Caches/com.apple.businessservicesd", 44),
        "appcache.cloudd": ("Library/Caches/com.apple.cloudd", 17),
        "appcache.cloud-telemetry": ("Library/Caches/com.apple.CloudTelemetry", 50),
        "appcache.ctcategories": ("Library/Caches/com.apple.ctcategories.service", 23),
        "appcache.donotdisturbd": ("Library/Caches/com.apple.donotdisturbd", 58),
        "appcache.duetexpertd": ("Library/Caches/com.apple.duetexpertd", 13),
        "appcache.feature-access-agent": ("Library/Caches/com.apple.FeatureAccessAgent", 44),
        "appcache.feedbacklogger": ("Library/Caches/com.apple.feedbacklogger", 15),
        "appcache.fileprovider-appstore": ("Library/Caches/com.apple.FileProviderDaemon.AppStoreService", 53),
        "appcache.findmy": ("Library/Caches/com.apple.findmy.fmipcore", 30),
        "appcache.geoanalyticsd": ("Library/Caches/com.apple.geoanalyticsd", 56),
        "appcache.helpd": ("Library/Caches/com.apple.helpd", 13),
        "appcache.homed": ("Library/Caches/com.apple.homed", 48),
        "appcache.itunes": ("Library/Caches/com.apple.iTunes", 14),
        "appcache.managedappdistribution": ("Library/Caches/com.apple.managedappdistributionagent", 22),
        "appcache.nsurlsessiond": ("Library/Caches/com.apple.nsurlsessiond", 37),
        "appcache.parsecd": ("Library/Caches/com.apple.parsecd", 33),
        "appcache.proactive-eventtracker": ("Library/Caches/com.apple.proactive.eventtracker", 23),
        "appcache.remindd": ("Library/Caches/com.apple.remindd", 28),
        "appcache.shazam": ("Library/Caches/com.apple.shazamlibrary.cloud", 37),
        "appcache.siri-tts": ("Library/Caches/com.apple.sirittsd", 27),
        "appcache.spotlight": ("Library/Caches/com.apple.Spotlight", 16),
        "appcache.tipsd": ("Library/Caches/com.apple.tipsd", 55),
        "appcache.videoconference": ("Library/Caches/com.apple.VideoConference", 17),
        "appcache.gamed": ("Library/Caches/com.apple.gamed", 24),
        "appcache.chrono": ("Library/Caches/com.apple.chrono", 31),
        "appcache.translation": ("Library/Caches/com.apple.translationd", 58),
        "appcache.gamekit": ("Library/Caches/GameKit", 39),
        "appcache.apple-maps": ("Library/Caches/com.apple.Maps", 32),
        "appcache.apple-photos": ("Library/Caches/com.apple.Photos", 23),
        "appcache.apple-mail": ("Library/Caches/com.apple.mail", 25),
        "appcache.apple-music-app": ("Library/Caches/com.apple.Music", 41),
        "appcache.network-cache": ("Library/Caches/com.apple.networkserviceproxy", 13),
        "appcache.screenshot-app": ("Library/Caches/com.apple.screencaptureui", 20),
        "appcache.dictionary-services": ("Library/Caches/com.apple.DictionaryServices", 33),
        "appcache.promoted-content": ("Library/Caches/com.apple.ap.PromotedContentJetService", 18),
        "appcache.intelligenceflowd-cache": ("Library/Caches/com.apple.intelligenceflow.intelligenceflowd", 55),
        "appcache.ssu": ("Library/Caches/ssu", 56),
        "appcache.storekitagent": ("Library/Caches/com.apple.storekitagent", 43),
        "appcache.ams-migrator": ("Library/Caches/AMSDataMigratorTool", 30),
        // p7-cleaner/10:自上游补差的开发工具规则与 Electron 应用缓存条目,一条规则一行正例
        "xcode.documentationCache": ("Library/Developer/Xcode/DocumentationCache", 20),
        "xcode.deviceSoftwareService": ("Library/Caches/com.apple.dt.Xcode.ITunesSoftwareService", 13),
        "cocoapods.specRepos": (".cocoapods/repos", 13),
        "npm.logs": (".npm/_logs", 33),
        "dart.pubCache": (".pub-cache/hosted", 42),
        "precommit.environments": (".cache/pre-commit", 28),
        "prek.cache": (".cache/prek/repos", 26),
        "prisma.cache": (".cache/prisma", 39),
        "expo.cache": (".expo/android-apk-cache", 24),
        "pyenv.rbenvDownloads": (".pyenv/cache", 26),
        "ohmyzsh.cache": (".oh-my-zsh/cache", 15),
        "opam.downloads": (".opam/download-cache", 55),
        "puppeteer.browsers": (".cache/puppeteer", 27),
        "dart.analysisCache": (".dartServer/.analysis-driver", 33),
        "hermes.agentCache": (".hermes/cache", 33),
        "opencode.cache": (".cache/opencode", 16),
        "conda.packageCache": (".conda/pkgs", 32),
        "nvm.downloads": (".nvm/.cache", 56),
        "giget.cache": (".cache/giget", 38),
        "firebase.emulators": (".cache/firebase/emulators", 43),
        "hex.packages": (".hex/packages", 21),
        "rebar3.cache": (".cache/rebar3", 39),
        "nuget.packages": (".nuget/packages", 34),
        "cabal.packages": (".cabal/packages", 57),
        "stack.cache": (".stack/pantry", 37),
        "bazel.cache": (".cache/bazel", 41),
        "android.buildCache": (".android/cache", 39),
        "zed.caches": ("Library/Caches/Zed", 29),
        "sbt.ivyCache": (".ivy2/cache", 40),
        "rubygems.downloads": (".gem/specs", 29),
        "bundler.cache": (".bundle/cache", 53),
        "composer.cache": (".composer/cache", 48),
        "terraform.pluginCache": (".terraform.d/plugin-cache", 41),
        "githubActions.cache": (".cache/act", 24),
        "vagrant.cache": (".vagrant.d/boxes", 47),
        "zsh.sessions": (".zsh_sessions", 52),
        "playwright.browsers": ("Library/Caches/ms-playwright", 38),
        "typescript.typeCache": ("Library/Caches/typescript", 43),
        "cypress.binaries": ("Library/Caches/Cypress", 39),
        "mise.cache": ("Library/Caches/mise", 19),
        "androidStudio.caches": ("Library/Caches/com.google.android.studio", 38),
        "apple.pythonCache": ("Library/Caches/com.apple.python", 55),
        "simulator.runtimeCache": ("Library/Caches/com.apple.iphonesimulator", 57),
        "pulse.swiftpmCache": ("Library/Caches/pulse-swiftpm", 55),
        "go.moduleCache": ("go/pkg/mod", 32),
        "go.buildCache": ("Library/Caches/go-build", 19),
        "appcache.electronApps": ("Library/Application Support/Slack/Cache", 29),
        "appcache.logs": ("Library/Logs", 100),
        // p6-cleaner/02:AI 模型四存储位(全「先检查」)
        "ai.ollama": (".ollama/models", 1100),
        "ai.lmstudio": (".lmstudio/models", 900),
        "ai.huggingface": (".cache/huggingface", 2700),
        "ai.gpt4all": ("Library/Application Support/GPT4All", 400),
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
        // p6-cleaner/01:知识库外的 Caches 目录不经本表(本表不出它;名单外的由通用发现
        // 另列,ADR-0013);字面匹配大小写敏感,"arc" ≠ "Arc"。
        "Library/Caches/arc",
        "Library/Caches/MyGo Music",
        "Library/Caches/Citro Labs",
        // p6-cleaner/02:AI 存储位的似是而非(变体 / 邻居目录)
        ".ollama/models-old",
        ".lmstudio/models-archive",
        "Library/Application Support/GPT4All-backup",
        ".ollama/keys",
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
        // p7-cleaner/01:规则表产出的候选不带任何条目标志——「需要管理员权限」「未识别」
        // 只由后续票的系统级规则与通用发现给出,本票不改变扫描结果。
        XCTAssertTrue(candidates.allSatisfy(\.flags.isEmpty), "规则表候选默认无标志")
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

    // MARK: 未命中本表不出

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
        XCTAssertEqual(JunkRuleTable.rule(id: "appcache.geoservices")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "appcache.doubaoIme")?.tier, .checkFirst)
        // p7-cleaner/09 逐条过目:上游只要用户下载过离线歌曲就不提供 Spotify 的缓存(清它会连
        // 离线歌曲一起带走),我们查不了有没有离线歌曲——恒「先检查」。
        XCTAssertEqual(JunkRuleTable.rule(id: "appcache.spotify")?.tier, .checkFirst)
        XCTAssertEqual(JunkRuleTable.rule(id: "pnpm.metadataCache")?.tier, .safe)
        XCTAssertEqual(JunkRuleTable.rule(id: "browser.arc")?.tier, .safe)
        for id in [
            "xcode.derivedData",
            "homebrew.cache",
            "npm.cache",
            "pnpm.store",
            "cocoapods.cache",
            "vscode.cache",
            "cursor.cache",
        ] {
            XCTAssertEqual(JunkRuleTable.rule(id: id)?.tier, .safe, id)
        }
        // p7-cleaner/10 对齐上游档位:上游 medium 的一律「先检查」(p6 时 Gradle / Maven / uv 判了
        // 「可安全清理」);Go 的两处缓存拆开,模块缓存先检查、构建缓存可安全清理。
        for id in ["gradle.caches", "maven.repository", "uv.cache", "go.moduleCache", "xcode.deviceSoftwareService"] {
            XCTAssertEqual(JunkRuleTable.rule(id: id)?.tier, .checkFirst, id)
        }
        XCTAssertEqual(JunkRuleTable.rule(id: "go.buildCache")?.tier, .safe)
        XCTAssertTrue(
            JunkRuleTable.builtin.allSatisfy { $0.source.contains("MIT") || $0.source.contains("Pulse 自定") },
            "每条规则注明出处:移植标 MIT 来源,自定标 Pulse 自定"
        )
    }

    /// p6-cleaner/01 组序与归属(spec 定案 8):CaseIterable 序即 UI / 总览品类序。
    /// p7-cleaner/01 在卸载残留之后追加「系统级」「安装包」两组(空组不出段)。
    func testGroupOrderAndOwnership() {
        XCTAssertEqual(
            JunkGroup.allCases.map(\.title),
            ["开发工具", "浏览器", "应用缓存", "项目产物", "AI 模型", "卸载残留", "系统级", "安装包"]
        )
        XCTAssertEqual(JunkGroup.allCases.filter(\.groupsByOwner), [.projectArtifacts, .uninstallLeftovers])
        // p6-cleaner/02:AI 组四条存储位规则落地,恒「先检查」,组不按所有者聚卡。
        let aiRules = JunkRuleTable.builtin.filter { $0.group == .aiModels }
        XCTAssertEqual(Set(aiRules.map(\.id)), ["ai.ollama", "ai.lmstudio", "ai.huggingface", "ai.gpt4all"])
        XCTAssertTrue(aiRules.allSatisfy { $0.tier == .checkFirst }, "AI 模型组恒「先检查」(重下载代价大)")
        XCTAssertTrue(aiRules.allSatisfy { !$0.rationale.isEmpty }, "每条规则 rationale 非空")
        XCTAssertTrue(aiRules.allSatisfy { $0.source.contains("Pulse 自定") }, "AI 规则来源 = Pulse 自定(存储位常识,非移植)")
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
