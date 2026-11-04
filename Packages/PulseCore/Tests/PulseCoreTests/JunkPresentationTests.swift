@testable import PulseCore
import XCTest

/// 展示层纯值(p4-uninstaller/08):两组排序、项目产物分组、全局缓存候选带
/// 最近变动 epoch(工具缓存「新旧」排序的数据前提)。
final class JunkPresentationTests: XCTestCase {
    private func candidate(
        _ path: String, bytes: Int64, epoch: Double? = nil,
        project: String? = nil, tier: CleanSafetyTier = .safe
    ) -> JunkCandidate {
        JunkCandidate(
            ruleID: "r", group: project == nil ? .globalToolCache : .projectArtifacts,
            title: (path as NSString).lastPathComponent, path: path, tier: tier,
            bytes: bytes, fileCount: 1, isPartial: false,
            allReclaimableAccounting: true, rationale: "…", symbolName: "cube",
            projectName: project, newestChangeEpoch: epoch
        )
    }

    // MARK: 排序

    func testSizeSortDescending() {
        let items = [candidate("/a", bytes: 10), candidate("/b", bytes: 900), candidate("/c", bytes: 100)]
        XCTAssertEqual(items.sortedForDisplay(by: .size).map(\.bytes), [900, 100, 10])
    }

    func testAgeSortOldestFirstWithUnknownLast() {
        let items = [
            candidate("/new", bytes: 1, epoch: 1_000_000),
            candidate("/old", bytes: 1, epoch: 500_000),
            candidate("/unknown", bytes: 1, epoch: nil),
            candidate("/mid", bytes: 1, epoch: 800_000),
        ]
        XCTAssertEqual(
            items.sortedForDisplay(by: .age).map(\.path),
            ["/old", "/mid", "/new", "/unknown"],
            "最久未动在前;未知排最后,不伪造"
        )
    }

    // MARK: 项目分组

    func testProjectGroupingAggregatesByName() {
        let items = [
            candidate("/code/octok/node_modules", bytes: 2100, epoch: 1000, project: "octok"),
            candidate("/code/pulse/node_modules", bytes: 640, epoch: 900, project: "pulse"),
            candidate("/code/octok/target", bytes: 1100, epoch: 500, project: "octok"),
        ]
        let groups = ProjectJunkGrouping.group(items)
        XCTAssertEqual(groups.map(\.projectName), ["octok", "pulse"], "首现序,不重排组间")
        let octok = groups[0]
        XCTAssertEqual(octok.items.count, 2)
        XCTAssertEqual(octok.totalBytes, 3200)
        XCTAssertEqual(octok.newestChangeEpoch, 1000, "项目最近活动 = 组内最新")
    }

    func testProjectGroupingFallsBackForMissingProjectName() {
        // 异常候选(无 projectName):按标题单列兜底,不丢行。
        let items = [candidate("/x/odd", bytes: 5, project: nil)]
        let groups = ProjectJunkGrouping.group(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].projectName, "odd")
    }

    // MARK: 全局缓存候选带 epoch(集成:树上有 mtime → 候选带出)

    func testMatcherCarriesRecentChangeEpochForGlobalCache() throws {
        func dir(_ path: String, mtime: Double?, children: [SpaceNode] = []) -> SpaceNode {
            SpaceNode(
                name: (path as NSString).lastPathComponent, path: path, kind: .directory,
                accountedBytes: 100, newestChangeEpoch: mtime, children: children
            )
        }
        let home = "/Users/t"
        let tree = dir(home, mtime: nil, children: [
            dir("\(home)/Library", mtime: nil, children: [
                dir("\(home)/Library/Caches", mtime: nil, children: [
                    dir("\(home)/Library/Caches/org.swift.swiftpm", mtime: 1_730_000_000, children: [
                        SpaceNode(
                            name: "f.bin",
                            path: "\(home)/Library/Caches/org.swift.swiftpm/f.bin",
                            kind: .file,
                            accountedBytes: 100,
                            newestChangeEpoch: 1_730_000_000
                        ),
                    ]),
                ]),
            ]),
        ])
        let candidates = JunkMatcher.candidates(in: [tree], home: home)
        let swiftpm = try XCTUnwrap(candidates.first { $0.ruleID == "swiftpm.cache" })
        XCTAssertEqual(swiftpm.newestChangeEpoch, 1_730_000_000, "全局缓存候选取节点最近变动(08 工具缓存排序数据前提)")
    }
}
