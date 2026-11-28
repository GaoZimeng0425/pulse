@testable import PulseCore
import XCTest

/// 开发工具规则的搬运账本(p7-cleaner/10):上游 purge-app 的 `DevScanner.globalCacheDefinitions()`
/// (MIT;提交 ceacaf8)共 63 条定义,每条在 Pulse 这边都有下落——由哪条规则担保、上游登记的每个
/// 路径都在那条规则的模式里;或者为什么没按固定路径搬(缘由在票 10 的 Comments)。行由脚本从上游
/// 源码生成后粘入(路径逐字取自源码,防手抄错字)。
final class GlobalToolCachePortLedgerTests: XCTestCase {
    /// (上游标签, 上游档位, 担保它的规则 id;nil = 不按固定路径搬, 上游登记的固定路径)
    private let ledger: [(label: String, tag: String, rule: String?, paths: [String])] = [
        ("Xcode Derived Data", "safe", "xcode.derivedData", ["Library/Developer/Xcode/DerivedData"]),
        ("Xcode Archives", "medium", "xcode.archives", ["Library/Developer/Xcode/Archives"]),
        (
            "Xcode Device Support",
            "medium",
            "xcode.deviceSupport",
            [
                "Library/Developer/Xcode/iOS DeviceSupport",
                "Library/Developer/Xcode/watchOS DeviceSupport",
                "Library/Developer/Xcode/tvOS DeviceSupport",
                "Library/Developer/Xcode/visionOS DeviceSupport",
                "Library/Developer/Xcode/xrOS DeviceSupport",
            ]
        ),
        ("Simulator Caches", "safe", "xcode.simulatorCaches", ["Library/Developer/CoreSimulator/Caches"]),
        ("Xcode Test Devices", "safe", "xcode.testDevices", ["Library/Developer/XCTestDevices"]),
        ("Xcode Caches", "safe", "xcode.caches", ["Library/Caches/com.apple.dt.Xcode"]),
        (
            "Xcode Documentation Cache",
            "safe",
            "xcode.documentationCache",
            ["Library/Developer/Xcode/DocumentationCache"]
        ),
        ("CocoaPods", "medium", "cocoapods.specRepos", [".cocoapods/repos"]),
        ("Homebrew Cache", "safe", "homebrew.cache", ["Library/Caches/Homebrew"]),
        ("npm Cache", "safe", "npm.cache", [".npm/_cacache"]),
        ("npm npx Cache", "safe", "npm.npx", [".npm/_npx"]),
        ("npm Logs", "safe", "npm.logs", [".npm/_logs"]),
        ("Corepack Cache", "safe", "corepack.cache", [".cache/node/corepack"]),
        ("pnpm Store", "safe", "pnpm.store", [".pnpm-store", "Library/pnpm/store"]),
        ("Yarn Cache", "safe", "yarn.cache", ["Library/Caches/Yarn", ".yarn/berry/cache"]),
        ("Dart Pub Cache", "safe", "dart.pubCache", [".pub-cache/hosted", ".pub-cache/git"]),
        ("pre-commit Environments", "safe", "precommit.environments", [".cache/pre-commit"]),
        (
            "prek Cache",
            "medium",
            "prek.cache",
            [".cache/prek/repos", ".cache/prek/hooks", ".cache/prek/tools", ".cache/prek/cache"]
        ),
        ("Prisma Engines", "safe", "prisma.cache", [".cache/prisma"]),
        ("uv Package Cache", "medium", "uv.cache", [".cache/uv"]),
        (
            "Expo Cache",
            "safe",
            "expo.cache",
            [
                ".expo/android-apk-cache",
                ".expo/ios-simulator-app-cache",
                ".expo/native-modules-cache",
                ".expo/schema-cache",
                ".expo/template-cache",
                ".expo/versions-cache",
                ".expo/expo-go",
            ]
        ),
        ("pyenv and rbenv Downloads", "safe", "pyenv.rbenvDownloads", [".pyenv/cache", ".rbenv/cache"]),
        ("Oh My Zsh Cache", "safe", "ohmyzsh.cache", [".oh-my-zsh/cache"]),
        ("opam Download Cache", "safe", "opam.downloads", [".opam/download-cache"]),
        ("Puppeteer Browsers", "medium", "puppeteer.browsers", [".cache/puppeteer"]),
        ("Dart Analysis Cache", "safe", "dart.analysisCache", [".dartServer/.analysis-driver"]),
        ("Hermes Agent Cache", "medium", "hermes.agentCache", [".hermes/cache"]),
        ("opencode Cache", "medium", "opencode.cache", [".cache/opencode"]),
        (
            "Conda Package Cache",
            "medium",
            "conda.packageCache",
            [
                ".conda/pkgs",
                "anaconda3/pkgs",
                "miniconda3/pkgs",
                "miniforge3/pkgs",
                "mambaforge/pkgs",
                "opt/anaconda3/pkgs",
                "opt/miniconda3/pkgs",
            ]
        ),
        ("Gradle Cache", "medium", "gradle.caches", [".gradle/caches", ".gradle/wrapper/dists"]),
        ("Gradle Logs and Temp Files", "safe", nil, []),
        ("nvm Download Cache", "safe", "nvm.downloads", [".nvm/.cache"]),
        ("giget Template Cache", "safe", "giget.cache", [".cache/giget"]),
        ("Firebase Emulators", "safe", "firebase.emulators", [".cache/firebase/emulators"]),
        ("Clang Module Cache", "safe", nil, []),
        ("Hex Package Cache", "safe", "hex.packages", [".hex/packages"]),
        ("Rebar3 Cache", "safe", "rebar3.cache", [".cache/rebar3"]),
        ("NuGet Packages", "medium", "nuget.packages", [".nuget/packages"]),
        ("Deno Cache", "safe", "deno.cache", ["Library/Caches/deno"]),
        ("Bun Cache", "safe", "bun.cache", [".bun/install/cache"]),
        ("Cabal Packages", "medium", "cabal.packages", [".cabal/packages"]),
        ("Stack Cache", "medium", "stack.cache", [".stack/pantry", ".stack/snapshots"]),
        ("Bazel Cache", "medium", "bazel.cache", [".cache/bazel"]),
        ("Swift Package Cache", "safe", "swiftpm.cache", ["Library/Caches/org.swift.swiftpm", ".swiftpm/cache"]),
        ("Android Build Cache", "safe", "android.buildCache", [".android/cache", ".android/build-cache"]),
        ("Docker Desktop", "medium", "docker.desktopData", []),
        (
            "VS Code Cache",
            "safe",
            "vscode.cache",
            [
                "Library/Application Support/Code/Cache",
                "Library/Application Support/Code/CachedData",
                "Library/Application Support/Code/CachedExtensionVSIXs",
            ]
        ),
        (
            "Cursor Cache",
            "safe",
            "cursor.cache",
            ["Library/Application Support/Cursor/Cache", "Library/Application Support/Cursor/CachedData"]
        ),
        ("JetBrains Cache", "safe", "jetbrains.caches", []),
        ("Zed Cache", "safe", "zed.caches", ["Library/Caches/Zed"]),
        ("GoModuleCacheScanPolicy.label", "medium", "go.moduleCache", []),
        ("Go Build Cache", "safe", "go.buildCache", ["Library/Caches/go-build", ".cache/go-build"]),
        ("Maven Cache", "medium", "maven.repository", [".m2/repository"]),
        ("SBT Cache", "medium", "sbt.ivyCache", [".ivy2/cache"]),
        ("Ruby Gems", "safe", "rubygems.downloads", [".gem/specs"]),
        ("Bundler Cache", "safe", "bundler.cache", [".bundle/cache"]),
        ("Composer Cache", "safe", "composer.cache", [".composer/cache"]),
        ("Cargo Registry", "safe", "cargo.registry", [".cargo/registry", ".cargo/git"]),
        ("Terraform Cache", "safe", "terraform.pluginCache", [".terraform.d/plugin-cache"]),
        ("GitHub Actions Cache", "safe", "githubActions.cache", [".cache/act"]),
        ("Vagrant Cache", "medium", "vagrant.cache", [".vagrant.d/boxes", ".vagrant.d/tmp"]),
        ("Zsh Cache", "safe", "zsh.sessions", [".zsh_sessions"]),
        (
            "Electron App Caches",
            "safe",
            "appcache.electronApps",
            [
                "Library/Application Support/Slack/Cache",
                "Library/Application Support/Slack/Code Cache",
                "Library/Application Support/discord/Cache",
                "Library/Application Support/discord/Code Cache",
                "Library/Application Support/Notion/Cache",
                "Library/Application Support/Figma/Cache",
            ]
        ),
    ]

    /// 上游登记了、我们有意不按固定路径担保的路径 → 缘由。
    private let notCovered: [String: String] = [
        ".zcompdump": "是文件不是目录;规则只认目录,这个文件很小",
        "Library/Containers/com.docker.docker": "只取它的 Data 子目录(镜像 / 容器 / 卷所在),不动容器根下 Docker 自己的设置文件",
    ]

    /// 我们规则里**不是**上游全局缓存定义里的路径 → 缘由。账本正着查「上游的路径都在规则里」,
    /// 反着查「规则里的路径都在上游、或在这里登记过」——两头都对上,才没有来历不明的路径。
    private let pulseAdded: [String: String] = [
        "Library/Caches/CocoaPods": "p6 自加:说明库 cocoapods-cache 条目登记的目录名(上游的全局缓存定义里是 .cocoapods/repos)",
        "Library/Caches/Code": "说明库 vscode 条目登记的目录名(缓存目录一级)",
        "Library/Caches/Cursor": "说明库 cursor 条目登记的目录名(缓存目录一级)",
        "Library/Caches/Cypress": "说明库 cypress-cache 条目登记的目录名",
        "Library/Caches/JetBrains": "上游 JetBrains 一行的根目录(上游逐个 IDE 子目录列、剔掉 LocalHistory;我们整目录一条)",
        "Library/Caches/bun": "本机实测:新版 Bun 把包缓存放在这里",
        "Library/Caches/com.apple.dt.Xcode.ITunesSoftwareService": "说明库 xcode-itunes-service 条目登记的目录名",
        "Library/Caches/com.apple.iphonesimulator": "说明库 simulator-cache 条目登记的目录名",
        "Library/Caches/com.apple.python": "说明库 apple-python-cache 条目登记的目录名",
        "Library/Caches/com.google.android.studio": "说明库 android-studio 条目登记的目录名",
        "Library/Caches/electron": "p4 自加(说明库 electron 条目):Electron 预编译二进制",
        "Library/Caches/electron-builder": "p4 自加:打包器缓存",
        "Library/Caches/mise": "说明库 mise-cache 条目登记的目录名",
        "Library/Caches/ms-playwright": "说明库 ms-playwright 条目的 key 就是目录名",
        "Library/Caches/ms-playwright-go": "说明库 ms-playwright 条目登记的别名(Go 版)",
        "Library/Caches/node-gyp": "p4 自加(说明库 node-gyp-headers 条目):头文件缓存",
        "Library/Caches/pnpm": "Pulse 自定(p6):pnpm 的注册表元数据缓存,2026-11-09 本机真案",
        "Library/Caches/prisma-nodejs": "说明库 prisma-nodejs 条目登记的目录名",
        "Library/Caches/pulse-swiftpm": "Pulse 自定:本机构建用的 SwiftPM 包缓存",
        "Library/Caches/rtx": "同上(Mise 的旧名)",
        "Library/Caches/typescript": "说明库 typescript-type-cache 条目登记的目录名",
        "Library/Caches/zed": "上游登记的是 Library/Caches/Zed;Zed 实际用小写,两种写法都登记",
        "Library/Containers/com.docker.docker/Data": "上游是整容器目录;我们只取 Data 子目录",
        "Library/Logs": "上游的「应用日志」扫描(说明库 applogs 条目),不在全局缓存定义里",
        "go/pkg/mod": "上游 Go Module Cache 的默认根目录(上游按环境现算,这是默认值)",
    ]

    /// 全字面的家目录相对路径;带后缀分量的模式不算(Xcode 的 `< DeviceSupport>`)。
    private func literalPaths(of rule: JunkRule) -> [String] {
        rule.patterns.compactMap { pattern in
            var parts: [String] = []
            for component in pattern.components {
                guard case let .literal(name) = component else { return nil }
                parts.append(name)
            }
            return parts.joined(separator: "/")
        }
    }

    private func rule(_ id: String) -> JunkRule? {
        JunkRuleTable.rule(id: id)
    }

    /// 规则的模式是否命中这个家目录相对路径(字面逐段相等;后缀分量认末段的后缀)。
    private func covers(_ rule: JunkRule, path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        for pattern in rule.patterns where pattern.components.count == parts.count {
            var hit = true
            for (component, part) in zip(pattern.components, parts) {
                switch component {
                case let .literal(name): hit = hit && name == part
                case let .suffix(suffix): hit = hit && part.hasSuffix(suffix) && part != suffix
                }
            }
            if hit {
                return true
            }
        }
        return false
    }

    // MARK: 账本自身

    func testLedgerCoversEveryUpstreamDefinition() {
        let labels = ledger.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "上游标签在账本里重复")
        XCTAssertEqual(ledger.count, 63, "上游全局缓存定义的条数(提交 ceacaf8)")
        XCTAssertEqual(ledger.filter { $0.rule == nil }.count, 2, "不按固定路径搬的条数")
        XCTAssertEqual(ledger.filter { $0.rule != nil }.flatMap(\.paths).count, 96, "由规则担保的路径数")
        XCTAssertEqual(
            ledger.filter { $0.rule != nil }.flatMap(\.paths).filter { $0 != ".gem/specs" }.count + notCovered.count,
            97,
            "上游固定路径总数 = 由规则担保的 + 有意不担保的"
        )
    }

    // MARK: 搬了

    /// 由规则担保的,规则真在;上游登记的每个路径都在它的模式里;上游标「先检查」的,规则不能是「可安全清理」。
    func testPortedDefinitionsAreCoveredPathForPath() {
        for row in ledger {
            // 没按固定路径搬的行(rule 为 nil)另有缘由(票面),这里只查搬了的
            guard let id = row.rule else { continue }
            guard let rule = rule(id) else {
                XCTFail("上游 \(row.label) 指向不存在的规则 \(id)")
                continue
            }
            XCTAssertTrue(rule.group == .globalToolCache || rule.group == .appCache, id)
            for path in row.paths {
                XCTAssertTrue(covers(rule, path: path), "上游 \(row.label) 的路径 \(path) 不在规则 \(id) 的模式里")
            }
            if row.tag == "medium" {
                XCTAssertEqual(rule.tier, .checkFirst, "上游标 medium 的 \(id) 不能是 safe")
            }
        }
    }

    /// 反查:由账本担保的规则,每个不是上游登记的路径都在 `pulseAdded` 里登记过缘由;登记了的都还在用、
    /// 且确实不是上游登记的——名单不许烂在这里。
    func testEveryPathOfOurOwnIsRegistered() {
        var upstream = Set(ledger.filter { $0.rule != nil }.flatMap(\.paths))
        upstream.formUnion(notCovered.keys)
        // 两张表里的每一条规则都在范围内:账本点名的、说明库里登记的、Pulse 自加的。
        var ours = Set<String>()
        for rule in JunkRuleTable.globalToolCacheRules + JunkRuleTable.appCacheFixedRules {
            ours.formUnion(literalPaths(of: rule))
        }
        for path in ours.sorted() where !upstream.contains(path) {
            XCTAssertNotNil(pulseAdded[path], "规则用到的路径 \(path) 不在上游的登记里,也没在 pulseAdded 里登记缘由")
        }
        XCTAssertEqual(
            Set(pulseAdded.keys).subtracting(ours).sorted(), [],
            "pulseAdded 里有已经没有规则在用的路径,删掉这几行"
        )
        XCTAssertEqual(
            Set(pulseAdded.keys).filter { upstream.contains($0) }.sorted(), [],
            "这几条其实上游登记了,从 pulseAdded 里删掉"
        )
    }

    // MARK: 没搬的

    /// 有意不担保的路径,确实没有任何规则担保——名单不许烂在这里。
    func testDocumentedGapsAreReallyNotCovered() {
        for path in notCovered.keys.sorted() {
            for rule in JunkRuleTable.builtin where covers(rule, path: path) {
                XCTFail("\(path) 记着「不担保」,却被规则 \(rule.id) 担保了——把这一行删掉")
            }
        }
    }
}
