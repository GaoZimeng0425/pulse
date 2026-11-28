@testable import PulseCore
import XCTest

/// 项目产物规则的搬运账本(p7-cleaner/10):上游 purge-app 的 `ProjectArtifactCatalog`(MIT;提交 ceacaf8)
/// 共 47 行,每行在 Pulse 这边都有下落——由哪条规则担保,上游的每个根标记、每个拒绝条件都在那条
/// 规则里;或者为什么没搬(缘由在票 10 的 Comments)。行由脚本从上游源码生成后粘入。
final class ProjectArtifactPortLedgerTests: XCTestCase {
    private typealias Row = (
        kind: String,
        projectType: String,
        folder: String,
        rootMarkers: [String],
        rootMarkerExtensions: [String],
        refuseWhenPresent: [String],
        level: String,
        rule: String?
    )

    private let ledger: [Row] = [
        ("nodeModules", "node", "node_modules", ["package.json"], [], [], "safe", "artifact.node_modules"),
        ("nextBuild", "node", ".next", ["package.json"], [], [], "safe", "artifact.next-cache"),
        (
            "nuxtBuild",
            "node",
            ".nuxt",
            ["nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.cjs"],
            [],
            [],
            "safe",
            "artifact.nuxt-build"
        ),
        (
            "nuxtOutput",
            "node",
            ".output",
            ["nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.cjs"],
            [],
            [],
            "safe",
            "artifact.nuxt-output"
        ),
        ("svelteKitBuild", "node", ".svelte-kit", ["package.json"], [], [], "safe", "artifact.sveltekit-build"),
        ("astroBuild", "node", ".astro", ["package.json"], [], [], "safe", "artifact.astro-build"),
        ("angularCache", "node", ".angular", ["package.json"], [], [], "safe", "artifact.angular-cache"),
        ("turboCache", "node", ".turbo", ["package.json"], [], [], "safe", "artifact.turbo-cache"),
        ("parcelCache", "node", ".parcel-cache", ["package.json"], [], [], "safe", "artifact.parcel-cache"),
        ("viteCache", "node", "node_modules/.vite", ["package.json"], [], [], "safe", nil),
        ("target", "rust", "target", ["Cargo.toml"], [], [], "safe", "artifact.target"),
        ("venv", "python", "venv", ["requirements.txt", "pyproject.toml"], [], [], "safe", "artifact.venv"),
        ("venv", "python", ".venv", ["requirements.txt", "pyproject.toml"], [], [], "safe", "artifact.dot-venv"),
        (
            "pytestCache",
            "python",
            ".pytest_cache",
            ["requirements.txt", "pyproject.toml"],
            [],
            [],
            "safe",
            "artifact.pytest-cache"
        ),
        (
            "mypyCache",
            "python",
            ".mypy_cache",
            ["requirements.txt", "pyproject.toml"],
            [],
            [],
            "safe",
            "artifact.mypy-cache"
        ),
        (
            "ruffCache",
            "python",
            ".ruff_cache",
            ["requirements.txt", "pyproject.toml"],
            [],
            [],
            "safe",
            "artifact.ruff-cache"
        ),
        ("toxEnvironments", "python", ".tox", ["tox.ini"], [], [], "safe", "artifact.tox"),
        ("dartTool", "flutter", ".dart_tool", ["pubspec.yaml"], [], [], "safe", "artifact.dart-tool"),
        ("flutterBuild", "flutter", "build", ["pubspec.yaml"], [], [], "safe", "artifact.gradle-build"),
        (
            "dotGradle",
            "androidGradle",
            ".gradle",
            ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
            [],
            [],
            "safe",
            "artifact.gradle-project-state"
        ),
        (
            "dotGradle",
            "androidGradle",
            "android/.gradle",
            ["android/build.gradle", "android/build.gradle.kts"],
            [],
            [],
            "safe",
            "artifact.gradle-project-state"
        ),
        ("pods", "xcode", "Pods", ["Podfile"], [], [], "safe", "artifact.pods"),
        ("pods", "xcode", "ios/Pods", ["ios/Podfile"], [], [], "safe", "artifact.pods"),
        ("swiftPMBuild", "swiftPackage", ".build", ["Package.swift"], [], [], "safe", "artifact.swiftpm-build"),
        ("elixirBuild", "elixir", "_build", ["mix.exs"], [], [], "safe", "artifact.mix-build"),
        ("elixirDeps", "elixir", "deps", ["mix.exs"], [], [], "safe", "artifact.elixir-deps"),
        ("mavenTarget", "maven", "target", ["pom.xml"], [], [], "safe", "artifact.target"),
        (
            "gradleBuild",
            "gradleJVM",
            "build",
            ["build.gradle", "build.gradle.kts"],
            [],
            [],
            "safe",
            "artifact.gradle-build"
        ),
        ("sbtTarget", "sbt", "target", ["build.sbt"], [], [], "safe", "artifact.target"),
        ("sbtTarget", "sbt", "project/target", ["build.sbt"], [], [], "safe", "artifact.target"),
        ("dotnetBin", "dotnet", "bin", [], ["csproj", "fsproj", "vbproj", "sln"], [], "safe", "artifact.dotnet-bin"),
        ("dotnetObj", "dotnet", "obj", [], ["csproj", "fsproj", "vbproj", "sln"], [], "safe", "artifact.dotnet-obj"),
        ("composerVendor", "composer", "vendor", ["composer.json"], [], [], "safe", "artifact.composer-vendor"),
        ("bundlerVendor", "bundler", "vendor/bundle", ["Gemfile"], [], [], "safe", nil),
        ("stackWork", "haskellStack", ".stack-work", ["stack.yaml"], [], [], "safe", "artifact.stack-work"),
        ("cabalDist", "haskellCabal", "dist-newstyle", [], ["cabal"], [], "safe", "artifact.cabal-dist"),
        ("zigCache", "zig", ".zig-cache", ["build.zig"], [], [], "safe", "artifact.zig-cache"),
        ("zigCache", "zig", "zig-cache", ["build.zig"], [], [], "safe", "artifact.zig-cache-legacy"),
        ("zigOut", "zig", "zig-out", ["build.zig"], [], [], "safe", "artifact.zig-out"),
        ("duneBuild", "ocamlDune", "_build", ["dune-project"], [], [], "safe", "artifact.mix-build"),
        ("cmakeBuild", "cmake", "build", ["CMakeLists.txt"], [], [], "safe", "artifact.gradle-build"),
        (
            "terraformPlugins",
            "terraform",
            ".terraform",
            [],
            ["tf"],
            ["terraform.tfstate", "terraform.tfstate.backup", "environment"],
            "medium",
            "artifact.terraform-plugins"
        ),
        ("godotCache", "godot", ".godot", ["project.godot"], [], [], "safe", "artifact.godot-cache"),
        (
            "unityLibrary",
            "unity",
            "Library",
            ["ProjectSettings/ProjectVersion.txt"],
            [],
            [],
            "medium",
            "artifact.unity-library"
        ),
        ("unityTemp", "unity", "Temp", ["ProjectSettings/ProjectVersion.txt"], [], [], "medium", "artifact.unity-temp"),
        (
            "unrealIntermediate",
            "unreal",
            "Intermediate",
            [],
            ["uproject"],
            [],
            "medium",
            "artifact.unreal-intermediate"
        ),
        (
            "unrealDerivedData",
            "unreal",
            "DerivedDataCache",
            [],
            ["uproject"],
            [],
            "medium",
            "artifact.unreal-derived-data"
        ),
    ]

    /// 上游有、我们没搬的行 → 缘由。
    private let deferred: [String: String] = [
        "node_modules/.vite": "在 node_modules 里面;匹配器不下潜产物内部,它的字节已算在 node_modules 那一条里",
        "vendor/bundle": "在 vendor 里面;只有旁边有 Gemfile 才算,而 Gemfile 在再上一级,现有标记表达不了",
    ]

    /// 上游的根标记我们用别的、更直接的办法认的行(或有意的更严),不逐个比标记。
    private let differentlyMarked: [String: String] = [
        "venv": "产物里面有 pyvenv.cfg,比旁边的 requirements.txt / pyproject.toml 更直接",
        ".venv": "同上",
        "build": "目录名太通用:不设标记、恒「先检查」(比上游严)",
    ]

    private var rulesByID: [String: ProjectArtifactRule] {
        Dictionary(uniqueKeysWithValues: ProjectArtifactRuleTable.builtin.map { ($0.id, $0) })
    }

    /// 上游一行的根标记,折算成我们「相对产物所在目录」的写法:带子目录的产物(`ios/Pods`)的
    /// 根标记去掉那一级前缀就是同级文件;`project/target` 的根标记在再上一级。
    private func expectedMarkers(_ row: Row) -> Set<String> {
        let parent = row.folder.split(separator: "/").dropLast().map { $0 + "/" }.joined()
        var out = Set<String>()
        for marker in row.rootMarkers {
            if !parent.isEmpty, marker.hasPrefix(parent) {
                out.insert("sibling:" + marker.dropFirst(parent.count))
            } else if !parent.isEmpty {
                out.insert("parentSibling:" + marker)
            } else {
                out.insert("sibling:" + marker)
            }
        }
        for ext in row.rootMarkerExtensions {
            out.insert("siblingExtension:" + ext)
        }
        return out
    }

    private func ourMarkers(_ rule: ProjectArtifactRule) -> Set<String> {
        Set(rule.markers.map { marker -> String in
            switch marker {
            case let .sibling(name): "sibling:" + name
            case let .parentSibling(name): "parentSibling:" + name
            case let .inside(name): "inside:" + name
            case let .siblingExtension(ext): "siblingExtension:" + ext
            }
        })
    }

    // MARK: 账本自身

    func testLedgerCoversEveryUpstreamRow() {
        XCTAssertEqual(ledger.count, 47, "上游项目产物表的行数(提交 ceacaf8)")
        XCTAssertEqual(Set(deferred.keys), Set(ledger.filter { $0.rule == nil }.map(\.folder)), "没搬的行与缘由清单一一对应")
        XCTAssertFalse(deferred.isEmpty, "护栏在空转")
    }

    // MARK: 搬了

    /// 上游每一行都由一条规则担保:规则真在;上游的每个根标记、每个拒绝条件都在它里面;
    /// 上游标「先检查」的,规则不能是「可安全清理」。
    func testPortedRowsAreCoveredMarkerForMarker() {
        let rules = rulesByID
        for row in ledger {
            guard let id = row.rule else { continue }
            guard let rule = rules[id] else {
                XCTFail("上游 \(row.folder)(\(row.projectType))指向不存在的规则 \(id)")
                continue
            }
            if let reason = differentlyMarked[row.folder] {
                XCTAssertTrue(
                    rule.rationale.contains("先检查") || rule.markers
                        .contains {
                            if case .inside = $0 {
                                true
                            } else {
                                false
                            }
                        },
                    "\(row.folder) 记着「用别的办法认」(\(reason)),规则 \(id) 却两者都不是了"
                )
                continue
            }
            let missing = expectedMarkers(row).subtracting(ourMarkers(rule))
            XCTAssertEqual(missing, [], "规则 \(id) 缺上游 \(row.folder) 的根标记")
            for name in row.refuseWhenPresent where !rule.refuseWhenPresent.contains(name) {
                XCTFail("规则 \(id) 缺上游 \(row.folder) 的拒绝条件 \(name)")
            }
            if row.level == "medium" {
                XCTAssertEqual(rule.tier, .checkFirst, "上游标 medium 的 \(id) 不能是 safe")
            }
        }
    }

    /// 反过来:知识库里的每条规则,账本里都有上游的行指向它——没有绕过账本进来的规则。
    func testEveryRuleIsReachableFromTheLedger() {
        let ported = Set(ledger.compactMap(\.rule))
        // Pulse 自定的规则没有上游的行,点名放行。
        let pulseOwn: Set = ["artifact.dist"]
        for rule in ProjectArtifactRuleTable.builtin where !pulseOwn.contains(rule.id) {
            XCTAssertTrue(ported.contains(rule.id), "规则 \(rule.id) 在账本里没有上游的行指向它")
        }
    }
}
