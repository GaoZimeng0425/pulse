@testable import PulseCore
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
        /// 交给后续的票(目前为空:票 10 已落定;以后再有整批交接时可用)。
        case ticket10
        /// 有意不列(缘由在票 09 的 Comments)。
        case notListed
        /// 别名没证实是缓存目录名;真有那个目录,由通用发现以「先检查」列出。
        case genericDiscovery
        /// 不属于任何在办票(或交给别的后续批次),去向记在票 09 / 票 10 的 Comments。
        case elsewhere
    }

    /// 上游 key → (上游档位, 每个目录名的下落)。目录名 = 上游的 aliases 加 bundle_ids。
    private let ledger: [(key: String, tag: String, names: [String: Fate])] = [
        ("adobe-media-cache-files", "safe", ["Adobe Media Cache Files": .entry("adobe-media-cache-files")]),
        ("adobe-media-cache", "safe", ["Adobe Media Cache": .entry("adobe-media-cache")]),
        (
            "adobe-camera-raw",
            "safe",
            ["Adobe Camera Raw": .entry("adobe-camera-raw"), "Adobe Camera Raw 2": .entry("adobe-camera-raw")]
        ),
        (
            "perplexity-updater",
            "safe",
            ["ai.perplexity.CometUpdater": .entry("perplexity-updater"), "CometUpdater": .entry("perplexity-updater")]
        ),
        ("blender", "safe", ["Blender": .entry("blender"), "org.blenderfoundation.blender": .entry("blender")]),
        ("checkpoint-nodejs", "safe", ["checkpoint-nodejs": .elsewhere]),
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
        ("datadog", "safe", ["com.datadoghq": .entry("datadog")]),
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
        ("nt-ware-smartclient", "medium", ["com.nt-ware.SmartClient": .entry("nt-ware-smartclient")]),
        ("openai-codex", "safe", ["com.openai.codex": .entry("openai-codex"), "Codex": .genericDiscovery]),
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
        ("purge-app", "safe", ["io.getpurge.app": .entry("purge-app")]),
        ("sentry", "safe", ["io.sentry": .entry("sentry"), "SentryCrash": .entry("sentry")]),
        ("ms-playwright", "medium", ["ms-playwright-go": .rule("playwright.browsers")]),
        ("node-modules", "safe", ["node_modules": .rule("artifact.node_modules")]),
        ("prisma-nodejs", "safe", ["prisma-nodejs": .rule("prisma.cache")]),
        ("segment", "safe", ["segment": .entry("segment")]),
        ("ssu", "safe", ["ssu": .entry("ssu")]),
        ("macos-installer", "medium", ["macOS Installer": .elsewhere]),
        ("macos-install-data", "medium", ["macOS Install Data": .elsewhere]),
        ("dart-tool", "safe", [".dart_tool": .rule("artifact.dart-tool")]),
        ("ams-migrator", "safe", ["AMSDataMigratorTool": .entry("ams-migrator")]),
        ("spokenly", "safe", ["app.spokenly": .entry("spokenly"), "app.spokenly.revenuecat": .entry("revenuecat")]),
        ("container-managerd", "safe", ["com.apple.containermanagerd": .notListed]),
        ("storekitagent", "medium", ["com.apple.storekitagent": .entry("storekitagent")]),
        ("docker", "medium", ["com.docker.docker": .rule("docker.desktopData")]),
        ("raycast", "safe", ["com.raycast.macos": .entry("raycast")]),
        ("DerivedData", "safe", ["DerivedData": .rule("xcode.derivedData"), "deriveddata": .rule("xcode.derivedData")]),
        ("swiftpm", "safe", ["org.swift.swiftpm": .rule("swiftpm.cache")]),
        ("zen", "safe", ["zen": .entry("zen")]),
        ("yab", "safe", ["Yab": .entry("yab")]),
        (
            "xcode-itunes-service",
            "medium",
            ["com.apple.dt.Xcode.ITunesSoftwareService": .rule("xcode.deviceSoftwareService")]
        ),
        ("gamed", "safe", ["com.apple.gamed": .entry("gamed")]),
        ("chrono", "safe", ["com.apple.chrono": .entry("chrono")]),
        ("translation", "safe", ["com.apple.translationd": .entry("translation")]),
        ("figma-agent", "safe", ["com.figma.agent": .entry("figma")]),
        ("gamekit", "safe", ["GameKit": .entry("gamekit")]),
        ("image-cache", "safe", ["ImageCache": .genericDiscovery]),
        ("revenuecat", "safe", ["RevenueCat": .entry("revenuecat"), "RevenueCatFonts": .entry("revenuecat")]),
        ("gitworktrees", "medium", ["worktrees": .elsewhere]),
        (
            "vscode",
            "safe",
            [
                "Code": .rule("vscode.cache"),
                "CachedData": .rule("vscode.cache"),
                "CachedExtensionVSIXs": .rule("vscode.cache"),
            ]
        ),
        ("cursor", "safe", ["Cursor": .rule("cursor.cache")]),
        ("jetbrains", "safe", ["JetBrains": .rule("jetbrains.caches"), "JetPackCache": .genericDiscovery]),
        ("zed", "safe", ["zed": .rule("zed.caches"), "Zed": .rule("zed.caches")]),
        ("go-build-cache", "safe", ["go-build": .rule("go.buildCache")]),
        ("maven", "medium", ["maven": .rule("maven.repository"), ".m2": .rule("maven.repository")]),
        ("sbt", "medium", ["sbt": .rule("sbt.ivyCache"), ".ivy2": .rule("sbt.ivyCache")]),
        ("rubygems", "safe", ["rubygems": .rule("rubygems.downloads"), ".gem": .rule("rubygems.downloads")]),
        ("bundler", "safe", ["bundler": .rule("bundler.cache"), ".bundle": .rule("bundler.cache")]),
        ("composer", "safe", ["composer": .rule("composer.cache"), ".composer": .rule("composer.cache")]),
        ("cargo", "safe", ["cargo": .rule("cargo.registry"), ".cargo": .rule("cargo.registry")]),
        (
            "terraform",
            "safe",
            ["terraform": .rule("terraform.pluginCache"), ".terraform.d": .rule("terraform.pluginCache")]
        ),
        (
            "githubactions",
            "safe",
            ["act": .rule("githubActions.cache"), "github-actions": .rule("githubActions.cache")]
        ),
        ("vagrant", "medium", ["vagrant": .rule("vagrant.cache"), ".vagrant.d": .rule("vagrant.cache")]),
        (
            "zsh",
            "safe",
            ["zsh_sessions": .rule("zsh.sessions"), ".zsh_sessions": .rule("zsh.sessions"), "zcompdump": .elsewhere]
        ),
        (
            "electron",
            "safe",
            ["electron": .rule("appcache.electronApps"), "Code Cache": .rule("appcache.electronApps")]
        ),
        ("applogs", "safe", ["Logs": .rule("appcache.logs"), "applogs": .genericDiscovery]),
        ("crashreports", "safe", ["DiagnosticReports": .rule("appcache.logs"), "crashreports": .genericDiscovery]),
        ("crashpad-pending", "medium", ["Unsent Crash Reports": .elsewhere]),
        ("iossimulators", "medium", ["CoreSimulator": .elsewhere, "iossimulators": .elsewhere]),
        ("bun-cache", "safe", [".bun": .rule("bun.cache"), "bun-install": .rule("bun.cache")]),
        ("deno-cache", "safe", ["deno": .rule("deno.cache")]),
        (
            "turbo-cache",
            "safe",
            [".turbo": .rule("artifact.turbo-cache"), "turbo-cache": .rule("artifact.turbo-cache")]
        ),
        ("mise-cache", "safe", ["mise": .rule("mise.cache"), "rtx": .rule("mise.cache")]),
        ("vite-cache", "safe", [".vite": .rule("artifact.node_modules"), "vite-cache": .rule("artifact.node_modules")]),
        (
            "parcel-cache",
            "safe",
            [".parcel-cache": .rule("artifact.parcel-cache"), "parcel-cache": .rule("artifact.parcel-cache")]
        ),
        ("eslint-cache", "safe", [".eslintcache": .elsewhere]),
        ("jest-cache", "safe", ["jest-cache": .elsewhere, ".jest-cache": .elsewhere, "jest_cache": .elsewhere]),
        ("vitest-cache", "safe", [".vitest-cache": .elsewhere, "vitest-cache": .elsewhere]),
        (
            "cypress-cache",
            "medium",
            [
                "Cypress": .rule("cypress.binaries"),
                "cypress": .rule("cypress.binaries"),
                "cypress-cache": .rule("cypress.binaries"),
            ]
        ),
        ("python-cache", "safe", ["__pycache__": .elsewhere, ".pyc": .elsewhere, "pycache": .elsewhere]),
        ("uv-cache", "medium", ["uv": .rule("uv.cache"), "uv-cache": .rule("uv.cache"), ".uv": .rule("uv.cache")]),
        (
            "ruff-cache",
            "safe",
            [".ruff_cache": .rule("artifact.ruff-cache"), "ruff-cache": .rule("artifact.ruff-cache")]
        ),
        (
            "mypy-cache",
            "safe",
            [".mypy_cache": .rule("artifact.mypy-cache"), "mypy-cache": .rule("artifact.mypy-cache")]
        ),
        ("kotlin-build", "safe", [".kotlin": .elsewhere, "kotlin-build": .elsewhere]),
        (
            "gradle-cache",
            "safe",
            [".gradle": .rule("artifact.gradle-project-state"), "gradle-cache": .rule("artifact.gradle-project-state")]
        ),
        ("gradle-global-cache", "medium", ["Gradle Dependency Cache": .rule("gradle.caches")]),
        (
            "cocoapods-cache",
            "safe",
            ["CocoaPods": .rule("cocoapods.cache"), "Pods": .rule("artifact.pods"), "pod-cache": .genericDiscovery]
        ),
        ("swift-build", "safe", ["swift-build": .elsewhere]),
        ("rust-target", "safe", ["target": .rule("artifact.target"), "rust-target": .rule("artifact.target")]),
        (
            "flutter-cache",
            "safe",
            [".flutter-plugins": .elsewhere, ".flutter-plugins-dependencies": .elsewhere, "flutter_cache": .elsewhere]
        ),
        ("pub-cache", "safe", ["pub-cache": .rule("dart.pubCache"), ".pub-cache": .rule("dart.pubCache")]),
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
        ("nvm-cache", "medium", [".nvm": .elsewhere, "nvm": .elsewhere]),
        ("volta-cache", "safe", ["volta": .elsewhere]),
        ("pnpm-store", "safe", ["pnpm-store": .rule("pnpm.store"), ".pnpm-store": .rule("pnpm.store")]),
        (
            "yarn-cache",
            "safe",
            ["yarn-cache": .genericDiscovery, "yarn": .rule("yarn.cache"), "berry": .rule("yarn.cache")]
        ),
        ("npm-cache", "safe", ["npm-cache": .rule("npm.cache"), "npm": .rule("npm.cache")]),
        ("husky-cache", "safe", ["_husky": .elsewhere]),
        ("storybook-cache", "safe", [".storybook-cache": .elsewhere, "storybook-static": .elsewhere]),
        ("nx-cache", "safe", ["nx-cache": .elsewhere]),
        ("moon-cache", "safe", ["moon-cache": .elsewhere]),
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
        ("loom", "safe", ["com.loom.desktop": .entry("loom"), "Loom": .genericDiscovery]),
        ("grammarly", "safe", ["com.grammarly.ProjectLlama": .entry("grammarly"), "Grammarly": .entry("grammarly")]),
        ("alfred", "safe", ["com.runningwithcrayons.Alfred": .entry("alfred"), "Alfred": .entry("alfred")]),
        (
            "1password",
            "medium",
            ["com.1password.1password": .notListed, "1Password 7": .notListed, "1Password 8": .notListed]
        ),
        ("dropbox", "medium", ["com.dropbox.DropboxMacFileHelper": .entry("dropbox"), "Dropbox": .entry("dropbox")]),
        (
            "google-drive",
            "medium",
            ["com.google.GoogleDrive": .entry("google-drive"), "Google Drive": .entry("google-drive")]
        ),
        ("onedrive", "medium", ["com.microsoft.OneDrive": .entry("onedrive"), "OneDrive": .entry("onedrive")]),
        (
            "microsoft-teams",
            "safe",
            [
                "com.microsoft.teams2": .entry("microsoft-teams"),
                "Teams": .genericDiscovery,
                "Microsoft Teams": .entry("microsoft-teams"),
            ]
        ),
        (
            "microsoft-word",
            "safe",
            ["com.microsoft.Word": .entry("microsoft-word"), "Microsoft Word": .entry("microsoft-word")]
        ),
        (
            "microsoft-excel",
            "safe",
            ["com.microsoft.Excel": .entry("microsoft-excel"), "Microsoft Excel": .entry("microsoft-excel")]
        ),
        ("granola", "safe", ["com.granola.app": .entry("granola"), "Granola": .genericDiscovery]),
        ("claude-app", "safe", ["com.anthropic.claudefordesktop": .entry("claude"), "Claude": .entry("claude")]),
        ("chatgpt-app", "safe", ["com.openai.chat": .entry("chatgpt"), "ChatGPT": .entry("chatgpt")]),
        ("ollama", "medium", ["com.ollama.Ollama": .entry("ollama"), "Ollama": .genericDiscovery]),
        ("sketch", "safe", ["com.bohemiancoding.sketch3": .entry("sketch"), "Sketch": .genericDiscovery]),
        (
            "affinity-designer",
            "safe",
            [
                "com.seriflabs.affinitydesigner2": .entry("affinity-designer"),
                "Affinity Designer": .entry("affinity-designer"),
            ]
        ),
        (
            "affinity-photo",
            "safe",
            ["com.seriflabs.affinityphoto2": .entry("affinity-photo"), "Affinity Photo": .entry("affinity-photo")]
        ),
        ("xcode-app", "safe", ["com.apple.dt.Xcode": .rule("xcode.caches"), "Xcode": .genericDiscovery]),
        (
            "simulator-cache",
            "safe",
            ["com.apple.iphonesimulator": .rule("simulator.runtimeCache"), "Simulator": .genericDiscovery]
        ),
        (
            "android-studio",
            "safe",
            [
                "com.google.android.studio": .rule("androidStudio.caches"),
                "Android Studio": .rule("androidStudio.caches"),
                "AndroidStudio": .rule("androidStudio.caches"),
            ]
        ),
        ("proxyman", "safe", ["com.proxyman.NSProxy": .entry("proxyman"), "Proxyman": .entry("proxyman")]),
        ("tableplus", "safe", ["com.tinyapp.TablePlus": .entry("tableplus"), "TablePlus": .entry("tableplus")]),
        ("postico", "safe", ["at.eggerapps.Postico": .entry("postico"), "Postico": .entry("postico")]),
        ("insomnia", "safe", ["com.insomnia.app": .entry("insomnia"), "Insomnia": .genericDiscovery]),
        (
            "paw-rapi",
            "safe",
            ["com.luckymarmot.Paw": .entry("paw-rapi"), "Paw": .genericDiscovery, "RapidAPI": .entry("paw-rapi")]
        ),
        ("fork-git", "safe", ["com.DanPristupov.Fork": .entry("fork-git"), "Fork": .genericDiscovery]),
        (
            "sourcetree",
            "safe",
            ["com.torusknot.SourceTreeNotMAS": .entry("sourcetree"), "SourceTree": .entry("sourcetree")]
        ),
        ("tower-git", "safe", ["com.fournova.Tower3": .entry("tower-git"), "Tower": .genericDiscovery]),
        ("screenflow", "safe", ["net.telestream.screenflow": .entry("screenflow"), "ScreenFlow": .entry("screenflow")]),
        ("cleanmymac", "safe", ["com.macpaw.CleanMyMac4": .entry("cleanmymac"), "CleanMyMac": .entry("cleanmymac")]),
        ("lungo", "safe", ["com.sindresorhus.Lungo": .entry("lungo"), "Lungo": .entry("lungo")]),
        ("bartender", "safe", ["com.surteesstudios.Bartender": .entry("bartender"), "Bartender": .entry("bartender")]),
        ("cleanshot", "safe", ["pl.maketheweb.cleanshotx": .entry("cleanshot"), "CleanShot": .entry("cleanshot")]),
        (
            "screenshot-app",
            "safe",
            ["com.apple.screencaptureui": .entry("screenshot-app"), "Screenshot": .genericDiscovery]
        ),
        ("xnapper", "safe", ["com.xnapper.xnapper": .entry("xnapper"), "Xnapper": .entry("xnapper")]),
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
        ("npm-logs", "safe", ["npm-logs": .rule("npm.logs"), "_logs": .rule("npm.logs")]),
        (
            "xcode-docs-cache",
            "safe",
            [
                "xcode-docs-cache": .rule("xcode.documentationCache"),
                "DocumentationCache": .rule("xcode.documentationCache"),
            ]
        ),
        ("corepack-cache", "safe", ["corepack-cache": .rule("corepack.cache"), "corepack": .rule("corepack.cache")]),
        ("cursor-agent-leftover", "medium", ["cursor-agent-leftover": .elsewhere]),
        ("orphaned-git-worktree", "medium", ["orphaned-git-worktree": .elsewhere]),
        ("stale-browser-framework", "medium", ["stale-browser-framework": .elsewhere]),
        ("link-thumbnail-cache", "safe", ["LinkThumbnail": .elsewhere]),
        ("chat-media-cache", "safe", ["ChatMedia": .elsewhere]),
        ("app-installation-binary-deltas", "safe", ["AppInstallationBinaryDeltas": .genericDiscovery]),
        ("shipit-updater-cache", "safe", ["ShipIt": .entry("shipit-updater-cache")]),
        ("electron-updater-downloads", "safe", ["Electron Updater Downloads": .elsewhere]),
        ("elixir-build", "safe", ["_build": .rule("artifact.mix-build"), "elixir-build": .rule("artifact.mix-build")]),
        ("elixir-deps", "safe", ["elixir-deps": .rule("artifact.elixir-deps")]),
        ("hex-packages", "safe", ["Hex Package Cache": .rule("hex.packages")]),
        ("rebar3-cache", "safe", ["Rebar3 Cache": .rule("rebar3.cache"), "rebar3": .rule("rebar3.cache")]),
        ("next-build", "safe", [".next": .rule("artifact.next-cache")]),
        ("nuxt-build", "safe", [".nuxt": .rule("artifact.nuxt-build")]),
        ("nuxt-output", "safe", [".output": .rule("artifact.nuxt-output")]),
        ("sveltekit-build", "safe", [".svelte-kit": .rule("artifact.sveltekit-build")]),
        ("astro-build", "safe", [".astro": .rule("artifact.astro-build")]),
        ("angular-cache", "safe", [".angular": .rule("artifact.angular-cache")]),
        ("pytest-cache", "safe", [".pytest_cache": .rule("artifact.pytest-cache")]),
        ("tox-environments", "safe", [".tox": .rule("artifact.tox")]),
        ("stack-work", "safe", [".stack-work": .rule("artifact.stack-work")]),
        ("cabal-dist", "safe", ["dist-newstyle": .rule("artifact.cabal-dist")]),
        ("zig-cache", "safe", [".zig-cache": .rule("artifact.zig-cache")]),
        ("terraform-plugins", "safe", [".terraform": .rule("artifact.terraform-plugins")]),
        ("godot-cache", "safe", [".godot": .rule("artifact.godot-cache")]),
        ("nuget-packages", "medium", ["NuGet Packages": .rule("nuget.packages")]),
        ("stack-global", "medium", ["Stack Cache": .rule("stack.cache")]),
        ("cabal-packages", "medium", ["Cabal Packages": .rule("cabal.packages")]),
        ("bazel-cache", "medium", ["Bazel Cache": .rule("bazel.cache")]),
        ("swiftpm-cache", "safe", ["Swift Package Cache": .rule("swiftpm.cache")]),
        ("venv", "safe", ["venv": .rule("artifact.venv"), ".venv": .rule("artifact.dot-venv")]),
        ("node-gyp-headers", "safe", ["node-gyp": .rule("electron.toolingCaches")]),
        ("typescript-type-cache", "safe", ["typescript": .rule("typescript.typeCache")]),
        ("cursor-compile-cache", "safe", ["cursor-compile-cache": .elsewhere]),
        ("claude-cli-cache", "safe", ["claude-cli-nodejs": .entry("claude-cli-cache")]),
        ("apple-python-cache", "safe", ["com.apple.python": .rule("apple.pythonCache")]),
        ("jna-libraries", "safe", ["JNA": .entry("jna-libraries")]),
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
        ("pre-commit-cache", "safe", ["pre-commit": .rule("precommit.environments")]),
        ("puppeteer-browsers", "medium", ["puppeteer": .rule("puppeteer.browsers")]),
        (
            "effectcraft",
            "safe",
            ["EffectCraft": .entry("effectcraft"), "ai.storyteller.effectcraft": .entry("effectcraft")]
        ),
        ("codexbar-cache", "safe", ["com.steipete.codexbar": .entry("codexbar-cache")]),
        ("codexbar-usage-history", "medium", ["CodexBar": .entry("codexbar-usage-history")]),
        (
            "intelligenceflowd-cache",
            "safe",
            ["com.apple.intelligenceflow.intelligenceflowd": .entry("intelligenceflowd-cache")]
        ),
        ("swift-frontend-cache", "safe", ["swift-frontend": .elsewhere]),
    ]

    /// 上游没登记目录名的条目:开发工具的固定路径与项目产物。每条带上游档位与下落(票 10 落定)。
    private let withoutFolderNames: [(key: String, tag: String, fate: Fate)] = [
        ("android-sdk", "safe", .rule("android.buildCache")),
        ("playwright-unused-builds", "medium", .rule("playwright.browsers")),
        ("archives", "medium", .elsewhere),
        ("go", "medium", .rule("go.moduleCache")),
        ("nextjs-cache", "safe", .rule("artifact.next-cache")),
        ("android-build", "safe", .rule("artifact.gradle-build")),
        ("cocoapods-spec-repos", "medium", .rule("cocoapods.specRepos")),
        ("orphaned-editor-workspace-storage", "medium", .elsewhere),
        ("spotlight-profiles-cache", "medium", .elsewhere),
        ("swiftpm-build", "safe", .rule("artifact.swiftpm-build")),
        ("maven-target", "safe", .rule("artifact.target")),
        ("gradle-build", "safe", .rule("artifact.gradle-build")),
        ("sbt-target", "safe", .rule("artifact.target")),
        ("dotnet-bin", "safe", .rule("artifact.dotnet-bin")),
        ("dotnet-obj", "safe", .rule("artifact.dotnet-obj")),
        ("composer-vendor", "safe", .rule("artifact.composer-vendor")),
        ("bundler-vendor", "safe", .elsewhere),
        ("zig-out", "safe", .rule("artifact.zig-out")),
        ("dune-build", "safe", .rule("artifact.mix-build")),
        ("cmake-build", "safe", .rule("artifact.gradle-build")),
        ("unity-library", "medium", .rule("artifact.unity-library")),
        ("unity-temp", "medium", .rule("artifact.unity-temp")),
        ("unreal-intermediate", "medium", .rule("artifact.unreal-intermediate")),
        ("unreal-derived-data", "medium", .rule("artifact.unreal-derived-data")),
        ("old-cli-versions", "safe", .elsewhere),
        ("cursor-agent-install-leftovers", "medium", .elsewhere),
        ("claude-code-downloads", "medium", .elsewhere),
        ("android-ndk-version", "medium", .elsewhere),
        ("android-system-images", "medium", .elsewhere),
        ("old-figma-profiles", "medium", .elsewhere),
        ("prek-cache", "medium", .rule("prek.cache")),
        ("expo-cache", "safe", .rule("expo.cache")),
        ("version-manager-downloads", "safe", .rule("pyenv.rbenvDownloads")),
        ("oh-my-zsh-cache", "safe", .rule("ohmyzsh.cache")),
        ("opam-download-cache", "safe", .rule("opam.downloads")),
        ("conda-packages", "medium", .rule("conda.packageCache")),
        ("dart-analysis-cache", "safe", .rule("dart.analysisCache")),
        ("hermes-agent-cache", "medium", .rule("hermes.agentCache")),
        ("opencode-cache", "medium", .rule("opencode.cache")),
        ("antigravity-browser-cache", "safe", .elsewhere),
        ("nvm-download-cache", "safe", .rule("nvm.downloads")),
        ("nvm-node-version", "medium", .elsewhere),
        ("vite-plus-node-version", "medium", .elsewhere),
        ("vite-plus-node-install-leftovers", "medium", .elsewhere),
        ("pyenv-python-version", "medium", .elsewhere),
        ("rustup-toolchain", "medium", .elsewhere),
        ("uv-python-version", "medium", .elsewhere),
        ("giget-cache", "safe", .rule("giget.cache")),
        ("firebase-emulators", "safe", .rule("firebase.emulators")),
        ("gradle-leftovers", "safe", .elsewhere),
        ("clang-module-cache", "safe", .elsewhere),
    ]

    /// p6 首批就登记、上游现行说明库(提交 ceacaf8)里没有的目录名:p6 的决定,保留。它们没有上游
    /// 条目可对账,所以在这里点名。新加的目录名要么有账本下落,要么在这里登记——不然「往现有
    /// 条目里塞一个目录名」就绕过了账本。
    private let legacyNames: Set<String> = [
        "Arc", "company.thebrowser.browser",
        "Zen",
        "Safari",
        "zoom.us",
        "Raycast",
        "Microsoft AutoUpdate",
        "com.google.Keystone",
        // Pulse 本机实测补的版本号(上游只登记到 CleanMyMac4)
        "com.macpaw.CleanMyMac5",
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

    // MARK: 账本自身

    /// 账本覆盖上游的每一条:带目录名的 260 条、没登记目录名的 51 条,key 不重复。
    /// 另外钉住账本的形状——上游档位 197 条 safe / 63 条 medium、目录名共 404 个。档位是从上游
    /// 抄进账本的,抄错了下面「不放宽」的检查就跟着错;这几个数是从上游原件另算的,抄错一条
    /// 就对不上。重新对照新版上游搬运时,这些数随账本一起改。
    func testLedgerCoversEveryUpstreamEntry() {
        let keys = ledger.map(\.key) + withoutFolderNames.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "上游 key 在账本里重复")

        XCTAssertEqual(ledger.count, 260, "上游带目录名的条目数(提交 ceacaf8)")
        XCTAssertEqual(withoutFolderNames.count, 51, "上游没登记目录名的条目数(提交 ceacaf8)")
        XCTAssertEqual(ledger.filter { $0.tag == "safe" }.count, 197, "上游带目录名、标 safe 的条目数")
        XCTAssertEqual(ledger.filter { $0.tag == "medium" }.count, 63, "上游带目录名、标 medium 的条目数")
        XCTAssertEqual(fates.count, 404, "上游目录名总数(aliases 加 bundle_ids)")
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

    /// 反过来:凡标了上游出处的条目,它的每个目录名在账本里都有下落——没有绕过账本进来的名字
    /// (只查条目 key 的话,往现有条目里加一个目录名就绕过去了)。例外只在 `legacyNames` 里点名。
    func testEveryPortedDirectoryNameIsReachableFromTheLedger() {
        var ported: Set<[String]> = [] // [条目 key, 目录名]
        for row in fates {
            guard case let .entry(entryKey) = row.fate else { continue }
            ported.insert([entryKey, row.name])
        }
        let catalogNames = Set(AppCacheCatalog.entries.flatMap(\.names))

        for entry in AppCacheCatalog.entries where entry.source == JunkRuleTable.purgeAppExplanations {
            for name in entry.names {
                XCTAssertTrue(
                    ported.contains([entry.key, name]) || legacyNames.contains(name),
                    "\(entry.key) 的目录名「\(name)」标了上游出处,账本里却没有它的下落"
                )
            }
        }
        for name in legacyNames.sorted() {
            XCTAssertTrue(catalogNames.contains(name), "点名保留的目录名「\(name)」已不在知识库里,把这一行删掉")
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

    /// 没登记目录名的那些条目,下落同样要成立:是规则的,规则真在;上游标「先检查」的,规则不能是「可安全清理」。
    func testEntriesWithoutFolderNamesAreAccountedFor() {
        for entry in withoutFolderNames {
            guard case let .rule(ruleID) = entry.fate else { continue }
            let tier = tier(ofRule: ruleID)
            XCTAssertNotNil(tier, "上游 \(entry.key) 指向不存在的规则 \(ruleID)")
            if entry.tag == "medium" {
                XCTAssertEqual(tier, .checkFirst, "上游标 medium 的 \(ruleID) 不能是 safe")
            }
        }
        XCTAssertTrue(withoutFolderNames.contains { $0.fate == .elsewhere }, "护栏在空转")
    }

    // MARK: 不列

    /// 有意不列的目录名,谁都不列:规则表不出它,通用发现也把它挡在保护名单外。知识库的规则
    /// 命中不经通用发现那道闸,所以这条检查是「两道都不列」的唯一证明。
    func testNamesWeRefuseToListAreListedByNobody() async {
        let names = fates.filter { $0.fate == .notListed }.map(\.name)
        XCTAssertFalse(names.isEmpty, "护栏在空转")

        let trees = await JunkCacheScanFixture.trees(cachesNames: names)
        let byRule = JunkMatcher.candidates(in: trees, home: JunkCacheScanFixture.home)
        let byDiscovery = GenericDiscovery.detect(
            in: trees,
            home: JunkCacheScanFixture.home,
            claimedBy: byRule,
            excludedPathPrefixes: []
        )

        XCTAssertEqual([byRule, byDiscovery].flatMap { $0.map(\.path) }, [], "不列的目录名被列出来了")
    }

    // MARK: 留给通用发现 / 交给票 10

    /// 没证实是缓存目录名的别名:规则表不认领(真有那个目录,通用发现按「先检查」处理)。
    func testUnverifiedAliasesAreNotClaimedByAnyRule() async {
        let names = fates.filter { $0.fate == .genericDiscovery }.map(\.name)
        XCTAssertFalse(names.isEmpty, "护栏在空转")

        let candidates = await JunkCacheScanFixture.candidates(cachesNames: names)

        XCTAssertEqual(candidates.map(\.path), [])
    }

    /// 交给票 10 的目录名还没进知识库——进了就与账本不符,票 10 搬的时候要连账本一起改。
    func testTicket10NamesAreNotInCatalogYet() {
        let catalogNames = Set(AppCacheCatalog.entries.flatMap(\.names))

        for row in fates where row.fate == .ticket10 {
            XCTAssertFalse(catalogNames.contains(row.name), "上游 \(row.key) 的「\(row.name)」标着交给票 10,却已在知识库里")
        }
    }
}
