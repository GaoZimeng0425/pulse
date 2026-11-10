@testable import PulseCore
import XCTest

/// mcp-disk-usage/01:快照目录占用查询与文案(手搭树夹具,同 ProjectArtifactTests 纪律)。
final class McpDiskUsageTests: XCTestCase {
    // MARK: 夹具

    private func dir(
        _ name: String, at path: String, bytes: Int64,
        partial: Bool = false, files: Int = 0,
        children: [SpaceNode] = []
    ) -> SpaceNode {
        var node = SpaceNode(
            name: name,
            path: path,
            kind: .directory,
            accountedBytes: bytes,
            isPartial: partial,
            newestChangeEpoch: nil,
            children: children
        )
        node.fileCount = files
        return node
    }

    private func file(_ name: String, at path: String, bytes: Int64) -> SpaceNode {
        return SpaceNode(
            name: name,
            path: path,
            kind: .file,
            accountedBytes: bytes,
            isPartial: false,
            newestChangeEpoch: nil,
            children: []
        )
    }

    /// /home/dev:code(projects + media)两级树;projects 本身缺席(被排除),
    /// 只留 a/b 两个孤儿子孙——练前缀聚合。
    private var tree: SpaceNode {
        let projectA = dir("a", at: "/home/dev/code/projects/a", bytes: 1000)
        let projectB = dir("b", at: "/home/dev/code/projects/b", bytes: 2000)
        let media = dir("media", at: "/home/dev/code/media", bytes: 4000, partial: true, files: 12, children: [
            file("big.mov", at: "/home/dev/code/media/big.mov", bytes: 3800),
        ])
        return dir("code", at: "/home/dev/code", bytes: 7000, children: [
            dir("projects", at: "/home/dev/code/projects", bytes: 0), // 占位父(另一种形态)
            media,
            projectA,
            projectB,
        ])
    }

    // MARK: 查询

    func testSubtreeExactHitReturnsNode() {
        let subtree = DiskUsageQuery.subtree(path: "/home/dev/code/media", in: [tree])
        XCTAssertEqual(subtree?.node?.path, "/home/dev/code/media")
        XCTAssertEqual(subtree?.aggregatedBytes, 4000)
        XCTAssertEqual(subtree?.matchedDescendantCount, 0)
    }

    func testSubtreeNormalizesTrailingSlash() {
        let subtree = DiskUsageQuery.subtree(path: "/home/dev/code/media/", in: [tree])
        XCTAssertEqual(subtree?.node?.path, "/home/dev/code/media")
    }

    func testSubtreePrefixAggregatesWhenParentExcluded() {
        // 把占位父换掉:projects 不在树里,只剩孤侄 a/b。
        let orphanTree = dir("code", at: "/home/dev/code", bytes: 7000, children: [
            dir("a", at: "/home/dev/code/projects/a", bytes: 1000, children: [
                dir("sub", at: "/home/dev/code/projects/a/sub", bytes: 600),
            ]),
            dir("b", at: "/home/dev/code/projects/b", bytes: 2000),
        ])
        let subtree = DiskUsageQuery.subtree(path: "/home/dev/code/projects", in: [orphanTree])
        XCTAssertNil(subtree?.node, "路径本身不在快照里")
        XCTAssertEqual(subtree?.aggregatedBytes, 3000, "a(含子树)+ b,命中层不重复计")
        XCTAssertEqual(subtree?.matchedDescendantCount, 2)
    }

    func testSubtreeMissReturnsNil() {
        XCTAssertNil(DiskUsageQuery.subtree(path: "/no/such", in: [tree]))
    }

    func testTopChildrenDirectoriesOnlySortedDesc() {
        let children = DiskUsageQuery.topChildren(of: tree, limit: 10)
        XCTAssertEqual(children.map(\.name), ["media", "b", "a", "projects"], "目录降序;big.mov 文件不入列")
        XCTAssertEqual(children.first?.isPartial, true)
        XCTAssertEqual(DiskUsageQuery.topChildren(of: tree, limit: 2).count, 2)
    }

    func testTopLevelMergesRootsSorted() {
        let otherRoot = dir("ext", at: "/Volumes/ext", bytes: 9000, children: [
            dir("docs", at: "/Volumes/ext/docs", bytes: 9000),
        ])
        let top = DiskUsageQuery.topLevel(in: [tree, otherRoot], limit: 3)
        XCTAssertEqual(top.map(\.name), ["docs", "media", "b"], "跨根合并按占用降序(列根的子女,不列根)")
        XCTAssertEqual(DiskUsageQuery.totalBytes(in: [tree, otherRoot]), 16000)
    }

    // MARK: 文案

    private var scanTime: Date {
        Date(timeIntervalSince1970: 1_789_000_000)
    }

    private var now: Date {
        scanTime.addingTimeInterval(30 * 60) // 扫描后 30 分钟
    }

    func testUsageTextCoversExactNodeAndChildren() throws {
        let media = try XCTUnwrap(tree.children.first { $0.name == "media" })
        let text = McpDiskUsageText.usage(
            path: "/home/dev/code/media",
            subtree: .init(node: media, aggregatedBytes: media.accountedBytes, matchedDescendantCount: 0),
            topChildren: [],
            scanFinishedAt: scanTime,
            cancelled: false,
            cleanedPathCount: 0,
            now: now
        )
        XCTAssertTrue(text.contains("30 分钟前"), "快照年龄:\(text)")
        XCTAssertTrue(text.contains("12 个文件"))
        XCTAssertTrue(text.contains("没有(能看到的)子目录"))
    }

    func testUsageTextPrefixAggregationSaysLowerBound() {
        let text = McpDiskUsageText.usage(
            path: "/home/dev/code/projects",
            subtree: .init(node: nil, aggregatedBytes: 3000, matchedDescendantCount: 2),
            topChildren: [],
            scanFinishedAt: scanTime,
            cancelled: false,
            cleanedPathCount: 2,
            now: now
        )
        XCTAssertTrue(text.contains("本身不在快照里"))
        XCTAssertTrue(text.contains("下限"))
        XCTAssertTrue(text.contains("已清理 2 个目录"), "扫描后清理过要注记:\(text)")
    }

    func testOverviewTextHeaderAndCancelled() {
        let text = McpDiskUsageText.overview(
            roots: ["/Users/dev"],
            totalBytes: 7000,
            top: DiskUsageQuery.topChildren(of: tree, limit: 2),
            scanFinishedAt: scanTime,
            cancelled: true,
            cleanedPathCount: 0,
            now: now
        )
        XCTAssertTrue(text.contains("扫描范围:/Users/dev"))
        XCTAssertTrue(text.contains("7 KB"))
        XCTAssertTrue(text.contains("被中途取消"))
        XCTAssertTrue(text.contains("media"))
    }

    func testCacheFileNameConstantMatchesAppContract() {
        XCTAssertEqual(SpaceScanCache.defaultFileName, "scan-cache-v1.bin", "app 与 pulse-mcp 读同一文件,改名须两头同步")
    }
}
