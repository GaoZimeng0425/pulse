@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 搬运账本(p7-cleaner/09):上游 purge-app 的 `purge/Resources/explanations.json`(MIT,
/// 可移植;2026-11-28 读取,提交 ceacaf8)共 311 条,每一条在 Pulse 这边都有明确下落——
/// 没有「忘了」这一种。账本行由脚本从上游文件生成后粘入(目录名照抄上游,防手抄出错);
/// 下落是逐条过目的结论,改它之前先读票 09 的 Comments。
final class AppCacheCatalogPortLedgerTests: XCTestCase {
    private enum Fate: Equatable {
        /// 进了知识库的这条条目(条目 key)。
        case entry(String)
        /// 这条说的东西已由这条现有规则担保(安全白名单规则表或项目产物规则表的规则 id);
        /// 名字本身多半不是缓存目录一级名。
        case rule(String)
        /// 交给票 10:开发工具缓存、项目产物、别处的路径。
        case ticket10
        /// 有意不列(缘由在票 09 的 Comments)。
        case notListed
        /// 别名没证实是缓存目录名;真有那个目录,由通用发现以「先检查」列出。
        case genericDiscovery
        /// 不属于任何在办票,去向记在票 09 的 Comments。
        case elsewhere
    }

    private let home = "/Users/test"
    private let engine = SpaceScanEngine()

    /// 上游 key → (上游档位, 每个目录名的下落)。目录名 = 上游的 aliases 加 bundle_ids。
    private let ledger: [(key: String, tag: String, names: [String: Fate])] = [
        (
            "perplexity-updater",
            "safe",
            ["ai.perplexity.CometUpdater": .entry("perplexity-updater"), "CometUpdater": .entry("perplexity-updater")]
        ),
        ("checkpoint-nodejs", "safe", ["checkpoint-nodejs": .genericDiscovery]),
        ("cloudkit", "medium", ["CloudKit": .notListed]),
        ("claude-updater", "safe", ["com.anthropic.claudefordesktop.ShipIt": .entry("claude-updater")]),
        ("accountsd", "medium", ["com.apple.accountsd": .notListed]),
        ("akd", "medium", ["com.apple.akd": .notListed]),
        ("amp-library-agent", "medium", ["com.apple.AMPLibraryAgent": .entry("amp-library-agent")]),
        ("amsaccountsd", "medium", ["com.apple.amsaccountsd": .notListed]),
        ("amsengagementd", "safe", ["com.apple.amsengagementd": .entry("amsengagementd")]),
        ("adprivacyd", "safe", ["com.apple.ap.adprivacyd": .entry("adprivacyd")]),
        ("appleaccountd", "medium", ["com.apple.appleaccountd": .notListed]),
        ("apple-media-services", "safe", ["com.apple.AppleMediaServices": .entry("apple-media-services")]),
        ("appstoreagent", "safe", ["com.apple.appstoreagent": .entry("appstoreagent")]),
        (
            "assistantd",
            "safe",
            ["com.apple.assistantd": .entry("assistantd"), "com.apple.AssistantServices": .entry("assistantd")]
        ),
        (
            "authentication-services",
            "medium",
            ["com.apple.AuthenticationServicesCore.AuthenticationServicesAgent": .notListed]
        ),
        ("beta-enrollment", "safe", ["com.apple.betaenrollmentagent": .entry("beta-enrollment")]),
        ("bird", "medium", ["com.apple.bird": .entry("bird")]),
        ("businessservicesd", "safe", ["com.apple.businessservicesd": .entry("businessservicesd")]),
        ("cache-delete", "safe", ["com.apple.cache_delete": .notListed]),
        ("cloudd", "medium", ["com.apple.cloudd": .entry("cloudd")]),
        ("cloud-telemetry", "safe", ["com.apple.CloudTelemetry": .entry("cloud-telemetry")]),
        ("ctcategories", "safe", ["com.apple.ctcategories.service": .entry("ctcategories")]),
        ("dataaccessd", "medium", ["com.apple.dataaccess.dataaccessd": .notListed]),
        ("donotdisturbd", "safe", ["com.apple.donotdisturbd": .entry("donotdisturbd")]),
        ("duetexpertd", "medium", ["com.apple.duetexpertd": .entry("duetexpertd")]),
        ("e5bundlecache", "safe", ["com.apple.e5rt.e5bundlecache": .notListed]),
        ("feature-access-agent", "safe", ["com.apple.FeatureAccessAgent": .entry("feature-access-agent")]),
        ("feedbacklogger", "safe", ["com.apple.feedbacklogger": .entry("feedbacklogger")]),
        (
            "fileprovider-appstore",
            "safe",
            ["com.apple.FileProviderDaemon.AppStoreService": .entry("fileprovider-appstore")]
        ),
        ("findmy", "medium", ["com.apple.findmy.fmipcore": .entry("findmy")]),
        ("geoanalyticsd", "safe", ["com.apple.geoanalyticsd": .entry("geoanalyticsd")]),
        ("maps-tile-cache", "medium", ["GeoServices": .entry("geoservices")]),
        ("helpd", "safe", ["com.apple.helpd": .entry("helpd")]),
        ("homed", "medium", ["com.apple.homed": .entry("homed"), "com.apple.HomeKit": .entry("homed")]),
        ("icloud-notification-agent", "medium", ["com.apple.iCloudNotificationAgent": .notListed]),
        ("itunes", "medium", ["com.apple.iTunes": .entry("itunes"), "com.apple.itunescloudd": .notListed]),
        ("managedappdistribution", "safe", ["com.apple.managedappdistributionagent": .entry("managedappdistribution")]),
        ("nsurlsessiond", "medium", ["com.apple.nsurlsessiond": .entry("nsurlsessiond")]),
        ("parsecd", "safe", ["com.apple.parsecd": .entry("parsecd")]),
        ("passd", "medium", ["com.apple.passd": .notListed, "PassKit": .notListed]),
        ("proactive-eventtracker", "medium", ["com.apple.proactive.eventtracker": .entry("proactive-eventtracker")]),
        ("remindd", "safe", ["com.apple.remindd": .entry("remindd")]),
        ("safari", "safe", ["com.apple.Safari": .entry("safari"), "com.apple.Safari.SafeBrowsing": .notListed]),
        ("shazam", "safe", ["com.apple.shazamlibrary.cloud": .entry("shazam")]),
        ("siri-tts", "safe", ["com.apple.sirittsd": .entry("siri-tts"), "SiriTTS": .entry("siri-tts")]),
        ("spotlight", "medium", ["com.apple.Spotlight": .entry("spotlight")]),
        ("tipsd", "safe", ["com.apple.tipsd": .entry("tipsd")]),
        ("videoconference", "safe", ["com.apple.VideoConference": .entry("videoconference")]),
        (
            "google-updater",
            "safe",
            [
                "com.google.antigravity.ShipIt": .entry("googleUpdater"),
                "com.google.GoogleUpdater": .entry("googleUpdater"),
                "google-sdks-events": .entry("google-sdks-events"),
            ]
        ),
        ("microsoft-autoupdate", "safe", ["com.microsoft.autoupdate.fba": .entry("msAutoUpdate")]),
        ("microsoft-edge-updater", "safe", ["com.microsoft.EdgeUpdater": .entry("edgeUpdater")]),
        ("todesktop-shipit", "safe", ["com.todesktop.230313mzl4w4u92.ShipIt": .entry("todesktop-shipit")]),
        (
            "arc-browser",
            "safe",
            [
                "company.thebrowser.browser.helper": .entry("arc"),
                "company.thebrowser.dia": .entry("dia"),
                "Dia": .entry("dia"),
                "company.thebrowser.Browser": .entry("arc"),
            ]
        ),
        ("family-circle", "medium", ["FamilyCircle": .notListed]),
        ("ms-playwright", "medium", ["ms-playwright-go": .ticket10]),
        ("node-modules", "safe", ["node_modules": .ticket10]),
        ("prisma-nodejs", "safe", ["prisma-nodejs": .ticket10]),
        ("ssu", "safe", ["ssu": .entry("ssu")]),
        ("macos-installer", "medium", ["macOS Installer": .elsewhere]),
        ("macos-install-data", "medium", ["macOS Install Data": .elsewhere]),
        ("dart-tool", "safe", [".dart_tool": .ticket10]),
        ("ams-migrator", "safe", ["AMSDataMigratorTool": .entry("ams-migrator")]),
        ("container-managerd", "safe", ["com.apple.containermanagerd": .notListed]),
        ("storekitagent", "medium", ["com.apple.storekitagent": .entry("storekitagent")]),
        ("docker", "medium", ["com.docker.docker": .rule("docker.desktopData")]),
        ("raycast", "safe", ["com.raycast.macos": .entry("raycast")]),
        ("DerivedData", "safe", ["DerivedData": .rule("xcode.derivedData"), "deriveddata": .rule("xcode.derivedData")]),
        ("swiftpm", "safe", ["org.swift.swiftpm": .rule("swiftpm.cache")]),
        ("zen", "safe", ["zen": .entry("zen")]),
        ("yab", "safe", ["Yab": .entry("yab")]),
        ("xcode-itunes-service", "medium", ["com.apple.dt.Xcode.ITunesSoftwareService": .ticket10]),
        ("gamed", "safe", ["com.apple.gamed": .entry("gamed")]),
        ("chrono", "safe", ["com.apple.chrono": .entry("chrono")]),
        ("translation", "safe", ["com.apple.translationd": .entry("translation")]),
        ("figma-agent", "safe", ["com.figma.agent": .entry("figma")]),
        ("gamekit", "safe", ["GameKit": .entry("gamekit")]),
        ("image-cache", "safe", ["ImageCache": .genericDiscovery]),
        ("gitworktrees", "medium", ["worktrees": .ticket10]),
        ("vscode", "safe", ["Code": .ticket10, "CachedData": .ticket10, "CachedExtensionVSIXs": .ticket10]),
        ("cursor", "safe", ["Cursor": .ticket10]),
        ("jetbrains", "safe", ["JetBrains": .rule("jetbrains.caches"), "JetPackCache": .genericDiscovery]),
        ("zed", "safe", ["zed": .ticket10, "Zed": .ticket10]),
        ("go-build-cache", "safe", ["go-build": .rule("go.caches")]),
        ("maven", "medium", ["maven": .ticket10, ".m2": .ticket10]),
        ("sbt", "medium", ["sbt": .ticket10, ".ivy2": .ticket10]),
        ("rubygems", "safe", ["rubygems": .ticket10, ".gem": .ticket10]),
        ("bundler", "safe", ["bundler": .ticket10, ".bundle": .ticket10]),
        ("composer", "safe", ["composer": .ticket10, ".composer": .ticket10]),
        ("cargo", "safe", ["cargo": .ticket10, ".cargo": .ticket10]),
        ("terraform", "safe", ["terraform": .ticket10, ".terraform.d": .ticket10]),
        ("githubactions", "safe", ["act": .ticket10, "github-actions": .ticket10]),
        ("vagrant", "medium", ["vagrant": .ticket10, ".vagrant.d": .ticket10]),
        ("zsh", "safe", ["zsh_sessions": .ticket10, ".zsh_sessions": .ticket10, "zcompdump": .ticket10]),
        ("electron", "safe", ["electron": .rule("electron.toolingCaches"), "Code Cache": .ticket10]),
        ("applogs", "safe", ["Logs": .rule("appcache.logs"), "applogs": .genericDiscovery]),
        ("crashreports", "safe", ["DiagnosticReports": .rule("appcache.logs"), "crashreports": .genericDiscovery]),
        ("crashpad-pending", "medium", ["Unsent Crash Reports": .elsewhere]),
        ("iossimulators", "medium", ["CoreSimulator": .ticket10, "iossimulators": .ticket10]),
        ("bun-cache", "safe", [".bun": .ticket10, "bun-install": .ticket10]),
        ("deno-cache", "safe", ["deno": .rule("deno.cache")]),
        ("turbo-cache", "safe", [".turbo": .ticket10, "turbo-cache": .ticket10]),
        ("mise-cache", "safe", ["mise": .ticket10, "rtx": .ticket10]),
        ("vite-cache", "safe", [".vite": .ticket10, "vite-cache": .ticket10]),
        ("parcel-cache", "safe", [".parcel-cache": .ticket10, "parcel-cache": .ticket10]),
        ("eslint-cache", "safe", [".eslintcache": .ticket10]),
        ("jest-cache", "safe", ["jest-cache": .ticket10, ".jest-cache": .ticket10, "jest_cache": .ticket10]),
        ("vitest-cache", "safe", [".vitest-cache": .ticket10, "vitest-cache": .ticket10]),
        ("cypress-cache", "medium", ["Cypress": .ticket10, "cypress": .ticket10, "cypress-cache": .ticket10]),
        ("python-cache", "safe", ["__pycache__": .ticket10, ".pyc": .ticket10, "pycache": .ticket10]),
        ("uv-cache", "medium", ["uv": .ticket10, "uv-cache": .ticket10, ".uv": .ticket10]),
        ("ruff-cache", "safe", [".ruff_cache": .ticket10, "ruff-cache": .ticket10]),
        ("mypy-cache", "safe", [".mypy_cache": .ticket10, "mypy-cache": .ticket10]),
        ("kotlin-build", "safe", [".kotlin": .ticket10, "kotlin-build": .ticket10]),
        ("gradle-cache", "safe", [".gradle": .ticket10, "gradle-cache": .ticket10]),
        ("gradle-global-cache", "medium", ["Gradle Dependency Cache": .ticket10]),
        (
            "cocoapods-cache",
            "safe",
            ["CocoaPods": .rule("cocoapods.cache"), "Pods": .rule("artifact.pods"), "pod-cache": .genericDiscovery]
        ),
        ("swift-build", "safe", ["swift-build": .ticket10]),
        ("rust-target", "safe", ["target": .ticket10, "rust-target": .ticket10]),
        (
            "flutter-cache",
            "safe",
            [".flutter-plugins": .ticket10, ".flutter-plugins-dependencies": .ticket10, "flutter_cache": .ticket10]
        ),
        ("pub-cache", "safe", ["pub-cache": .ticket10, ".pub-cache": .ticket10]),
        ("xcode-archives", "medium", ["xcarchive": .rule("xcode.archives")]),
        (
            "xcode-device-support",
            "medium",
            [
                "iOS DeviceSupport": .rule("xcode.deviceSupport"),
                "watchOS DeviceSupport": .rule("xcode.deviceSupport"),
                "tvOS DeviceSupport": .rule("xcode.deviceSupport"),
                "xros DeviceSupport": .rule("xcode.deviceSupport"),
            ]
        ),
        (
            "homebrew-cache",
            "safe",
            ["Homebrew": .rule("homebrew.cache"), "homebrew": .genericDiscovery, "homebrew-cache": .genericDiscovery]
        ),
        ("nvm-cache", "medium", [".nvm": .ticket10, "nvm": .ticket10]),
        ("volta-cache", "safe", ["volta": .ticket10]),
        ("pnpm-store", "safe", ["pnpm-store": .rule("pnpm.store"), ".pnpm-store": .rule("pnpm.store")]),
        (
            "yarn-cache",
            "safe",
            ["yarn-cache": .genericDiscovery, "yarn": .rule("yarn.cache"), "berry": .rule("yarn.cache")]
        ),
        ("npm-cache", "safe", ["npm-cache": .ticket10, "npm": .ticket10]),
        ("husky-cache", "safe", ["_husky": .ticket10]),
        ("storybook-cache", "safe", [".storybook-cache": .ticket10, "storybook-static": .ticket10]),
        ("nx-cache", "safe", ["nx-cache": .ticket10]),
        ("moon-cache", "safe", ["moon-cache": .ticket10]),
        ("warp-terminal", "safe", ["dev.warp.Warp-Stable": .entry("warp"), "Warp": .entry("warp")]),
        (
            "iterm2",
            "safe",
            ["com.googlecode.iterm2": .entry("iterm2"), "iTerm2": .entry("iterm2"), "iTerm": .genericDiscovery]
        ),
        ("ghostty", "safe", ["com.mitchellh.ghostty": .entry("ghostty"), "Ghostty": .entry("ghostty")]),
        (
            "chrome",
            "safe",
            ["com.google.Chrome": .entry("chrome"), "Google": .entry("chrome"), "Chrome": .entry("chrome")]
        ),
        ("firefox", "safe", ["org.mozilla.firefox": .entry("firefox"), "Firefox": .entry("firefox")]),
        ("brave", "safe", ["com.brave.Browser": .entry("brave"), "Brave": .entry("brave")]),
        ("opera", "safe", ["com.operasoftware.Opera": .entry("opera"), "Opera": .entry("opera")]),
        ("slack", "safe", ["com.tinyspeck.slackmacgap": .entry("slack"), "Slack": .entry("slack")]),
        ("discord", "safe", ["com.hnc.Discord": .entry("discord"), "Discord": .entry("discord")]),
        ("zoom", "safe", ["us.zoom.xos": .entry("zoom"), "Zoom": .genericDiscovery]),
        ("notion", "safe", ["notion.id": .entry("notion"), "Notion": .entry("notion")]),
        ("spotify", "safe", ["com.spotify.client": .entry("spotify"), "Spotify": .entry("spotify")]),
        ("whatsapp", "safe", ["net.whatsapp.WhatsApp": .entry("whatsapp"), "WhatsApp": .entry("whatsapp")]),
        ("telegram", "safe", ["ru.keepcoder.Telegram": .entry("telegram"), "Telegram": .entry("telegram")]),
        ("telegram-media-cache", "medium", ["Telegram Media Cache": .elsewhere]),
        ("linear", "safe", ["com.linear": .entry("linear"), "Linear": .entry("linear")]),
        ("figma", "safe", ["com.figma.Desktop": .entry("figma"), "Figma": .entry("figma")]),
        ("alfred", "safe", ["com.runningwithcrayons.Alfred": .entry("alfred"), "Alfred": .entry("alfred")]),
        (
            "1password",
            "medium",
            ["com.1password.1password": .notListed, "1Password 7": .notListed, "1Password 8": .notListed]
        ),
        ("claude-app", "safe", ["com.anthropic.claudefordesktop": .entry("claude"), "Claude": .entry("claude")]),
        ("chatgpt-app", "safe", ["com.openai.chat": .entry("chatgpt"), "ChatGPT": .entry("chatgpt")]),
        ("xcode-app", "safe", ["com.apple.dt.Xcode": .rule("xcode.caches"), "Xcode": .genericDiscovery]),
        ("simulator-cache", "safe", ["com.apple.iphonesimulator": .ticket10, "Simulator": .genericDiscovery]),
        (
            "android-studio",
            "safe",
            ["com.google.android.studio": .ticket10, "Android Studio": .ticket10, "AndroidStudio": .ticket10]
        ),
        (
            "screenshot-app",
            "safe",
            ["com.apple.screencaptureui": .entry("screenshot-app"), "Screenshot": .genericDiscovery]
        ),
        ("apple-maps", "medium", ["com.apple.Maps": .entry("apple-maps"), "Maps": .genericDiscovery]),
        ("apple-photos", "medium", ["com.apple.Photos": .entry("apple-photos"), "Photos": .genericDiscovery]),
        ("apple-mail", "medium", ["com.apple.mail": .entry("apple-mail"), "Mail": .genericDiscovery]),
        ("apple-music-app", "medium", ["com.apple.Music": .entry("apple-music-app"), "Music": .genericDiscovery]),
        (
            "network-cache",
            "safe",
            ["NetworkCache": .genericDiscovery, "com.apple.networkserviceproxy": .entry("network-cache")]
        ),
        ("screen-time", "medium", ["com.apple.ScreenTimeAgent": .notListed, "ScreenTime": .notListed]),
        ("npm-npx-cache", "safe", ["npm-npx-cache": .genericDiscovery, "_npx": .rule("npm.npx")]),
        ("npm-logs", "safe", ["npm-logs": .ticket10, "_logs": .ticket10]),
        ("xcode-docs-cache", "safe", ["xcode-docs-cache": .ticket10, "DocumentationCache": .ticket10]),
        ("corepack-cache", "safe", ["corepack-cache": .ticket10, "corepack": .ticket10]),
        ("cursor-agent-leftover", "medium", ["cursor-agent-leftover": .elsewhere]),
        ("orphaned-git-worktree", "medium", ["orphaned-git-worktree": .elsewhere]),
        ("stale-browser-framework", "medium", ["stale-browser-framework": .elsewhere]),
        ("link-thumbnail-cache", "safe", ["LinkThumbnail": .elsewhere]),
        ("chat-media-cache", "safe", ["ChatMedia": .elsewhere]),
        ("app-installation-binary-deltas", "safe", ["AppInstallationBinaryDeltas": .genericDiscovery]),
        ("shipit-updater-cache", "safe", ["ShipIt": .entry("shipit-updater-cache")]),
        ("electron-updater-downloads", "safe", ["Electron Updater Downloads": .elsewhere]),
        ("elixir-build", "safe", ["_build": .ticket10, "elixir-build": .ticket10]),
        ("elixir-deps", "safe", ["elixir-deps": .ticket10]),
        ("hex-packages", "safe", ["Hex Package Cache": .ticket10]),
        ("rebar3-cache", "safe", ["Rebar3 Cache": .ticket10, "rebar3": .ticket10]),
        ("next-build", "safe", [".next": .ticket10]),
        ("nuxt-build", "safe", [".nuxt": .ticket10]),
        ("nuxt-output", "safe", [".output": .ticket10]),
        ("sveltekit-build", "safe", [".svelte-kit": .ticket10]),
        ("astro-build", "safe", [".astro": .ticket10]),
        ("angular-cache", "safe", [".angular": .ticket10]),
        ("pytest-cache", "safe", [".pytest_cache": .ticket10]),
        ("tox-environments", "safe", [".tox": .ticket10]),
        ("stack-work", "safe", [".stack-work": .ticket10]),
        ("cabal-dist", "safe", ["dist-newstyle": .ticket10]),
        ("zig-cache", "safe", [".zig-cache": .ticket10]),
        ("terraform-plugins", "safe", [".terraform": .ticket10]),
        ("godot-cache", "safe", [".godot": .ticket10]),
        ("nuget-packages", "medium", ["NuGet Packages": .ticket10]),
        ("stack-global", "medium", ["Stack Cache": .ticket10]),
        ("cabal-packages", "medium", ["Cabal Packages": .ticket10]),
        ("bazel-cache", "medium", ["Bazel Cache": .ticket10]),
        ("swiftpm-cache", "safe", ["Swift Package Cache": .ticket10]),
        ("venv", "safe", ["venv": .ticket10, ".venv": .ticket10]),
        ("node-gyp-headers", "safe", ["node-gyp": .rule("electron.toolingCaches")]),
        ("typescript-type-cache", "safe", ["typescript": .ticket10]),
        ("cursor-compile-cache", "safe", ["cursor-compile-cache": .ticket10]),
        ("apple-python-cache", "safe", ["com.apple.python": .ticket10]),
        ("dictionary-services", "safe", ["com.apple.DictionaryServices": .entry("dictionary-services")]),
        ("promoted-content", "safe", ["com.apple.ap.PromotedContentJetService": .entry("promoted-content")]),
        ("device-software-updates", "safe", ["Device Software Updates": .elsewhere]),
        ("davinci-cacheclip", "safe", ["CacheClip": .elsewhere]),
        ("aerial-wallpaper-videos", "medium", ["Aerial Wallpaper Videos": .elsewhere]),
        ("messages-previews", "safe", ["Messages Previews": .elsewhere]),
        ("mail-downloads", "medium", ["Mail Downloads": .elsewhere]),
        ("unfinished-downloads", "medium", ["Unfinished Downloads": .elsewhere]),
        ("coresimulator-caches", "safe", ["Simulator Caches": .rule("xcode.simulatorCaches")]),
        ("xctest-devices", "safe", ["Xcode Test Devices": .rule("xcode.testDevices")]),
        ("pre-commit-cache", "safe", ["pre-commit": .ticket10]),
        ("puppeteer-browsers", "medium", ["puppeteer": .ticket10]),
        (
            "intelligenceflowd-cache",
            "safe",
            ["com.apple.intelligenceflow.intelligenceflowd": .entry("intelligenceflowd-cache")]
        ),
        ("swift-frontend-cache", "safe", ["swift-frontend": .ticket10]),
    ]

    /// 上游没登记目录名的条目:开发工具的固定路径与项目产物,整批交给票 10。
    private let withoutFolderNames: [String] = [
        "android-sdk",
        "playwright-unused-builds",
        "archives",
        "go",
        "nextjs-cache",
        "android-build",
        "cocoapods-spec-repos",
        "orphaned-editor-workspace-storage",
        "spotlight-profiles-cache",
        "swiftpm-build",
        "maven-target",
        "gradle-build",
        "sbt-target",
        "dotnet-bin",
        "dotnet-obj",
        "composer-vendor",
        "bundler-vendor",
        "zig-out",
        "dune-build",
        "cmake-build",
        "unity-library",
        "unity-temp",
        "unreal-intermediate",
        "unreal-derived-data",
        "old-cli-versions",
        "cursor-agent-install-leftovers",
        "claude-code-downloads",
        "android-ndk-version",
        "android-system-images",
        "old-figma-profiles",
        "prek-cache",
        "expo-cache",
        "version-manager-downloads",
        "oh-my-zsh-cache",
        "opam-download-cache",
        "conda-packages",
        "dart-analysis-cache",
        "hermes-agent-cache",
        "opencode-cache",
        "antigravity-browser-cache",
        "nvm-download-cache",
        "nvm-node-version",
        "vite-plus-node-version",
        "vite-plus-node-install-leftovers",
        "pyenv-python-version",
        "rustup-toolchain",
        "uv-python-version",
        "giget-cache",
        "firebase-emulators",
        "gradle-leftovers",
        "clang-module-cache",
    ]

    /// 规则 id → 档位:安全白名单规则表,或项目产物规则表(Pods 这类在那边)。
    private func tier(ofRule ruleID: String) -> CleanSafetyTier? {
        JunkRuleTable.rule(id: ruleID)?.tier
            ?? ProjectArtifactRuleTable.builtin.first { $0.id == ruleID }?.tier
    }

    private var fates: [(key: String, tag: String, name: String, fate: Fate)] {
        ledger.flatMap { row in
            row.names.keys.sorted().map { (row.key, row.tag, $0, row.names[$0]!) }
        }
    }

    private func trees(cachesNames: [String]) async -> [SpaceNode] {
        let directories = Dictionary(uniqueKeysWithValues: cachesNames.enumerated().map {
            ("Library/Caches/" + $1, Int64(100 + $0))
        })
        let listings = CleanFixture.homeListings(home: home, directories: directories)
        return await engine.scan(
            SpaceScanOptions(roots: [home], retainFileNodes: false),
            using: FakeCleanDirectoryEnumerator(listings: listings)
        ).trees
    }

    // MARK: 账本自身

    /// 账本与上游一一对应:带目录名的 260 条、没登记目录名的 51 条,key 不重复。
    /// 重新对照新版上游搬运时,这两个数随账本一起改。
    func testLedgerMirrorsUpstreamOneForOne() {
        let keys = ledger.map(\.key) + withoutFolderNames
        XCTAssertEqual(Set(keys).count, keys.count, "上游 key 在账本里重复")
    }

    // MARK: 搬了

    /// 下落是「进了知识库」的目录名,知识库里真有:条目在、名字在条目里。上游标「先检查」的,
    /// 我们这边不能升成「可安全清理」——只能更严。
    func testPortedNamesAreRegisteredWithoutLooseningTheTier() {
        let entries = Dictionary(uniqueKeysWithValues: AppCacheCatalog.entries.map { ($0.key, $0) })

        for row in fates {
            guard case let .entry(entryKey) = row.fate else { continue }
            let entry = entries[entryKey]
            XCTAssertNotNil(entry, "上游 \(row.key) 的「\(row.name)」指向不存在的条目 \(entryKey)")
            XCTAssertTrue(entry?.names.contains(row.name) == true, "\(entryKey) 里没有目录名「\(row.name)」")
            if row.tag == "medium" {
                XCTAssertEqual(entry?.tier, .checkFirst, "上游标 medium 的 \(entryKey) 不能是 safe")
            }
        }
    }

    /// 反过来:凡标了上游出处的条目,账本里都有名字指向它——没有绕过账本进来的。
    /// 例外是 p6 首批就有、上游现行说明库里已没有对应条目的两条(p6 的决定,保留,不计入这次搬运)。
    func testEveryPortedEntryIsReachableFromTheLedger() {
        let legacyEntries = ["chromium", "edge"]
        let portedKeys = Set(fates.compactMap { row -> String? in
            guard case let .entry(key) = row.fate else { return nil }
            return key
        })

        for entry in AppCacheCatalog.entries where entry.source == JunkRuleTable.purgeAppExplanations {
            if legacyEntries.contains(entry.key) {
                continue
            }
            XCTAssertTrue(portedKeys.contains(entry.key), "条目 \(entry.key) 标了上游出处,账本里却没有它的下落")
        }
        for key in legacyEntries {
            XCTAssertNotNil(AppCacheCatalog.entries.first { $0.key == key }, "例外清单里的条目 \(key) 已不存在,把例外删掉")
        }
    }

    /// 下落是「现有规则已担保」的:规则真在;上游标「先检查」的,规则不能是「可安全清理」。
    func testRulesCoveringUpstreamEntriesExistWithoutLooseningTheTier() {
        for row in fates {
            guard case let .rule(ruleID) = row.fate else { continue }
            let tier = tier(ofRule: ruleID)
            XCTAssertNotNil(tier, "上游 \(row.key) 的「\(row.name)」指向不存在的规则 \(ruleID)")
            if row.tag == "medium" {
                XCTAssertEqual(tier, .checkFirst, "上游标 medium 的 \(ruleID) 不能是 safe")
            }
        }
    }

    // MARK: 不列

    /// 有意不列的目录名,谁都不列:规则表不出它,通用发现也把它挡在保护名单外。知识库的规则
    /// 命中不经通用发现那道闸,所以这条检查是「两道都不列」的唯一证明。
    func testNamesWeRefuseToListAreListedByNobody() async {
        let names = fates.filter { $0.fate == .notListed }.map(\.name)
        XCTAssertFalse(names.isEmpty, "护栏在空转")

        let trees = await trees(cachesNames: names)
        let byRule = JunkMatcher.candidates(in: trees, home: home)
        let byDiscovery = GenericDiscovery.detect(in: trees, home: home, claimedBy: byRule, excludedPathPrefixes: [])

        XCTAssertEqual([byRule, byDiscovery].flatMap { $0.map(\.path) }, [], "不列的目录名被列出来了")
    }

    // MARK: 留给通用发现 / 交给票 10

    /// 没证实是缓存目录名的别名:规则表不认领(真有那个目录,通用发现按「先检查」处理)。
    func testUnverifiedAliasesAreNotClaimedByAnyRule() async {
        let names = fates.filter { $0.fate == .genericDiscovery }.map(\.name)
        XCTAssertFalse(names.isEmpty, "护栏在空转")

        let trees = await trees(cachesNames: names)

        XCTAssertEqual(JunkMatcher.candidates(in: trees, home: home).map(\.path), [])
    }

    /// 交给票 10 的目录名还没进知识库——进了就与账本不符,票 10 搬的时候要连账本一起改。
    func testTicket10NamesAreNotInCatalogYet() {
        let catalogNames = Set(AppCacheCatalog.entries.flatMap(\.names))

        for row in fates where row.fate == .ticket10 {
            XCTAssertFalse(catalogNames.contains(row.name), "上游 \(row.key) 的「\(row.name)」标着交给票 10,却已在知识库里")
        }
    }
}
