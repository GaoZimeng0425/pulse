@testable import PulseCore
import XCTest

/// 系统级规则(p7-cleaner/05;起步一条:过期的系统崩溃报告)。接缝 1:扫描树 → 候选清单。
/// 系统目录建不成夹具,手搭 /Library 下的树;文件节点按扫描引擎「保留文件节点」时的
/// 形状给(kind = file,修改时间在 `newestChangeEpoch`)。
final class SystemLevelRulesTests: XCTestCase {
    private let reports = "/Library/Logs/DiagnosticReports"
    private let now: TimeInterval = 1_700_000_000
    private let day: TimeInterval = 86400

    private func file(_ name: String, bytes: Int64 = 100, modified: Double?) -> SpaceNode {
        SpaceNode(
            name: name,
            path: reports + "/" + name,
            kind: .file,
            accountedBytes: bytes,
            fileCount: 1,
            newestChangeEpoch: modified
        )
    }

    private func tree(_ children: [SpaceNode]) -> SpaceNode {
        chain(to: reports, children: children)
    }

    /// 从根起按路径分量搭出一条目录链(名字 = 分量:扫描树按名字下钻),末端放 children。
    private func chain(to directory: String, children: [SpaceNode]) -> SpaceNode {
        var node = SpaceNode(
            name: (directory as NSString).lastPathComponent, path: directory, kind: .directory, children: children
        )
        var parent = (directory as NSString).deletingLastPathComponent
        while parent != "/" {
            node = SpaceNode(
                name: (parent as NSString).lastPathComponent,
                path: parent,
                kind: .directory,
                children: [node]
            )
            parent = (parent as NSString).deletingLastPathComponent
        }
        return node
    }

    private func detect(_ tree: SpaceNode, excluded: [String] = []) -> [JunkCandidate] {
        SystemLevelDetector.detect(in: [tree], now: now, excludedPathPrefixes: excluded)
    }

    // MARK: 正例

    /// 放满 7 天的崩溃报告出现在清单里:「需要管理员权限」条目标志、归系统级组、
    /// 「可安全清理」档(认识的条目归安全档;移走前才要密码)。删前复核的快照 = 文件自身
    /// 的修改时间。
    func testExpiredCrashReportIsListedAsRequiringAuthorization() throws {
        let modified = now - 8 * day
        let tree = tree([file("Pulse_2026-11-19-100000_MacBook-Pro.diag", bytes: 4096, modified: modified)])

        let item = try XCTUnwrap(detect(tree).only)

        XCTAssertEqual(item.path, reports + "/Pulse_2026-11-19-100000_MacBook-Pro.diag")
        XCTAssertEqual(item.title, "Pulse_2026-11-19-100000_MacBook-Pro.diag")
        XCTAssertEqual(item.ruleID, "system.crashReports")
        XCTAssertEqual(item.flags, [.requiresAuthorization])
        XCTAssertEqual(item.group, .systemLevel)
        XCTAssertEqual(item.tier, .safe)
        XCTAssertEqual(item.bytes, 4096)
        XCTAssertEqual(item.fileCount, 1)
        XCTAssertEqual(item.modifiedAtScan, modified, "文件自身 mtime 就是删前复核的快照")
        XCTAssertEqual(item.newestChangeEpoch, modified)
        XCTAssertTrue(item.rationale.contains("管理员密码"), "行悬停要提前说清会要密码:\(item.rationale)")
    }

    /// 年龄门槛是「满 7 天」:刚好 7 天算过期,差一秒不算。
    func testAgeThresholdIsSevenWholeDays() {
        let tree = tree([
            file("Exactly.ips", modified: now - 7 * day),
            file("OneSecondShort.ips", modified: now - 7 * day + 1),
        ])

        XCTAssertEqual(detect(tree).map(\.path), [reports + "/Exactly.ips"])
    }

    // MARK: 只收该收的

    /// 只收目录直接下面的普通文件:符号链接、隐藏文件、子目录里的、目录本身、读不到修改
    /// 时间的一律不列(证明不了年龄就不列)。
    func testOnlyRegularNonHiddenDirectFilesAreListed() {
        let old = now - 30 * day
        let tree = tree([
            file("Old.diag", modified: old),
            SpaceNode(
                name: "Link.diag",
                path: reports + "/Link.diag",
                kind: .symlink,
                accountedBytes: 1,
                newestChangeEpoch: old
            ),
            file(".DS_Store", modified: old),
            SpaceNode(name: "Retired", path: reports + "/Retired", kind: .directory, children: [
                SpaceNode(
                    name: "Older.diag",
                    path: reports + "/Retired/Older.diag",
                    kind: .file,
                    accountedBytes: 1,
                    newestChangeEpoch: now - 90 * day
                ),
            ]),
            SpaceNode(
                name: "DiagnosticLogs",
                path: reports + "/DiagnosticLogs",
                kind: .directory,
                newestChangeEpoch: old
            ),
            file("NoTimestamp.diag", modified: nil),
        ])

        XCTAssertEqual(detect(tree).map(\.path), [reports + "/Old.diag"])
    }

    /// 右键排除照收:排除的报告不列。
    func testExcludedReportIsNotListed() {
        let tree = tree([
            file("Kept.diag", modified: now - 30 * day),
            file("Excluded.diag", modified: now - 30 * day),
        ])

        XCTAssertEqual(
            detect(tree, excluded: [reports + "/Excluded.diag"]).map(\.path),
            [reports + "/Kept.diag"]
        )
    }

    /// 目录不在扫描树里(被排除的扫描根、读不到)自然不产出。
    func testMissingDirectoryProducesNothing() {
        let tree = chain(to: "/Library/Logs", children: [])

        XCTAssertTrue(detect(tree).isEmpty)
    }

    /// 名字里带换行或制表符的不收:条目要一行一个写进清单文件交给复核脚本,这类名字没法表达。
    func testNamesThatCannotBeWrittenOnePerLineAreNotListed() {
        let tree = tree([
            file("Line\nBreak.diag", modified: now - 30 * day),
            file("Tab\tSeparated.diag", modified: now - 30 * day),
            file("Plain.diag", modified: now - 30 * day),
        ])

        XCTAssertEqual(detect(tree).map(\.path), [reports + "/Plain.diag"])
    }

    // MARK: 登记面

    /// 登记完整性:系统崩溃报告目录就是这一个——脚本的复核形状照它写,改了路径两边要一起动。
    func testCrashReportsDirectoryIsTheSystemOne() {
        XCTAssertEqual(SystemLevelRuleTable.crashReportsDirectory, "/Library/Logs/DiagnosticReports")
        XCTAssertEqual(SystemLevelRuleTable.crashReportsMinimumAge, 7 * 86400)
    }

    /// 登记完整性:每条内置的系统级规则至少被一个正例命中——新增规则不补正例必红;
    /// 规则的目录全部进「保留文件节点」前缀(规则按文件判年龄,节点不在树上就永远列不出)。
    func testEveryBuiltinRuleHasAPositiveExampleAndRetainsFileNodes() throws {
        for rule in SystemLevelRuleTable.builtin {
            let modified = now - rule.minimumAge - day
            let tree = chain(to: rule.directory, children: [
                SpaceNode(
                    name: "sample.report",
                    path: rule.directory + "/sample.report",
                    kind: .file,
                    accountedBytes: 1,
                    fileCount: 1,
                    newestChangeEpoch: modified
                ),
            ])

            let item = try XCTUnwrap(SystemLevelDetector.detect(in: [tree], now: now, excludedPathPrefixes: []).only)

            XCTAssertEqual(item.ruleID, rule.id)
            XCTAssertTrue(
                SystemLevelRuleTable.retainedFilePrefixes.contains(rule.directory),
                "\(rule.id) 的目录要进保留文件节点前缀"
            )
        }
    }
}

private extension [JunkCandidate] {
    var only: JunkCandidate? {
        count == 1 ? first : nil
    }
}
