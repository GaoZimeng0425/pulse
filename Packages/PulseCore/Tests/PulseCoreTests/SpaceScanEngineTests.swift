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
