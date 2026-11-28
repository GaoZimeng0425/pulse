@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 项目产物 + 在用保护(p4-cleaner/05)。登记完整性(ADR-0008 的安全边界本体:
/// 每条内置规则必须被至少一个正例命中)、按项目分组、嵌套产物不重复列、
/// 年龄口径(重装依赖不刷新年龄;git 活动计入)、活动推导三路 + 在用判定方向。
/// p7-cleaner/10 起再加:根标记的三种写法(同级 / 上一级 / 按扩展名)、拒绝条件、
/// 重建说明随说明带给用户;规则与上游的逐行对应在 `ProjectArtifactPortLedgerTests`。
final class ProjectArtifactTests: XCTestCase {
    // MARK: 夹具(手搭显示前的扫描树;newestChangeEpoch = 该目录直属文件口径)

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

    /// 两个项目:old-app(node_modules 800 + target 300,源码 40 天前动过)、
    /// new-tool(node_modules 100,刚动过)。扫描根 = /Users/dev/code。
    private func tree() -> SpaceNode {
        let oldApp = dir("old-app", under: "/Users/dev/code", newest: 40 * 86400 * -1 + 1_700_000_000, children: [
            dir("node_modules", under: "/Users/dev/code/old-app", bytes: 800, newest: 1_700_100_000),
            dir("target", under: "/Users/dev/code/old-app", bytes: 300, newest: 1_700_050_000),
            dir("src", under: "/Users/dev/code/old-app", newest: 1_700_000_000 - 40 * 86400),
        ])
        let newTool = dir("new-tool", under: "/Users/dev/code", newest: 1_700_200_000, children: [
            dir("node_modules", under: "/Users/dev/code/new-tool", bytes: 100, newest: 1_700_200_000),
        ])
        return dir("code", under: "/Users/dev", children: [oldApp, newTool])
    }

    /// 匹配入口:`files` = 盘上存在的标记文件全集;nil = 一律视作存在(只测非标记口径的用例)。
    /// `extensions` = 各目录里文件的扩展名集合(按扩展名认的根标记用);默认空 = 这种标记不成立。
    private func match(
        in trees: [SpaceNode],
        roots: [String],
        excludedPathPrefixes: [String] = [],
        files: Set<String>? = nil,
        extensions: (String) -> Set<String> = { _ in [] }
    ) -> [JunkCandidate] {
        ProjectArtifactMatcher.artifacts(
            in: trees,
            roots: roots,
            excludedPathPrefixes: excludedPathPrefixes,
            fileExists: { path in files.map { $0.contains(path) } ?? true },
            fileExtensions: extensions
        )
    }

    /// 一条规则的根标记全都成立所需的盘上事实:标记文件的路径集合,与各目录的扩展名集合。
    /// 拒绝条件里的文件不算在内(它们成立的话产物就不该列)。
    private func markerFacts(
        for rule: ProjectArtifactRule,
        artifactPath: String,
        parentOfParent: String
    ) -> (files: Set<String>, extensions: Set<String>) {
        var files = Set<String>()
        var extensions = Set<String>()
        for marker in rule.markers {
            switch marker {
            case let .sibling(name): files
                .insert(((artifactPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name))
            case let .parentSibling(name): files.insert((parentOfParent as NSString).appendingPathComponent(name))
            case let .inside(name): files.insert((artifactPath as NSString).appendingPathComponent(name))
            case let .siblingExtension(ext): extensions.insert(ext)
            }
        }
        return (files, extensions)
    }

    // MARK: 项目标记(cleaner-hardening/02):安全档产物必须有对应项目文件佐证

    func testSafeArtifactWithoutMarkerIsNotListed() {
        // ~/Documents/市场/target:普通文件夹碰巧叫 target,旁边没有 Cargo.toml。
        let project = dir("市场", under: "/u/Documents", children: [
            dir("target", under: "/u/Documents/市场", bytes: 900),
            dir("node_modules", under: "/u/Documents/市场", bytes: 900),
            dir("venv", under: "/u/Documents/市场", bytes: 900),
        ])
        let root = dir("Documents", under: "/u", children: [project])
        XCTAssertTrue(match(in: [root], roots: ["/u/Documents"], files: []).isEmpty)
    }

    func testSafeArtifactWithMarkerIsListed() {
        let project = dir("app", under: "/dev", children: [
            dir("target", under: "/dev/app", bytes: 10),
            dir("node_modules", under: "/dev/app", bytes: 10),
            dir(".venv", under: "/dev/app", bytes: 10),
            dir(".build", under: "/dev/app", bytes: 10),
        ])
        let root = dir("dev", under: "/", children: [project])
        let out = match(in: [root], roots: ["/dev"], files: [
            "/dev/app/Cargo.toml", "/dev/app/package.json", "/dev/app/.venv/pyvenv.cfg", "/dev/app/Package.swift",
        ])
        XCTAssertEqual(Set(out.map(\.path)), [
            "/dev/app/target", "/dev/app/node_modules", "/dev/app/.venv", "/dev/app/.build",
        ])
    }

    func testEverySafeRuleRequiresAMarker() {
        for rule in ProjectArtifactRuleTable.builtin where rule.tier == .safe {
            XCTAssertFalse(rule.markers.isEmpty, "安全档规则 \(rule.id) 必须声明项目标记")
        }
    }

    // MARK: 登记完整性(新增规则不写正例过不了这里)

    func testEveryBuiltinRuleHasAPositiveExample() {
        // 一个项目下铺齐全部规则目录名,并按每条规则的根标记铺好盘上事实(拒绝条件里的文件不铺);
        // 每条内置规则必须命中一次,且恰好一次(一条目录名只许有一条规则)。
        let rules = ProjectArtifactRuleTable.builtin
        var files = Set<String>()
        var extensions = Set<String>()
        for rule in rules {
            let facts = markerFacts(for: rule, artifactPath: "/dev/proj/" + rule.directoryName, parentOfParent: "/dev")
            files.formUnion(facts.files)
            extensions.formUnion(facts.extensions)
        }
        let project = dir(
            "proj",
            under: "/dev",
            children: rules.map { dir($0.directoryName, under: "/dev/proj", bytes: 10) }
        )
        let root = dir("dev", under: "/", children: [project])

        let out = match(in: [root], roots: ["/dev"], files: files, extensions: { _ in extensions })
        let counts = Dictionary(grouping: out, by: \.ruleID).mapValues(\.count)
        for rule in rules {
            XCTAssertEqual(counts[rule.id], 1, "规则 \(rule.id) 应当恰好命中一次——补 fixture、删规则,或处理撞名的规则")
        }
    }

    // MARK: p7-cleaner/10:根标记的三种写法、拒绝条件、重建说明

    /// 每条规则都带齐:说明、重建说明、出处;给用户看的说明里带着重建办法。
    func testEveryRuleCarriesRationaleReinstallAndSource() {
        for rule in ProjectArtifactRuleTable.builtin {
            XCTAssertFalse(rule.rationale.isEmpty, rule.id)
            XCTAssertFalse(rule.reinstall.isEmpty, "\(rule.id):重建说明非空")
            XCTAssertTrue(
                rule.source.contains("MIT") || rule.source.hasPrefix("Pulse 自定"),
                "\(rule.id):出处要么标 MIT 来源,要么标 Pulse 自定,现在是「\(rule.source)」"
            )
            XCTAssertTrue(rule.displayedRationale.contains(rule.reinstall), "\(rule.id):给用户看的说明要带上重建办法")
        }
    }

    /// 候选带出去的说明就是「说明 + 重建办法」(确认清单与行悬浮用的那一段)。
    func testCandidateCarriesRationaleWithReinstall() {
        let project = dir("proj", under: "/dev", children: [
            dir("node_modules", under: "/dev/proj", bytes: 10),
        ])
        let root = dir("dev", under: "/", children: [project])
        let out = match(in: [root], roots: ["/dev"], files: ["/dev/proj/package.json"])
        let rule = ProjectArtifactRuleTable.builtin.first { $0.id == "artifact.node_modules" }
        XCTAssertEqual(out.first?.rationale, rule?.displayedRationale)
        XCTAssertTrue(out.first?.rationale.contains("npm install") == true)
    }

    /// 按扩展名认的根标记:没有固定文件名的工程文件(`bin` 旁边的 `.csproj` / `.sln`、`dist-newstyle`
    /// 旁边的 `.cabal`)。没有工程文件的 `bin` 不列;不传目录清单时(默认空集)这种标记永不成立。
    /// 目录清单按约定给的是小写扩展名(生产端 `CleanerModel.fileExtensions` 负责转小写)。
    func testExtensionMarkersNeedProjectFilesWithThatExtension() {
        let project = dir("proj", under: "/dev", children: [
            dir("bin", under: "/dev/proj", bytes: 10),
            dir("obj", under: "/dev/proj", bytes: 10),
            dir("dist-newstyle", under: "/dev/proj", bytes: 10),
        ])
        let root = dir("dev", under: "/", children: [project])

        XCTAssertTrue(match(in: [root], roots: ["/dev"]).isEmpty, "不传目录清单:按扩展名认的标记不成立")
        XCTAssertTrue(match(in: [root], roots: ["/dev"], extensions: { _ in ["txt"] }).isEmpty, "扩展名对不上")
        let out = match(in: [root], roots: ["/dev"], extensions: { $0 == "/dev/proj" ? ["sln", "cabal"] : [] })
        XCTAssertEqual(
            Set(out.map(\.path)),
            ["/dev/proj/bin", "/dev/proj/obj", "/dev/proj/dist-newstyle"],
            "按扩展名认的工程文件"
        )
        XCTAssertEqual(out.first { $0.path == "/dev/proj/bin" }?.tier, .safe)
        XCTAssertEqual(out.first { $0.path == "/dev/proj/dist-newstyle" }?.tier, .checkFirst, "重建可能很久,先检查")
        // 工程文件在别的目录里不算:清单是按产物所在的目录取的。
        XCTAssertTrue(match(in: [root], roots: ["/dev"], extensions: { $0 == "/dev" ? ["sln"] : [] }).isEmpty)
    }

    /// 带子目录的产物,根标记按上游「相对项目根」的写法折算到产物所在的目录:`android/.gradle` 的
    /// 工程文件 `android/build.gradle` 就在它旁边(同级文件),上一级的 `build.gradle` 不算;
    /// sbt 的元构建 `project/target` 的工程文件 `build.sbt` 在项目根,也就是再上一级。
    func testNestedArtifactsLookForProjectFilesRelativeToTheirOwnFolder() {
        let project = dir("proj", under: "/dev", children: [
            dir("android", under: "/dev/proj", children: [
                dir(".gradle", under: "/dev/proj/android", bytes: 10),
            ]),
            dir("project", under: "/dev/proj", children: [
                dir("target", under: "/dev/proj/project", bytes: 10),
            ]),
        ])
        let root = dir("dev", under: "/", children: [project])

        XCTAssertTrue(
            match(in: [root], roots: ["/dev"], files: ["/dev/proj/android/build.gradle.bak"]).isEmpty,
            "名字差一点的工程文件不算"
        )
        // 只有项目根的 build.gradle(上一级):android/.gradle 不算——上游登记的是 android/build.gradle。
        let onlyRoot = match(in: [root], roots: ["/dev"], files: ["/dev/proj/build.gradle"])
        XCTAssertTrue(onlyRoot.isEmpty, "上一级的 build.gradle 不认 android/.gradle")
        // 工程文件在 android/ 里、build.sbt 在项目根:两个产物都认。
        let out = match(in: [root], roots: ["/dev"], files: ["/dev/proj/android/build.gradle", "/dev/proj/build.sbt"])
        XCTAssertEqual(Set(out.map(\.path)), ["/dev/proj/android/.gradle", "/dev/proj/project/target"])
    }

    /// 「在场才列」:规则登记了、盘上没有那个目录,就不产出候选——38 条规则一个都不凭空出现。
    func testRulesWithoutALocationOnDiskProduceNothing() {
        let empty = dir("empty-project", under: "/dev", children: [dir("src", under: "/dev/empty-project", bytes: 10)])
        let root = dir("dev", under: "/", children: [empty])
        XCTAssertTrue(match(in: [root], roots: ["/dev"]).isEmpty)
        // 标记探测一律说「有」也一样:树里没有目录名对得上的节点,就没有候选。
        XCTAssertTrue(match(
            in: [root],
            roots: ["/dev"],
            files: nil,
            extensions: { _ in ["sln", "tf", "uproject", "cabal"] }
        ).isEmpty)
    }

    /// 重建要花真实时间的(重新下载依赖、重新编译很久),即使上游标 safe 也落「先检查」(票面范围 1)。
    func testSlowRebuildsStayCheckFirst() {
        let rules = Dictionary(uniqueKeysWithValues: ProjectArtifactRuleTable.builtin.map { ($0.id, $0) })
        for id in [
            "artifact.tox",
            "artifact.stack-work",
            "artifact.cabal-dist",
            "artifact.unity-library",
            "artifact.unity-temp",
            "artifact.unreal-intermediate",
            "artifact.unreal-derived-data",
            "artifact.terraform-plugins",
        ] {
            XCTAssertEqual(rules[id]?.tier, .checkFirst, id)
            XCTAssertTrue(rules[id]?.reinstall.isEmpty == false, id)
        }
    }

    /// 拒绝条件:`.terraform` 里只要有状态文件就整个不列——丢了状态等于丢了对真实运行中基础设施的跟踪。
    func testRefuseWhenPresentKeepsStatefulArtifactOut() {
        let project = dir("proj", under: "/dev", children: [
            dir(".terraform", under: "/dev/proj", bytes: 10),
        ])
        let root = dir("dev", under: "/", children: [project])
        let beside: (String) -> Set<String> = { $0 == "/dev/proj" ? ["tf"] : [] }

        for stateFile in ["terraform.tfstate", "terraform.tfstate.backup", "environment"] {
            let out = match(
                in: [root],
                roots: ["/dev"],
                files: ["/dev/proj/.terraform/" + stateFile],
                extensions: beside
            )
            XCTAssertTrue(out.isEmpty, "有 \(stateFile) 的 .terraform 不该列,实际:\(out.map(\.path))")
        }
        let out = match(in: [root], roots: ["/dev"], files: ["/dev/proj/.terraform/modules.json"], extensions: beside)
        XCTAssertEqual(out.map(\.path), ["/dev/proj/.terraform"], "没有状态文件的照列")
        XCTAssertEqual(out.first?.tier, .checkFirst, "上游标 medium")
    }

    /// 目录名太通用的两条(build / dist)不设标记、恒「先检查」;同名的几种工程合成一条时标记取并集。
    func testGenericNamesStayCheckFirstAndMergedKindsShareAMarker() throws {
        let rules = Dictionary(uniqueKeysWithValues: ProjectArtifactRuleTable.builtin.map { ($0.id, $0) })
        for id in ["artifact.gradle-build", "artifact.dist"] {
            XCTAssertEqual(rules[id]?.tier, .checkFirst, id)
            XCTAssertEqual(rules[id]?.markers.isEmpty, true, "\(id):目录名太通用,不设标记(设了就等于凭名字认)")
        }
        let target = try XCTUnwrap(rules["artifact.target"])
        let siblingNames = target.markers.compactMap { marker -> String? in
            if case let .sibling(name) = marker {
                return name
            }
            return nil
        }
        XCTAssertEqual(
            Set(siblingNames),
            ["Cargo.toml", "pom.xml", "build.sbt"],
            "Rust / Maven / sbt 同用 target,三种工程文件都认"
        )
        XCTAssertEqual(target.tier, .safe)
    }

    // MARK: 分组与排序

    func testGroupsByProjectAndSortsBySize() {
        let out = match(in: [tree()], roots: ["/Users/dev/code"])
        XCTAssertEqual(out.map(\.projectName), [
            "/Users/dev/code/old-app", "/Users/dev/code/old-app", "/Users/dev/code/new-tool",
        ], "按产物父目录完整路径归组(cleaner-junk-card-fixes/02)")
        XCTAssertEqual(out.first?.path, "/Users/dev/code/old-app/node_modules", "组内大到小")
        XCTAssertEqual(out.first?.group, .projectArtifacts)
        XCTAssertTrue(out.allSatisfy { $0.tier == .safe }, "node_modules / target 都是无歧义产物")
    }

    func testSameNamedDirsInDifferentReposDoNotShareGroup() {
        // cleaner-junk-card-fixes/02 实报:两个仓库各自的 desktop 子目录,末段同名
        // 却是不同文件夹——完整路径键必须分属两组(旧键 node.name 会并成一张卡)。
        // 同一路径的多个产物同卡由 testGroupsByProjectAndSortsBySize 钉住。
        let repoA = dir("SwarmAgents", under: "/dev", children: [
            dir("apps", under: "/dev/SwarmAgents", children: [
                dir("desktop", under: "/dev/SwarmAgents/apps", children: [
                    dir("build", under: "/dev/SwarmAgents/apps/desktop", bytes: 30),
                ]),
            ]),
        ])
        let repoB = dir("ZCode", under: "/dev", children: [
            dir("packages", under: "/dev/ZCode", children: [
                dir("desktop", under: "/dev/ZCode/packages", children: [
                    dir("build", under: "/dev/ZCode/packages/desktop", bytes: 20),
                ]),
            ]),
        ])
        let root = dir("dev", under: "/", children: [repoA, repoB])

        let out = match(in: [root], roots: ["/dev"])
        XCTAssertEqual(Set(out.map(\.projectName)), [
            "/dev/SwarmAgents/apps/desktop", "/dev/ZCode/packages/desktop",
        ], "同名异路不并卡")
    }

    func testNestedArtifactsNotDoubleListed() {
        // monorepo:packages/a 下还有 node_modules——外层 node_modules 的字节已含它,不重复列。
        let pkg = dir("a", under: "/dev/proj/packages", children: [
            dir("node_modules", under: "/dev/proj/packages/a", bytes: 50),
        ])
        let project = dir("proj", under: "/dev", children: [
            dir(
                "node_modules",
                under: "/dev/proj",
                bytes: 500,
                children: [dir("packages", under: "/dev/proj", children: [pkg])]
            ),
        ])
        let root = dir("dev", under: "/", children: [project])

        let out = match(in: [root], roots: ["/dev"])
        XCTAssertEqual(out.map(\.path), ["/dev/proj/node_modules"], "嵌套产物不单独成行")
        XCTAssertEqual(out.first?.bytes, 500)
    }

    func testScanRootItselfIsAProjectForDirectArtifactsOnly() {
        // 根自己有 node_modules(根即项目);子项目的产物不因「根也是项目」被吞两遍。
        let project = dir("child", under: "/dev", children: [
            dir("target", under: "/dev/child", bytes: 20),
        ])
        let root = dir("dev", under: "/", children: [
            dir("node_modules", under: "/dev", bytes: 70),
            project,
        ])
        let out = match(in: [root], roots: ["/dev"])
        XCTAssertEqual(Set(out.map(\.path)), ["/dev/node_modules", "/dev/child/target"])
        XCTAssertEqual(out.first { $0.path == "/dev/node_modules" }?.projectName, "/dev")
    }

    func testRootMissingFromTreeIsSkippedAndFullVolumeRootRefused() {
        XCTAssertTrue(match(in: [tree()], roots: ["/nope"]).isEmpty)
        XCTAssertTrue(match(in: [tree()], roots: ["/"]).isEmpty, "全卷不许当项目扫描根")
    }

    func testZeroByteHiddenPartialListedAndExclusionNarrows() {
        let project = dir("proj", under: "/dev", children: [
            dir("node_modules", under: "/dev/proj", bytes: 0),
            dir("target", under: "/dev/proj", bytes: 0, partial: true, children: [
                SpaceNode(name: "x", path: "/dev/proj/target/x", kind: .directory, isPartial: true),
            ]),
        ])
        let root = dir("dev", under: "/", children: [project])
        var out = match(in: [root], roots: ["/dev"])
        XCTAssertEqual(out.map(\.path), ["/dev/proj/target"], "零字节不列、部分扫描如实列")

        out = match(in: [root], roots: ["/dev"], excludedPathPrefixes: ["/dev/proj/target"])
        XCTAssertTrue(out.isEmpty, "排除双保险:扫后新加的排除立即生效")
    }

    /// 登记完整性的正例是按规则自己的标记铺盘上事实的(同源,标记写错发现不了;标记与上游的逐个对应在
    /// `ProjectArtifactPortLedgerTests`)。这里手写几种真实工程的盘上事实,确认标记内容本身没写错。
    func testMarkerContentsMatchRealProjectLayouts() {
        let project = dir("proj", under: "/dev", children: [
            dir(".dart_tool", under: "/dev/proj", bytes: 10),
            dir("Pods", under: "/dev/proj", bytes: 10),
            dir(".godot", under: "/dev/proj", bytes: 10),
            dir(".tox", under: "/dev/proj", bytes: 10),
            dir(".stack-work", under: "/dev/proj", bytes: 10),
            dir(".zig-cache", under: "/dev/proj", bytes: 10),
            dir("vendor", under: "/dev/proj", bytes: 10),
            dir("deps", under: "/dev/proj", bytes: 10),
            dir(".nuxt", under: "/dev/proj", bytes: 10),
            dir(".svelte-kit", under: "/dev/proj", bytes: 10),
            dir(".pytest_cache", under: "/dev/proj", bytes: 10),
        ])
        let root = dir("dev", under: "/", children: [project])
        func hit(_ files: [String]) -> Set<String> {
            Set(match(in: [root], roots: ["/dev"], files: Set(files)).map(\.ruleID))
        }
        // 一个 Flutter 工程:只有 pubspec.yaml。
        XCTAssertEqual(hit(["/dev/proj/pubspec.yaml"]), ["artifact.dart-tool"])
        // 一个只有依赖清单的 Python 工程。
        XCTAssertEqual(hit(["/dev/proj/requirements.txt"]), ["artifact.pytest-cache"])
        // 一个 Godot 工程。
        XCTAssertEqual(hit(["/dev/proj/project.godot"]), ["artifact.godot-cache"])
        // 一个 Composer 的 PHP 工程:vendor 认;deps 不认(它只认 mix.exs)。
        XCTAssertEqual(hit(["/dev/proj/composer.json"]), ["artifact.composer-vendor"])
        // 一个 Nuxt 工程(nuxt.config 的四种写法之一)。
        XCTAssertEqual(hit(["/dev/proj/nuxt.config.mjs"]), ["artifact.nuxt-build"])
        // 一个 Zig 工程:zig-cache(旧名)与 .zig-cache 都认。
        XCTAssertEqual(hit(["/dev/proj/build.zig"]), ["artifact.zig-cache"])
        // 工程文件在上一级不算(除了 sbt 的 project/target,见上面那条用例)。
        XCTAssertEqual(hit(["/dev/build.zig"]), [])
    }

    /// 生产用的目录清单:只认普通文件、扩展名转小写;目录名带点的不算,符号链接不算,读不了给空集。
    func testLiveExtensionProbeListsRegularFilesOnlyInLowercase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-marker-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("App.CSPROJ"))
        try Data().write(to: directory.appendingPathComponent("readme.md"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("assets.TF"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("link.sln").path,
            withDestinationPath: "/nonexistent/target.sln"
        )

        XCTAssertEqual(ProjectArtifactMatcher.fileExtensions(ofDirectory: directory.path), ["csproj", "md"])
        XCTAssertEqual(
            ProjectArtifactMatcher.fileExtensions(ofDirectory: directory.appendingPathComponent("missing").path),
            []
        )
    }

    /// 一次匹配里每个目录只列一次清单(一条规则可以带好几个按扩展名认的标记,同一个目录下也可以有几个产物)。
    func testExtensionProbeListsEachDirectoryOnce() {
        let project = dir("proj", under: "/dev", children: [
            dir("bin", under: "/dev/proj", bytes: 10),
            dir("obj", under: "/dev/proj", bytes: 10),
        ])
        let root = dir("dev", under: "/", children: [project])
        var listed: [String] = []
        let out = ProjectArtifactMatcher.artifacts(
            in: [root], roots: ["/dev"], excludedPathPrefixes: [],
            fileExists: { _ in false },
            fileExtensions: { directory in
                listed.append(directory)
                return ["sln"]
            }
        )
        XCTAssertEqual(Set(out.map(\.path)), ["/dev/proj/bin", "/dev/proj/obj"])
        XCTAssertEqual(listed, ["/dev/proj"])
    }

    // MARK: 年龄口径(票面钉死:重装依赖不刷新年龄)

    func testProjectAgeIgnoresArtifactMtimes() {
        let out = match(in: [tree()], roots: ["/Users/dev/code"])
        let oldAppNode = out.first { $0.projectName == "/Users/dev/code/old-app" }
        // node_modules 里文件 mtime = 1_700_100_000(新),源码 = 40 天前——
        // 年龄必须是源码那个,产物自身 mtime 一点不算。
        XCTAssertEqual(oldAppNode?.newestChangeEpoch, 1_700_000_000 - 40 * 86400)
        let newToolNode = out.first { $0.projectName == "/Users/dev/code/new-tool" }
        XCTAssertEqual(newToolNode?.newestChangeEpoch, 1_700_200_000, "项目直属文件的最新变动")
    }

    func testProjectAgeIncludesGitActivity() {
        // .git 下的 FETCH_HEAD 是文件:刚 fetch 过的老项目年龄必须新鲜。
        let git = dir(".git", under: "/dev/proj", newest: 1_700_300_000)
        let project = dir("proj", under: "/dev", newest: 1_690_000_000, children: [
            dir("node_modules", under: "/dev/proj", bytes: 400, newest: 1_690_000_000),
            git,
        ])
        let root = dir("dev", under: "/", children: [project])
        let out = match(in: [root], roots: ["/dev"])
        XCTAssertEqual(out.first?.newestChangeEpoch, 1_700_300_000, "git 活动计入项目年龄")
    }

    // MARK: 活动推导(三路)+ 在用判定方向

    func testDerivationClassifiesAndMergesReasons() {
        let entries = CleanActivityDerivation.entries(from: [
            CleanActivitySample(executablePath: "/bin/zsh", cwd: "/Users/dev/proj", argv: []),
            CleanActivitySample(executablePath: "/opt/homebrew/bin/cargo", cwd: "/Users/dev/proj", argv: []),
            CleanActivitySample(executablePath: "/usr/bin/git", cwd: "/Users/dev/proj", argv: []),
        ])
        let proj = entries.first { $0.path == "/Users/dev/proj" }
        XCTAssertEqual(proj?.reasons, [.terminal, .build, .git], "同路径多进程原因取并集")
    }

    func testDerivationSkipsUnclassifiedCwdAndKeepsArgvReferences() {
        let entries = CleanActivityDerivation.entries(from: [
            // 守护进程 cwd 在家目录:不许变成「整个家目录都在用」
            CleanActivitySample(executablePath: "/System/Library/Frameworks/foo", cwd: "/Users/dev", argv: []),
            // 未分类进程 argv 里的绝对路径引用仍然算数
            CleanActivitySample(
                executablePath: "/usr/bin/tail",
                cwd: "/private/tmp",
                argv: ["-f", "/Users/dev/proj/build/log"]
            ),
        ])
        XCTAssertFalse(entries.contains { $0.path == "/Users/dev" }, "未分类 cwd 不发条目")
        XCTAssertTrue(entries.contains { $0.path == "/Users/dev/proj/build/log" && $0.reasons == [.referenced] })
    }

    func testInUseDirectionIsInsideOnly() {
        let entries = [
            CleanActivityEntry(path: "/Users/dev/proj", reasons: [.terminal]),
        ]
        // 活动在项目之内 → 保护(含项目根本身、产物、更深处)。
        XCTAssertEqual(CleanInUse.reasons(protectingPath: "/Users/dev/proj", entries: entries), [.terminal])
        // 反方向不算:活动在父目录(cd 在家目录)不保护子项目;别的项目更不保护。
        let parentActivity = [CleanActivityEntry(path: "/Users/dev", reasons: [.terminal])]
        XCTAssertNil(CleanInUse.reasons(protectingPath: "/Users/dev/proj", entries: parentActivity))
        XCTAssertNil(CleanInUse.reasons(protectingPath: "/Users/dev/other", entries: entries))
        // 更深的活动(产物内部的构建)→ 同样保护项目。
        let deep = [CleanActivityEntry(path: "/Users/dev/proj/node_modules/.bin", reasons: [.build])]
        XCTAssertEqual(CleanInUse.reasons(protectingPath: "/Users/dev/proj", entries: deep), [.build])
    }
}
