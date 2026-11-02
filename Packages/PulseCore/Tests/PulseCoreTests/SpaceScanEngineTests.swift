@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 空间扫描引擎(p4-cleaner/02):口径 / 去重 / 防双计 / 台账 / 取消 / 排除。
/// 全部打在内存文件系统夹具上——零真盘 I/O、零真删除(CODING_STANDARDS 测试纪律)。
/// 口径依据:探针 11(PRVATESIZE=删即释放、firmlink 同 dev);布局细节见 docs/probes/11。
final class SpaceScanEngineTests: XCTestCase {
    private let engine = SpaceScanEngine()

    // MARK: 口径

    /// 全量 PRIVATESIZE:树按「真实可回收」求和,表观/回退口径各自另存。
    func testTreeAggregatesReclaimableBytes() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("a.bin", logical: 600, allocated: 512, reclaimable: 512),
                CleanFixture.file("b.bin", logical: 1200, allocated: 1024, reclaimable: 1024),
                CleanFixture.directory("sub", fileID: 101),
            ]),
            "/r/sub": .entries([
                CleanFixture.file("c.bin", allocated: 2048, reclaimable: 2048),
            ]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.trees.count, 1)
        let root = result.trees[0]
        XCTAssertEqual(root.accountedBytes, 512 + 1024 + 2048)
        XCTAssertEqual(root.reclaimableBytes, 512 + 1024 + 2048)
        XCTAssertEqual(root.fallbackBytes, 512 + 1024 + 2048)
        XCTAssertTrue(root.allReclaimableAccounting)
        XCTAssertEqual(root.fileCount, 3)
        XCTAssertEqual(root.directoryCount, 1)
        XCTAssertFalse(root.isPartial)
        XCTAssertEqual(result.stats.files, 3)
        XCTAssertEqual(result.stats.directories, 1)
        XCTAssertTrue(result.ledger.isEmpty)
    }

    /// PRIVATESIZE 缺席 → 该文件回退 block 口径,节点标记「非全量真实口径」。
    /// 不伪造 0:回退字节如实入账,标志位让界面标注(防御性数据纪律)。
    func testFallbackAccountingWhenPrivatesizeMissing() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("has.bin", allocated: 512, reclaimable: 512),
                CleanFixture.file("missing.bin", allocated: 4096, reclaimable: nil),
            ]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)
        let root = result.trees[0]

        XCTAssertEqual(root.accountedBytes, 512 + 4096)
        XCTAssertEqual(root.reclaimableBytes, 512)
        XCTAssertFalse(root.allReclaimableAccounting, "混入回退口径必须如实标记")
    }

    // MARK: 去重与防双计

    /// 硬链接:同 (device, fileID) 的文件只计首个——两处引用,字节一份。
    func testHardlinkedFileCountedOnce() async {
        let shared = CleanFixture.file("data.bin", allocated: 1024, reclaimable: 1024, fileID: 777)
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.directory("d1", fileID: 11),
                CleanFixture.directory("d2", fileID: 22),
            ]),
            "/r/d1": .entries([shared]),
            "/r/d2": .entries([shared]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.stats.hardlinkSkips, 1)
        XCTAssertEqual(result.trees[0].accountedBytes, 1024)
        XCTAssertEqual(result.trees[0].fileCount, 1)
    }

    /// firmlink 双路径(探针 11 ⑤:根卷与 Data 卷同 dev,双计风险在目录重复可达):
    /// 同 (device, fileID) 的目录只走先到的一条路径。
    func testFirmlinkDoubleVisitGuardSkipsSecondPath() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.directory("via-first", fileID: 555),
                CleanFixture.directory("via-second", fileID: 555),
            ]),
            "/r/via-first": .entries([CleanFixture.file("only.bin", allocated: 512, reclaimable: 512)]),
            "/r/via-second": .entries([CleanFixture.file("dup.bin", allocated: 512, reclaimable: 512)]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.stats.doubleVisitSkips, 1)
        let second = await fs.requestedPathCount("/r/via-second")
        XCTAssertEqual(second, 0, "同身份目录的第二条路径绝不该被枚举")
        XCTAssertEqual(result.trees[0].accountedBytes, 512)
    }

    /// 重叠根:一根是另一根的子孙 → 后到的整棵跳过,子树只出现一次。
    func testOverlappingRootsSecondSkipped() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/a": .entries([CleanFixture.directory("sub", fileID: 31)]),
            "/a/sub": .entries([CleanFixture.file("x.bin", allocated: 256, reclaimable: 256)]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/a", "/a/sub"]), using: fs)

        XCTAssertEqual(result.trees.count, 1, "重叠根只产一棵树")
        let subRequests = await fs.requestedPathCount("/a/sub")
        XCTAssertEqual(subRequests, 1)
        XCTAssertEqual(result.trees[0].fileCount, 1)
    }

    // MARK: 排除

    /// 排除目录(GLOSSARY:只收窄):不下潜、不计数;排除根 → 树缺席、不进台账(用户意图不是错误)。
    func testExcludedDirectoryNotDescended() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("keep.bin", allocated: 128, reclaimable: 128),
                CleanFixture.directory("node_modules", fileID: 41),
            ]),
            "/r/node_modules": .entries([CleanFixture.file("junk.js", allocated: 4096, reclaimable: 4096)]),
        ])
        let result = await engine.scan(
            SpaceScanOptions(roots: ["/r"], excludedPathPrefixes: ["/r/node_modules"]),
            using: fs
        )

        let nmRequests = await fs.requestedPathCount("/r/node_modules")
        XCTAssertEqual(nmRequests, 0)
        XCTAssertEqual(result.trees[0].fileCount, 1)
        XCTAssertEqual(result.trees[0].accountedBytes, 128)
        XCTAssertTrue(result.ledger.isEmpty, "排除是用户意图,不是错误")
    }

    // MARK: 台账与部分扫描

    /// 枚举失败:分类入册、子树标 partial、其余目录照走——绝不中断。
    func testPermissionFailureRecordedAndPartial() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.directory("locked", fileID: 51),
                CleanFixture.directory("open", fileID: 52),
            ]),
            "/r/locked": .failure(.permissionDenied),
            "/r/open": .entries([CleanFixture.file("f.bin", allocated: 64, reclaimable: 64)]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.ledger, [CleanEnumerateError(path: "/r/locked", reason: .permissionDenied)])
        XCTAssertTrue(result.trees[0].isPartial)
        XCTAssertEqual(result.trees[0].fileCount, 1, "兄弟目录不受牵连")
        let openRequests = await fs.requestedPathCount("/r/open")
        XCTAssertEqual(openRequests, 1)
    }

    /// 扫描中消失:入册 + partial,不崩。
    func testVanishedDirectoryTolerated() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.directory("gone", fileID: 61)]),
            "/r/gone": .failure(.vanished),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.ledger.first?.reason, .vanished)
        XCTAssertTrue(result.trees[0].isPartial)
    }

    /// 深度护栏(dust 教训):超深目录入台账标 partial,不崩不递归爆栈。
    func testMaxDepthGuard() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.directory("deep", fileID: 71)]),
            "/r/deep": .entries([CleanFixture.directory("deeper", fileID: 72)]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"], maxDepth: 1), using: fs)

        XCTAssertEqual(result.ledger, [CleanEnumerateError(path: "/r/deep", reason: .tooDeep)])
        XCTAssertTrue(result.trees[0].isPartial)
    }

    // MARK: 取消与进度

    /// 取消:已扫部分可用、结果标 cancelled;枚举不再继续。
    func testCancellationFlagsResultAndStops() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.directory("first", fileID: 81),
                CleanFixture.directory("second", fileID: 82),
            ]),
            "/r/first": .entries([CleanFixture.file("a.bin", allocated: 16, reclaimable: 16)]),
            "/r/second": .entries([CleanFixture.file("b.bin", allocated: 16, reclaimable: 16)]),
        ])
        let entered = LockedCounter()
        let result = await engine.scan(
            SpaceScanOptions(roots: ["/r"]),
            using: fs,
            isCancelled: { entered.next() >= 3 } // 根+first 放行,second 入口取消——已扫部分必须可用
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.trees[0].isPartial)
        let secondRequests = await fs.requestedPathCount("/r/second")
        XCTAssertEqual(secondRequests, 0, "取消后不再枚举新目录")
        XCTAssertEqual(result.trees[0].fileCount, 1, "已扫部分照常可用")
    }

    /// 进度:收尾必回调一次,末次统计与最终 stats 一致(< 2048 项时只在收尾发)。
    func testProgressCallbackCarriesFinalStats() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("a.bin", allocated: 8, reclaimable: 8)]),
        ])
        let calls = LockedValue<ScanStats>()
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs) { stats in
            calls.append(stats)
        }

        let all = calls.load()
        XCTAssertGreaterThanOrEqual(all.count, 1)
        XCTAssertEqual(all.last?.entriesSeen, result.stats.entriesSeen)
        XCTAssertEqual(all.last?.accountedBytes, 8)
    }

    // MARK: 边角

    /// 符号链接:不跟随、零字节贡献、单独计数。
    func testSymlinkNotFollowedAndZeroBytes() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.symlink("alias"),
                CleanFixture.file("real.bin", allocated: 32, reclaimable: 32),
            ]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.stats.symlinks, 1)
        XCTAssertEqual(result.trees[0].symlinkCount, 1)
        XCTAssertEqual(result.trees[0].accountedBytes, 32)
    }

    /// dataless(iCloud 壳):照常计数并单独标记,字节按口径如实(探针 11 ⑥)。
    func testDatalessCountedAndFlagged() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("cloud.bin", allocated: 0, reclaimable: 0, dataless: true)]),
        ])
        let result = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs)

        XCTAssertEqual(result.stats.datalessFiles, 1)
        XCTAssertEqual(result.trees[0].datalessCount, 1)
        XCTAssertEqual(result.trees[0].fileCount, 1)
    }

    // MARK: 文件节点不进树(p4-cleaner/04 内存量级:全卷 340 万项全量驻留 ≈900 MB)

    /// `retainFileNodes: false`:树里只剩目录节点,目录上的计数与字节与全量树逐位相同。
    func testDirectoryOnlyTreeKeepsAggregatesIdentical() async {
        let listings: [String: FakeCleanDirectoryEnumerator.Listing] = [
            "/r": .entries([
                CleanFixture.file("a.bin", allocated: 512, reclaimable: 512),
                CleanFixture.directory("sub", fileID: 301),
                CleanFixture.symlink("link"),
            ]),
            "/r/sub": .entries([
                CleanFixture.file("b.bin", allocated: 1024, reclaimable: nil),
                CleanFixture.file("c.bin", allocated: 0, reclaimable: 0, dataless: true),
            ]),
        ]
        let full = await engine.scan(
            SpaceScanOptions(roots: ["/r"]),
            using: FakeCleanDirectoryEnumerator(listings: listings)
        )
        let dirsOnly = await engine.scan(
            SpaceScanOptions(roots: ["/r"], retainFileNodes: false),
            using: FakeCleanDirectoryEnumerator(listings: listings)
        )

        let fullRoot = full.trees[0], slimRoot = dirsOnly.trees[0]
        XCTAssertEqual(slimRoot.children.map(\.name), ["sub"], "只剩目录子节点")
        XCTAssertTrue(slimRoot.children[0].children.isEmpty)
        XCTAssertEqual(fullRoot.children.map(\.name), ["a.bin", "sub"], "默认形状不变(02 票的树)")
        XCTAssertEqual(slimRoot.accountedBytes, fullRoot.accountedBytes)
        XCTAssertEqual(slimRoot.reclaimableBytes, fullRoot.reclaimableBytes)
        XCTAssertEqual(slimRoot.fallbackBytes, fullRoot.fallbackBytes)
        XCTAssertEqual(slimRoot.fileCount, fullRoot.fileCount)
        XCTAssertEqual(slimRoot.directoryCount, fullRoot.directoryCount)
        XCTAssertEqual(slimRoot.symlinkCount, fullRoot.symlinkCount)
        XCTAssertEqual(slimRoot.datalessCount, fullRoot.datalessCount)
        XCTAssertEqual(slimRoot.allReclaimableAccounting, fullRoot.allReclaimableAccounting)
        XCTAssertEqual(dirsOnly.stats, full.stats)
    }

    // MARK: 树内定位(白名单匹配器的入口)

    /// mtime 聚合口径(05):`newestChangeEpoch` = **本目录直属文件**的最大 mtime,
    /// 不向父级传播(产物排除靠匹配器逐层取值,聚合反而会把产物 mtime 卷进项目年龄)。
    func testNewestChangeEpochAggregatesOwnFilesOnly() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("root-old.bin", allocated: 512, reclaimable: 512, modified: 100.0),
                CleanFixture.file("root-new.bin", allocated: 512, reclaimable: 512, modified: 300.5),
                CleanFixture.directory("sub", fileID: 401),
            ]),
            "/r/sub": .entries([
                CleanFixture.file("sub-file.bin", allocated: 512, reclaimable: 512, modified: 200.0),
            ]),
        ])
        let result = await engine.scan(
            SpaceScanOptions(roots: ["/r"], retainFileNodes: false),
            using: fs
        )
        let root = result.trees[0]
        XCTAssertEqual(root.newestChangeEpoch, 300.5, "直属文件取最大,含小数纳秒")
        XCTAssertEqual(root.children[0].newestChangeEpoch, 200.0, "子目录的直属文件归子目录")
        // 无 mtime 的文件不伪造(nil 保持 nil)。
        let fs2 = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("a.bin", allocated: 512, reclaimable: 512)]),
        ])
        let result2 = await engine.scan(SpaceScanOptions(roots: ["/r"]), using: fs2)
        XCTAssertNil(result2.trees[0].newestChangeEpoch)
    }

    // MARK: 并行内核(性能票:串行↔并行等价、去重语义、取消)

    /// 扁平化树成「路径 → 账目」便于与串行产物逐位对比(子节点顺序由入口序决定,
    /// 并行下同样按入口序拼装,理论全等;对比聚合更稳)。
    private struct FlatAccount: Equatable {
        var bytes: Int64
        var files: Int
        var dirs: Int
        var partial: Bool
    }

    private func flatten(_ node: SpaceNode, into map: inout [String: FlatAccount]) {
        map[node.path] = FlatAccount(
            bytes: node.accountedBytes,
            files: node.fileCount,
            dirs: node.directoryCount,
            partial: node.isPartial
        )
        for child in node.children {
            flatten(child, into: &map)
        }
    }

    private func parallelFixture() -> FakeCleanDirectoryEnumerator {
        // 三层、多分枝、含跨目录硬链接(同 dev+fileID)与 firmlink 双路径(同身份目录)。
        FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("root.bin", allocated: 512, reclaimable: 512),
                CleanFixture.directory("a", fileID: 501),
                CleanFixture.directory("b", fileID: 502),
                CleanFixture.directory("dup", fileID: 501), // 与 a 同身份:双访跳过
            ]),
            "/r/a": .entries([
                CleanFixture.file("shared.bin", allocated: 1024, reclaimable: 1024, device: 16_777_229, fileID: 9001),
                CleanFixture.directory("deep", fileID: 511),
            ]),
            "/r/a/deep": .entries([
                CleanFixture.file("d.bin", allocated: 256, reclaimable: 256),
            ]),
            "/r/b": .entries([
                // 硬链接到 /r/a/shared.bin:同 (dev, fileID) 只计一次
                CleanFixture.file("shared.bin", allocated: 1024, reclaimable: 1024, device: 16_777_229, fileID: 9001),
                CleanFixture.file("b1.bin", allocated: 128, reclaimable: 128),
            ]),
        ])
    }

    func testParallelScanProducesIdenticalTreeAndStatsAsSerial() async {
        let serial = await engine.scan(
            SpaceScanOptions(roots: ["/r"], retainFileNodes: false),
            using: parallelFixture()
        )
        let parallel = await engine.scan(
            SpaceScanOptions(roots: ["/r"], retainFileNodes: false, maxConcurrency: 4),
            using: parallelFixture()
        )

        var serialFlat: [String: FlatAccount] = [:]
        var parallelFlat: [String: FlatAccount] = [:]
        for tree in serial.trees {
            flatten(tree, into: &serialFlat)
        }
        for tree in parallel.trees {
            flatten(tree, into: &parallelFlat)
        }
        XCTAssertEqual(serialFlat.keys, parallelFlat.keys)
        for (path, serialEntry) in serialFlat {
            XCTAssertEqual(parallelFlat[path], serialEntry, "路径 \(path) 的账目并行/串行不一致")
        }

        // 汇总口径逐字段相等(去重计数也是确定性总量,与先后无关)。
        XCTAssertEqual(parallel.stats.entriesSeen, serial.stats.entriesSeen)
        XCTAssertEqual(parallel.stats.files, serial.stats.files)
        XCTAssertEqual(parallel.stats.directories, serial.stats.directories)
        XCTAssertEqual(parallel.stats.hardlinkSkips, serial.stats.hardlinkSkips)
        XCTAssertEqual(parallel.stats.doubleVisitSkips, serial.stats.doubleVisitSkips)
        XCTAssertEqual(parallel.stats.accountedBytes, serial.stats.accountedBytes)
        XCTAssertFalse(parallel.cancelled)

        // 语义锚:硬链接 1 次、双访 1 次、文件 4 个(root/shared/deep/b1)。
        XCTAssertEqual(parallel.stats.files, 4)
        XCTAssertEqual(parallel.stats.hardlinkSkips, 1)
        XCTAssertEqual(parallel.stats.doubleVisitSkips, 1)
        XCTAssertFalse(parallelFlat.keys.contains("/r/dup"), "同身份目录不重复入树")
    }

    func testParallelScanCancelKeepsPartialTree() async {
        // 取消在首目录即触发:产出标记 cancelled、根保留为空 partial(与旧实现同义)。
        let cancelledResult = await engine.scan(
            SpaceScanOptions(roots: ["/r"], retainFileNodes: false, maxConcurrency: 4),
            using: parallelFixture(),
            isCancelled: { true }
        )
        XCTAssertTrue(cancelledResult.cancelled)
        XCTAssertEqual(cancelledResult.trees.count, 1, "取消也保留(空 partial)根节点")
        XCTAssertTrue(cancelledResult.trees[0].isPartial)
        XCTAssertTrue(cancelledResult.trees[0].children.isEmpty, "取消点之后不再枚举")
    }

    /// 双路径域(方案 A 路径域修正):物理根喂枚举器,树路径落规范前缀;
    /// 台账错误路径保留物理(诊断)。
    func testCanonicalRootsPutTreePathsInUserDomain() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/System/Volumes/Data": .entries([
                CleanFixture.directory("Users", fileID: 601),
            ]),
            "/System/Volumes/Data/Users": .entries([
                CleanFixture.directory("me", fileID: 602),
                CleanFixture.directory("locked", fileID: 603),
            ]),
            "/System/Volumes/Data/Users/me": .entries([
                CleanFixture.file("a.bin", allocated: 512, reclaimable: 512),
            ]),
            "/System/Volumes/Data/Users/locked": .failure(.permissionDenied),
        ])
        let result = await engine.scan(
            SpaceScanOptions(roots: ["/System/Volumes/Data"], canonicalRoots: ["/"]),
            using: fs
        )
        // 枚举走物理路径
        let meCount = await fs.requestedPathCount("/System/Volumes/Data/Users/me")
        XCTAssertGreaterThan(meCount, 0, "枚举器收到物理路径")
        // 树路径是规范域:定位 /Users/me 直接命中(匹配器/排除的同域前提)
        XCTAssertNotNil(SpaceNode.locate(path: "/Users/me", in: result.trees))
        XCTAssertEqual(result.trees[0].path, "/")
        // 台账错误用物理路径(诊断要看真路径)
        XCTAssertTrue(result.ledger.contains { $0.path == "/System/Volumes/Data/Users/locked" })
    }

    func testDescendantLocatesDirectoryByPath() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/Users": .entries([CleanFixture.directory("t", fileID: 11)]),
            "/Users/t": .entries([CleanFixture.directory("Library", fileID: 12), CleanFixture.file("Library.txt")]),
            "/Users/t/Library": .entries([CleanFixture.directory("Caches", fileID: 13)]),
        ])
        let trees = await engine.scan(SpaceScanOptions(roots: ["/Users"]), using: fs).trees

        XCTAssertEqual(SpaceNode.locate(path: "/Users/t/Library/Caches/", in: trees)?.path, "/Users/t/Library/Caches")
        XCTAssertEqual(SpaceNode.locate(path: "/Users", in: trees)?.name, "Users")
        XCTAssertNil(SpaceNode.locate(path: "/Users/t/Library.txt", in: trees), "文件不是目录节点")
        XCTAssertNil(SpaceNode.locate(path: "/Users/t/Nope", in: trees))
        XCTAssertNil(SpaceNode.locate(path: "/Volumes/x", in: trees), "不在任何根之下")
    }
}

// MARK: - 测试小件(Sendable 计数器 / 收集器;NSLock 同步域,锁内无 await——并发纪律)

final class LockedCounter: @unchecked Sendable {
    // @unchecked 前提:唯一可变状态 v 由 NSLock 串行化,increment/读取全在锁内。
    private let lock = NSLock()
    private var v = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        v += 1
        return v
    }
}

final class LockedValue<T>: @unchecked Sendable {
    // @unchecked 前提:数组由 NSLock 串行化;T 仅作不可变载荷存取。
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    func load() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
