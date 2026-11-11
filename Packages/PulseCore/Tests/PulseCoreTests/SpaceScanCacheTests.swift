@testable import PulseCore
import XCTest

/// 扫描结果落盘缓存(p4-cleaner/11):紧凑二进制的编解码往返、损坏数据安全、
/// 路径按结构重建(节点只存名字)、根名与路径尾段不同(如 "/")也如实保留。
final class SpaceScanCacheTests: XCTestCase {
    private func node(
        _ name: String,
        under parent: String,
        kind: FsEntrySnapshot.Kind = .directory,
        bytes: Int64 = 0,
        newest: Double? = nil,
        partial: Bool = false,
        children: [SpaceNode] = []
    ) -> SpaceNode {
        let path = parent == "/" ? "/" + name : parent + "/" + name
        return SpaceNode(
            name: name,
            path: path,
            kind: kind,
            accountedBytes: max(bytes, children.reduce(Int64(0)) { $0 + $1.accountedBytes }),
            reclaimableBytes: max(bytes, children.reduce(Int64(0)) { $0 + $1.reclaimableBytes }),
            fallbackBytes: bytes,
            allReclaimableAccounting: true,
            fileCount: children.isEmpty ? 1 : children.reduce(0) { $0 + $1.fileCount },
            directoryCount: children.count,
            isPartial: partial,
            newestChangeEpoch: newest,
            children: children
        )
    }

    private func fixturePayload() -> SpaceScanCachePayload {
        let users = node("Users", under: "/System/Volumes/Data", bytes: 500, newest: 100.25, children: [
            node("me", under: "/System/Volumes/Data/Users", bytes: 500, children: [
                node("a.bin", under: "/System/Volumes/Data/Users/me", kind: .file, bytes: 300, newest: 200.5),
                node("locked", under: "/System/Volumes/Data/Users/me", partial: true),
            ]),
        ])
        // 根:path "/System/Volumes/Data" 根名 "Data";再放一个根名为 "/" 的规范根
        let dataRoot = node("Data", under: "/System/Volumes", children: [users])
        let canonicalRoot = SpaceNode(
            name: "/",
            path: "/",
            kind: .directory,
            accountedBytes: 900,
            isPartial: true,
            newestChangeEpoch: 300.75,
            children: [node("Users", under: "/", bytes: 900)]
        )

        var stats = ScanStats()
        stats.entriesSeen = 11
        stats.files = 6
        stats.directories = 4
        stats.symlinks = 1
        stats.datalessFiles = 2
        stats.hardlinkSkips = 3
        stats.doubleVisitSkips = 1
        stats.accountedBytes = 1400
        return SpaceScanCachePayload(
            meta: SpaceScanMeta(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_006_060.5),
                roots: ["/System/Volumes/Data"],
                excludedPathPrefixes: ["/Users/me/Library/Caches/Homebrew"],
                cleanedPaths: ["/Users/me/Library/Caches/Homebrew", "/x"]
            ),
            result: SpaceScanResult(
                trees: [dataRoot, canonicalRoot],
                ledger: [
                    CleanEnumerateError(path: "/System/Volumes/Data/Users/me/locked", reason: .tccDenied),
                    CleanEnumerateError(path: "/x", reason: .permissionDenied),
                    CleanEnumerateError(path: "/y", reason: .vanished),
                    CleanEnumerateError(path: "/z", reason: .tooDeep),
                    CleanEnumerateError(path: "/w", reason: .other(errno: 13)),
                    // 批取消档(cleaner-scan-hang/02):取消的扫描按理不落盘,编解码
                    // 对称写全——roundtrip 保证将来允许部分落盘时缓存格式不炸。
                    CleanEnumerateError(path: "/c", reason: .cancelled),
                ],
                stats: stats,
                cancelled: true
            )
        )
    }

    /// 扁平化账目(树无 Equatable,逐路径比字段)。
    private func flatten(_ node: SpaceNode, into map: inout [String: SpaceNode]) {
        map[node.path] = node
        for child in node.children {
            flatten(child, into: &map)
        }
    }

    func testRoundtripPreservesEverything() throws {
        let payload = fixturePayload()
        let data = SpaceScanCache.encode(payload)
        let decoded = try XCTUnwrap(SpaceScanCache.decode(data), "应能解码")

        XCTAssertEqual(decoded.meta, payload.meta)
        XCTAssertEqual(decoded.meta.cleanedPaths, ["/Users/me/Library/Caches/Homebrew", "/x"], "v2 新字段:清理后重开的过滤依据")
        let result = decoded.result
        XCTAssertEqual(result.cancelled, true)
        XCTAssertEqual(result.stats.entriesSeen, 11)
        XCTAssertEqual(result.stats.files, 6)
        XCTAssertEqual(result.stats.datalessFiles, 2)
        XCTAssertEqual(result.stats.hardlinkSkips, 3)
        XCTAssertEqual(result.stats.doubleVisitSkips, 1)
        XCTAssertEqual(result.stats.accountedBytes, 1400)
        XCTAssertEqual(result.ledger, payload.result.ledger, "台账逐条含 errno")

        var before: [String: SpaceNode] = [:]
        var after: [String: SpaceNode] = [:]
        for tree in payload.result.trees {
            flatten(tree, into: &before)
        }
        for tree in result.trees {
            flatten(tree, into: &after)
        }
        XCTAssertEqual(after.keys, before.keys, "路径集逐位一致(名字重建不漂移)")
        for (path, original) in before {
            let restored = after[path]
            XCTAssertEqual(restored?.name, original.name, path)
            XCTAssertEqual(restored?.kind, original.kind, path)
            XCTAssertEqual(restored?.accountedBytes, original.accountedBytes, path)
            XCTAssertEqual(restored?.reclaimableBytes, original.reclaimableBytes, path)
            XCTAssertEqual(restored?.fallbackBytes, original.fallbackBytes, path)
            XCTAssertEqual(restored?.allReclaimableAccounting, original.allReclaimableAccounting, path)
            XCTAssertEqual(restored?.isPartial, original.isPartial, path)
            XCTAssertEqual(restored?.newestChangeEpoch, original.newestChangeEpoch, path)
            XCTAssertEqual(restored?.fileCount, original.fileCount, path)
            XCTAssertEqual(restored?.directoryCount, original.directoryCount, path)
            XCTAssertEqual(restored?.children.count, original.children.count, path)
        }
        XCTAssertEqual(after["/"]?.name, "/", "根名与路径尾段不同也如实保留")
        XCTAssertEqual(after["/System/Volumes/Data/Users/me/a.bin"]?.newestChangeEpoch, 200.5)
    }

    func testCorruptedOrForeignDataReturnsNil() {
        XCTAssertNil(SpaceScanCache.decode(Data([0x00])), "过短")
        XCTAssertNil(SpaceScanCache.decode(Data("NOTPULSE".utf8)), "魔数不对")
        // 版本不识别
        var wrongVersion = SpaceScanCache.encode(fixturePayload())
        wrongVersion[4] = 0xFF
        XCTAssertNil(SpaceScanCache.decode(wrongVersion))
        // 中途截断:每一种截断位置都不得半解
        let full = SpaceScanCache.encode(fixturePayload())
        for cut in stride(from: 8, to: full.count, by: max(1, full.count / 37)) {
            XCTAssertNil(SpaceScanCache.decode(full.prefix(cut)), "截断 @\(cut) 必须 nil")
        }
        // 尾部多字节(不识别的续写)也拒绝
        var trailing = full
        trailing.append(0x42)
        XCTAssertNil(SpaceScanCache.decode(trailing))
    }

    /// 计数字段被篡改成负数 / 天文数字:必须 nil,不许 Range 崩溃或预留爆内存
    /// (cleaner-hardening/04)。空树载荷的末字节恰是树计数 varint。
    func testCorruptedCountFieldReturnsNilInsteadOfCrashing() {
        let payload = SpaceScanCachePayload(
            meta: SpaceScanMeta(
                startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 1),
                roots: [],
                excludedPathPrefixes: []
            ),
            result: SpaceScanResult(trees: [], ledger: [], stats: ScanStats(), cancelled: false)
        )
        let full = SpaceScanCache.encode(payload)
        XCTAssertEqual(full.last, 0x00, "夹具前提:末字节 = 树计数 0")

        var negative = full
        negative[negative.count - 1] = 0x01 // zigzag → -1
        XCTAssertNil(SpaceScanCache.decode(negative), "负计数")

        var huge = full.dropLast()
        huge.append(contentsOf: [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10]) // zigzag → 2^42
        XCTAssertNil(SpaceScanCache.decode(Data(huge)), "超出剩余字节的计数")
    }

    func testEmptyResultRoundtrips() {
        let payload = SpaceScanCachePayload(
            meta: SpaceScanMeta(
                startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 1),
                roots: [],
                excludedPathPrefixes: []
            ),
            result: SpaceScanResult(trees: [], ledger: [], stats: ScanStats(), cancelled: false)
        )
        let decoded = SpaceScanCache.decode(SpaceScanCache.encode(payload))
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.result.trees.isEmpty == true)
        XCTAssertEqual(decoded?.meta.roots, [])
    }

    /// 真机体量预算:60 万目录节点的合成树,编码体积与耗时不爆表(冒烟上限,非精确基准)。
    func testLargeSyntheticTreeEncodesWithinBudget() throws {
        func makeBush(_ parent: String, depth: Int, breadth: Int, count: inout Int) -> SpaceNode {
            var children: [SpaceNode] = []
            if depth > 0 {
                for index in 0 ..< breadth {
                    children.append(makeBush(
                        parent == "/" ? "/d\(index)" : parent + "/d\(index)",
                        depth: depth - 1,
                        breadth: breadth,
                        count: &count
                    ))
                }
            }
            count += 1
            let name = (parent as NSString).lastPathComponent
            return SpaceNode(
                name: name.isEmpty ? parent : name,
                path: parent,
                kind: .directory,
                accountedBytes: 1000,
                fileCount: 3,
                newestChangeEpoch: 1_700_000_000,
                children: children
            )
        }
        var count = 0
        // 7 层 × 6 叉 ≈ 33 万节点;两棵 ≈ 66 万,贴近真机目录量级
        let treeA = makeBush("/Users", depth: 7, breadth: 6, count: &count)
        let payload = SpaceScanCachePayload(
            meta: SpaceScanMeta(
                startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 60),
                roots: ["/Users"],
                excludedPathPrefixes: []
            ),
            result: SpaceScanResult(trees: [treeA], ledger: [], stats: ScanStats(), cancelled: false)
        )
        let start = Date()
        let data = SpaceScanCache.encode(payload)
        let encodeSeconds = Date().timeIntervalSince(start)
        let decodeStart = Date()
        let decoded = SpaceScanCache.decode(data)
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        XCTAssertNotNil(decoded)
        XCTAssertLessThan(data.count, 60 * 1000 * 1000, "预算 60MB 内")
        XCTAssertLessThan(encodeSeconds, 5, "编码冒烟上限 5s(真机预算 ~1s)")
        XCTAssertLessThan(decodeSeconds, 5, "解码冒烟上限 5s(真机预算 ~2s)")
        var flat: [String: SpaceNode] = [:]
        try flatten(XCTUnwrap(decoded?.result.trees[0]), into: &flat)
        XCTAssertGreaterThan(flat.count, 300_000, "节点量级证明可扩展(\(count) 个;真机 60 万由 Release 基准另测)")
    }
}
