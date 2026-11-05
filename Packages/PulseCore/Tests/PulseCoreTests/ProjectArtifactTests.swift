@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 项目产物 + 在用保护(p4-cleaner/05)。登记完整性(ADR-0008 的安全边界本体:
/// 每条内置规则必须被至少一个正例命中)、按项目分组、嵌套产物不重复列、
/// 年龄口径(重装依赖不刷新年龄;git 活动计入)、活动推导三路 + 在用判定方向。
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
    private func match(
        in trees: [SpaceNode],
        roots: [String],
        excludedPathPrefixes: [String] = [],
        files: Set<String>? = nil
    ) -> [JunkCandidate] {
        ProjectArtifactMatcher.artifacts(
            in: trees,
            roots: roots,
            excludedPathPrefixes: excludedPathPrefixes,
            fileExists: { path in files.map { $0.contains(path) } ?? true }
        )
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
        // 一个项目下铺齐全部规则目录名;每条内置规则必须至少命中一次。
        let rules = ProjectArtifactRuleTable.builtin
        var children: [SpaceNode] = []
        for rule in rules {
            children.append(dir(rule.directoryName, under: "/dev/proj", bytes: 10))
        }
        let project = dir("proj", under: "/dev", children: children)
        let root = dir("dev", under: "/", children: [project])

        let hit = Set(match(in: [root], roots: ["/dev"]).map(\.ruleID))
        for rule in rules {
            XCTAssertTrue(hit.contains(rule.id), "规则 \(rule.id) 没有正例——补 fixture 或删规则")
        }
    }

    // MARK: 分组与排序

    func testGroupsByProjectAndSortsBySize() {
        let out = match(in: [tree()], roots: ["/Users/dev/code"])
        XCTAssertEqual(out.map(\.projectName), ["old-app", "old-app", "new-tool"], "按项目归组语义")
        XCTAssertEqual(out.first?.path, "/Users/dev/code/old-app/node_modules", "组内大到小")
        XCTAssertEqual(out.first?.group, .projectArtifacts)
        XCTAssertTrue(out.allSatisfy { $0.tier == .safe }, "node_modules / target 都是无歧义产物")
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
        XCTAssertEqual(out.first { $0.path == "/dev/node_modules" }?.projectName, "dev")
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

    // MARK: 年龄口径(票面钉死:重装依赖不刷新年龄)

    func testProjectAgeIgnoresArtifactMtimes() {
        let out = match(in: [tree()], roots: ["/Users/dev/code"])
        let oldAppNode = out.first { $0.projectName == "old-app" }
        // node_modules 里文件 mtime = 1_700_100_000(新),源码 = 40 天前——
        // 年龄必须是源码那个,产物自身 mtime 一点不算。
        XCTAssertEqual(oldAppNode?.newestChangeEpoch, 1_700_000_000 - 40 * 86400)
        let newToolNode = out.first { $0.projectName == "new-tool" }
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
