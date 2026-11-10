@testable import PulseCore
import XCTest

/// 清理总览聚合(p6-cleaner/03,纯逻辑):候选 × 活动条目 → 品类聚合行。
/// 夹具 = 丙案 v2 原型那批 2026-11-09 真机探针实测(spec Testing Decisions 拍板):
/// 23 项(dev 8 / browser 3 / app 6 / ai 2 / proj 3 / leftover 1,GB 值照抄原型)
/// + 废纸篓 0.95 GB / 31 项。在用两条:p3(项目产物,safe 档但项目有构建进程)、
/// m1(AI 模型,先检查档且 ollama 在跑)——钉死「在用与档位正交、三段互斥」的口径。
final class JunkOverviewTests: XCTestCase {
    // MARK: 夹具(原型真机数据)

    private let home = "/Users/probe"

    /// 原型 GB 值 → 字节(十进制口径,同 PulseFormat.memory;rounded 抵 Double 噪声)。
    private func gb(_ value: Double) -> Int64 {
        Int64((value * 1_000_000_000).rounded())
    }

    private func cand(
        _ path: String,
        group: JunkGroup,
        tier: CleanSafetyTier,
        bytes: Double,
        title: String? = nil,
        projectName: String? = nil
    ) -> JunkCandidate {
        JunkCandidate(
            ruleID: "fixture." + path,
            group: group,
            title: title ?? (path as NSString).lastPathComponent,
            path: path,
            tier: tier,
            bytes: gb(bytes),
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: true,
            rationale: "夹具",
            symbolName: "folder",
            projectName: projectName,
            newestChangeEpoch: nil,
            modifiedAtScan: nil
        )
    }

    /// 23 项候选(路径取原型的真实位置,家目录换成夹具 home)。
    private func fixtureCandidates() -> [JunkCandidate] {
        var items: [JunkCandidate] = []
        // dev 8(全 safe)
        for (name, size) in [
            ("Xcode DerivedData", 0.7), ("_npx", 5.7), ("Homebrew", 1.6), ("registry", 1.8),
            ("uv", 1.6), ("caches", 1.3), ("pnpm", 0.8), ("ms-playwright", 0.6),
        ] {
            items.append(cand(
                "\(home)/Library/Caches/\(name)",
                group: .globalToolCache,
                tier: .safe,
                bytes: size,
                title: name
            ))
        }
        // browser 3(全 safe)
        for (name, size) in [("Arc", 1.7), ("Dia", 0.9), ("com.izual.Easydict", 0.1)] {
            items.append(cand(
                "\(home)/Library/Caches/\(name)",
                group: .browserCache,
                tier: .safe,
                bytes: size,
                title: name
            ))
        }
        // app 6(safe 3 / check 3)
        for (name, size, tier) in [
            ("@zcodedesktop-updater", 0.6, CleanSafetyTier.safe),
            ("com.bytedance.inputmethod.doubaoime", 0.2, CleanSafetyTier.safe),
            ("Logs", 0.1, CleanSafetyTier.safe),
            ("CloudKit", 1.2, CleanSafetyTier.checkFirst),
            ("Citro Labs", 0.3, CleanSafetyTier.checkFirst),
            ("MyGo Music", 0.2, CleanSafetyTier.checkFirst),
        ] {
            items.append(cand(
                "\(home)/Library/Caches-or-Logs/\(name)",
                group: .appCache,
                tier: tier,
                bytes: size,
                title: name
            ))
        }
        // ai 2(check;m1 在用)
        items.append(cand(
            "\(home)/.ollama/models",
            group: .aiModels,
            tier: .checkFirst,
            bytes: 1.1,
            title: "Ollama · 2 个模型"
        ))
        items.append(cand(
            "\(home)/.cache/huggingface",
            group: .aiModels,
            tier: .checkFirst,
            bytes: 0.9,
            title: "HuggingFace 缓存"
        ))
        // proj 3(safe;p3 在用——保护路径是项目目录,不是产物自身)
        items.append(cand(
            "\(home)/Documents/Learn/macos/Vela/.build",
            group: .projectArtifacts,
            tier: .safe,
            bytes: 1.3,
            title: ".build",
            projectName: "Vela"
        ))
        items.append(cand(
            "\(home)/Documents/Learn/macos/Curator/.build",
            group: .projectArtifacts,
            tier: .safe,
            bytes: 0.2,
            title: ".build",
            projectName: "Curator"
        ))
        items.append(cand(
            "\(home)/Documents/Learn/macos/pulse/Packages/PulseCore/.build",
            group: .projectArtifacts,
            tier: .safe,
            bytes: 0.4,
            title: ".build",
            projectName: "pulse"
        ))
        // leftover 1(safe)
        items.append(cand(
            "\(home)/Library/Application Support/OrphanLeftovers",
            group: .uninstallLeftovers,
            tier: .safe,
            bytes: 0.02,
            title: "3 个应用的零星残留"
        ))
        return items
    }

    /// 活动条目:pulse 的 PulseCore 项目有构建进程(保护 p3);ollama 在跑(引用 .ollama/models)。
    private func fixtureActivity() -> [CleanActivityEntry] {
        [
            CleanActivityEntry(path: "\(home)/Documents/Learn/macos/pulse/Packages/PulseCore", reasons: [.build]),
            CleanActivityEntry(path: "\(home)/.ollama/models", reasons: [.referenced]),
        ]
    }

    // MARK: 品类聚合

    /// 六组齐全的夹具:各组总量 / 三段构成 / 条数与原型逐一相符。
    func testFixtureGroupAggregatesMatchPrototype() {
        let overview = JunkOverviewAggregator.overview(
            candidates: fixtureCandidates(),
            activityEntries: fixtureActivity()
        )
        XCTAssertEqual(overview.rows.count, 6)
        XCTAssertEqual(overview.rows.map(\.group), JunkGroup.allCases, "行序 = JunkGroup.allCases(UI 组序)")

        let dev = overview.row(for: .globalToolCache)
        XCTAssertEqual(dev?.itemCount, 8)
        XCTAssertEqual(dev?.totalBytes, gb(14.1))
        XCTAssertEqual(dev?.safeBytes, gb(14.1))
        XCTAssertEqual(dev?.checkBytes, 0)
        XCTAssertEqual(dev?.inUseBytes, 0)
        XCTAssertEqual(dev?.largestTitle, "_npx")
        XCTAssertEqual(dev?.largestBytes, gb(5.7))

        let browser = overview.row(for: .browserCache)
        XCTAssertEqual(browser?.itemCount, 3)
        XCTAssertEqual(browser?.totalBytes, gb(2.7))
        XCTAssertEqual(browser?.safeBytes, gb(2.7))

        let app = overview.row(for: .appCache)
        XCTAssertEqual(app?.itemCount, 6)
        XCTAssertEqual(app?.totalBytes, gb(2.6))
        XCTAssertEqual(app?.safeBytes, gb(0.9))
        XCTAssertEqual(app?.checkBytes, gb(1.7))
        XCTAssertEqual(app?.inUseBytes, 0)

        // AI 组:m1 先检查档但在用 → 全额进 inuse 段,check 段只剩 m2。
        let ai = overview.row(for: .aiModels)
        XCTAssertEqual(ai?.itemCount, 2)
        XCTAssertEqual(ai?.totalBytes, gb(2.0))
        XCTAssertEqual(ai?.safeBytes, 0)
        XCTAssertEqual(ai?.checkBytes, gb(0.9))
        XCTAssertEqual(ai?.inUseBytes, gb(1.1))

        // 项目产物:p3 是 safe 档但在用(构建进程在项目目录)→ safe 段只计 p1/p2。
        let proj = overview.row(for: .projectArtifacts)
        XCTAssertEqual(proj?.itemCount, 3)
        XCTAssertEqual(proj?.totalBytes, gb(1.9))
        XCTAssertEqual(proj?.safeBytes, gb(1.5))
        XCTAssertEqual(proj?.inUseBytes, gb(0.4))
        XCTAssertEqual(proj?.largestBytes, gb(1.3))

        let leftover = overview.row(for: .uninstallLeftovers)
        XCTAssertEqual(leftover?.itemCount, 1)
        XCTAssertEqual(leftover?.totalBytes, gb(0.02))
        XCTAssertEqual(leftover?.safeBytes, gb(0.02))
    }

    /// 总计(Hero 数据面):三段互斥相加恒等于合计,数字与原型合计一致。
    func testFixtureTotalsAndExclusiveComposition() {
        let overview = JunkOverviewAggregator.overview(
            candidates: fixtureCandidates(),
            activityEntries: fixtureActivity()
        )
        XCTAssertEqual(overview.totalBytes, gb(23.32))
        XCTAssertEqual(overview.safeBytes, gb(19.22))
        XCTAssertEqual(overview.checkBytes, gb(2.6))
        XCTAssertEqual(overview.inUseBytes, gb(1.5))
        XCTAssertEqual(overview.itemCount, 23)
        XCTAssertEqual(overview.totalBytes, overview.safeBytes + overview.checkBytes + overview.inUseBytes)
        // 各行同样满足互斥恒等式(构成条不重不漏的机械保证)。
        for row in overview.rows {
            XCTAssertEqual(row.totalBytes, row.safeBytes + row.checkBytes + row.inUseBytes)
        }
    }

    /// 空组不出行(02 未合时 AI 卡随空组自然不出):缺 browser / ai 的候选 → 只出四行,
    /// 且顺序仍是 JunkGroup.allCases 序。
    func testEmptyGroupsOmittedInCanonicalOrder() {
        let partial = fixtureCandidates().filter { $0.group != .browserCache && $0.group != .aiModels }
        let overview = JunkOverviewAggregator.overview(candidates: partial, activityEntries: [])
        XCTAssertEqual(
            overview.rows.map(\.group),
            [.globalToolCache, .appCache, .projectArtifacts, .uninstallLeftovers]
        )
        XCTAssertFalse(overview.isEmpty)
        // 全空 → 空 overview(总览页给空态卡)。
        let empty = JunkOverviewAggregator.overview(candidates: [], activityEntries: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.totalBytes, 0)
    }

    // MARK: 一键清理安全项

    /// 一键 = 全部 safe 且非在用:先检查档与在用项(safe 的 p3、checkFirst 的 m1)绝不入选,
    /// 且 safe ∩ 非在用 的每一项都在——既不漏杀也不多杀。
    func testSafeAutoSelectionExcludesCheckAndInUse() {
        let candidates = fixtureCandidates()
        let entries = fixtureActivity()
        let selection = JunkOverviewAggregator.safeAutoSelection(candidates: candidates, activityEntries: entries)

        XCTAssertEqual(selection.count, 17)
        XCTAssertEqual(selection.reduce(Int64(0)) { $0 + $1.bytes }, gb(19.22))

        let selectionPaths = Set(selection.map(\.path))
        // 「一键 ∩ {先检查 ∪ 在用} = ∅」
        let checkFirst = candidates.filter { $0.tier == .checkFirst }
        for candidate in checkFirst {
            XCTAssertFalse(selectionPaths.contains(candidate.path), "先检查项不得进入一键:\(candidate.title)")
        }
        XCTAssertFalse(
            selectionPaths.contains("\(home)/Documents/Learn/macos/pulse/Packages/PulseCore/.build"),
            "safe 档但在用的 p3 不得进入一键"
        )
        XCTAssertFalse(selectionPaths.contains("\(home)/.ollama/models"), "先检查且在用的 m1 不得进入一键")
        // 反向:每个 safe 且非在用的项都在。
        let expected = candidates.filter { candidate in
            candidate.tier == .safe
                && CleanInUse
                .reasons(protectingPath: CleanInUse.protectionPath(for: candidate), entries: entries) == nil
        }.map(\.path)
        XCTAssertEqual(selectionPaths, Set(expected))
    }

    /// 无活动源 / 无活动时:safe 档全可选(p3 不再被保护),先检查仍绝不入选。
    func testSafeAutoSelectionWithoutActivityTakesAllSafe() {
        let selection = JunkOverviewAggregator.safeAutoSelection(candidates: fixtureCandidates(), activityEntries: [])
        XCTAssertEqual(selection.count, 18) // 17 + p3
        XCTAssertTrue(selection.allSatisfy { $0.tier == .safe })
        XCTAssertEqual(selection.reduce(Int64(0)) { $0 + $1.bytes }, gb(19.62)) // 19.22 + 0.4
    }

    // MARK: 全部清单过滤

    /// 过滤纯值:nil = 全量同序;按品类 = 只留该组(顺序不变)。
    func testFilterByGroup() {
        let candidates = fixtureCandidates()
        XCTAssertEqual(JunkOverviewAggregator.filtered(candidates, by: nil).count, 23)
        XCTAssertEqual(JunkOverviewAggregator.filtered(candidates, by: nil), candidates)

        let appOnly = JunkOverviewAggregator.filtered(candidates, by: .appCache)
        XCTAssertEqual(appOnly.count, 6)
        XCTAssertTrue(appOnly.allSatisfy { $0.group == .appCache })
        XCTAssertEqual(
            appOnly.map(\.path),
            candidates.filter { $0.group == .appCache }.map(\.path),
            "过滤不重排,保持清单序"
        )
        XCTAssertEqual(JunkOverviewAggregator.filtered(candidates, by: .aiModels).count, 2)
    }

    /// 废纸篓读数复用 TrashInventory(总览卡数据面;原型夹具 0.95 GB / 31 项)。
    func testTrashInventoryFixtureReading() {
        let inventory = TrashInventory(
            volumes: [TrashInventory.Volume(name: "Macintosh HD", items: 31, bytes: gb(0.95))]
        )
        XCTAssertEqual(inventory.totalItems, 31)
        XCTAssertEqual(inventory.totalBytes, gb(0.95))
        XCTAssertFalse(inventory.isEmpty)
    }
}
