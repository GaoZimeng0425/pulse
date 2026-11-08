@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 删前复核(p5-cleaner/03,spec §15):五态判定、人话原因、执行器闸、快照管线
/// (引擎 → 缓存 v3 → 候选)、卸载残留同闸。全 spy / 夹具,零真盘零真删。
final class PreDeleteCheckTests: XCTestCase {
    // MARK: 判定表

    func testVerdictTable() {
        XCTAssertEqual(PreDeleteCheck.verdict(snapshot: 100.5, current: .present(modifiedEpoch: 100.5)), .unchanged)
        XCTAssertEqual(PreDeleteCheck.verdict(snapshot: nil, current: .present(modifiedEpoch: 100.5)), .noSnapshot)
        XCTAssertEqual(PreDeleteCheck.verdict(snapshot: 100.5, current: .present(modifiedEpoch: 101.5)), .changed)
        XCTAssertEqual(PreDeleteCheck.verdict(snapshot: 100.5, current: .missing), .missing)
        XCTAssertEqual(PreDeleteCheck.verdict(snapshot: 100.5, current: .unreadable), .unreadable)
        // 亚微秒级浮点尾差在容差内(同一 inode 值、两种读取路径的表示层差异)。
        XCTAssertEqual(
            PreDeleteCheck.verdict(snapshot: 100.5, current: .present(modifiedEpoch: 100.5 + 5e-7)),
            .unchanged
        )
    }

    func testEveryVerdictHasHumanReasonExceptUnchanged() {
        for origin in [PreDeleteCheck.Origin.scan, .leftoverProbe] {
            XCTAssertNil(PreDeleteCheck.skipReason(.unchanged, origin: origin))
            for verdict in [
                PreDeleteCheck.Verdict.changed, .missing, .noSnapshot, .unreadable,
            ] {
                let reason = PreDeleteCheck.skipReason(verdict, origin: origin)
                XCTAssertTrue(reason?.contains("跳过") == true, "\(verdict)/\(origin) 的人话必须说明已跳过")
            }
        }
    }

    func testPartitionKeepsOrderAndReportsSkips() async {
        let cleared: [String] = ["a", "c"]
        let result = await PreDeleteCheck.partition(
            ["a", "b", "c"],
            path: { $0 },
            snapshot: { _ in 1 },
            origin: .scan,
            currentState: { path in
                path == "b" ? .present(modifiedEpoch: 2) : .present(modifiedEpoch: 1)
            }
        )
        XCTAssertEqual(result.cleared, cleared, "放行项保持输入顺序")
        XCTAssertEqual(Array(result.skipped.keys), ["b"])
        XCTAssertEqual(result.skipped["b"], PreDeleteCheck.skipReason(.changed, origin: .scan))
    }

    // MARK: 扫描快照管线:引擎 → 候选

    func testEngineCarriesDirectoryOwnMtimeFromParentListing() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("f.bin", allocated: 512, reclaimable: 512, modified: 100),
                CleanFixture.directory("sub", fileID: 401, modified: 555.25),
                CleanFixture.directory("noMtime", fileID: 402, modified: nil),
            ]),
            "/r/sub": .entries([
                CleanFixture.file("g.bin", allocated: 512, reclaimable: 512, modified: 200),
            ]),
            "/r/noMtime": .entries([]),
        ])
        let result = await SpaceScanEngine().scan(
            SpaceScanOptions(roots: ["/r"], retainFileNodes: false),
            using: fs
        )
        let sub = result.trees[0].children.first { $0.name == "sub" }
        XCTAssertEqual(sub?.ownModifiedEpoch, 555.25, "目录自身 mtime 来自父目录列表条目")
        XCTAssertNil(
            result.trees[0].children.first { $0.name == "noMtime" }?.ownModifiedEpoch,
            "枚举器没给 = nil,不伪造"
        )
        XCTAssertNil(result.trees[0].ownModifiedEpoch, "扫描根没有父列表 = nil")
    }

    func testCandidatesCarrySnapshotAcrossAllThreeGroups() {
        // 同一棵夹具树喂三个规则域:工具缓存(JunkMatcher)+ 孤儿(InstalledAppInventory 空集)
        // + 项目产物(树里造不出 marker,退为只验证缓存域与孤儿域——产物域走单测直查)。
        let home = "/Users/me"
        let cacheNode = SpaceNode(
            name: "Homebrew", path: home + "/Library/Caches/Homebrew", kind: .directory,
            accountedBytes: 100, ownModifiedEpoch: 111.0
        )
        let orphanNode = SpaceNode(
            name: "com.gone.app", path: home + "/Library/Caches/com.gone.app", kind: .directory,
            accountedBytes: 200, newestChangeEpoch: 1, ownModifiedEpoch: 222.0
        )
        let caches = SpaceNode(
            name: "Caches", path: home + "/Library/Caches", kind: .directory,
            accountedBytes: 300, children: [cacheNode, orphanNode]
        )
        let library = SpaceNode(
            name: "Library", path: home + "/Library", kind: .directory,
            accountedBytes: 300, children: [caches]
        )
        let tree = SpaceNode(
            name: "me", path: home, kind: .directory, accountedBytes: 300, children: [library]
        )
        let global = JunkMatcher.candidates(in: [tree], home: home, excludedPathPrefixes: [])
        XCTAssertEqual(global.first?.modifiedAtScan, 111.0, "工具缓存候选带节点快照")

        let orphans = OrphanLeftoverDetector.detect(
            in: [tree], home: home, installedBundleIDs: [], excludedPathPrefixes: [], now: 1_700_000_000
        )
        XCTAssertEqual(orphans.first?.modifiedAtScan, 222.0, "孤儿候选带节点快照")

        let artifacts = ProjectArtifactMatcher.artifacts(
            in: [tree], roots: [home], excludedPathPrefixes: [], fileExists: { _ in true }
        )
        XCTAssertTrue(
            artifacts.allSatisfy { $0.modifiedAtScan != nil || $0.group != .projectArtifacts },
            "项目产物候选(命中时)同样带快照"
        )
    }

    // MARK: 缓存 v3:快照往返 + v2 兼容读

    private func payloadWithSnapshots() -> SpaceScanCachePayload {
        let child = SpaceNode(
            name: "Homebrew", path: "/Users/me/Library/Caches/Homebrew", kind: .directory,
            accountedBytes: 100, ownModifiedEpoch: 123.5
        )
        let parent = SpaceNode(
            name: "Caches", path: "/Users/me/Library/Caches", kind: .directory,
            accountedBytes: 100, ownModifiedEpoch: 456.25, children: [child]
        )
        let tree = SpaceNode(
            name: "me", path: "/Users/me", kind: .directory,
            accountedBytes: 100, children: [parent]
        )
        return SpaceScanCachePayload(
            meta: SpaceScanMeta(
                startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
                roots: ["/Users/me"], excludedPathPrefixes: []
            ),
            result: SpaceScanResult(trees: [tree], ledger: [], stats: ScanStats(), cancelled: false)
        )
    }

    func testCacheV3RoundTripsOwnModifiedEpoch() throws {
        let payload = payloadWithSnapshots()
        let decoded = try XCTUnwrap(SpaceScanCache.decode(SpaceScanCache.encode(payload)))
        let caches = try XCTUnwrap(decoded.result.trees[0].children.first { $0.name == "Caches" })
        XCTAssertEqual(caches.ownModifiedEpoch, 456.25)
        XCTAssertEqual(caches.children[0].ownModifiedEpoch, 123.5)
        XCTAssertNil(decoded.result.trees[0].ownModifiedEpoch, "没快照的节点往返后仍是 nil")
    }

    func testCacheV2BytesStillDecodeWithNilSnapshots() throws {
        /// v3 是 v2 的严格超集:差别只有节点 flags 的 0b1000 位与随后的 f64。同一棵**无快照**
        /// 的树,v3 编码器的产出与 v2 编码器逐字节相同(版本字节除外)——把版本改回 2 就是
        /// 一份真实的 v2 文件。旧缓存必须照常解出(用户不必重扫才能看清单),快照为 nil
        /// (删除时按「缺少扫描快照」跳过,fail-closed)。
        func stripped(_ node: SpaceNode) -> SpaceNode {
            var copy = node
            copy.ownModifiedEpoch = nil
            copy.children = node.children.map(stripped)
            return copy
        }
        var payload = payloadWithSnapshots()
        payload.result.trees = payload.result.trees.map(stripped)
        var bytes = SpaceScanCache.encode(payload)
        XCTAssertEqual(bytes[4], 3, "前提:魔数后 u32 小端版本号,当前 v3")
        bytes[4] = 2

        let decoded = try XCTUnwrap(SpaceScanCache.decode(bytes), "v2 文件必须照常解出")
        let caches = try XCTUnwrap(decoded.result.trees[0].children.first { $0.name == "Caches" })
        XCTAssertNil(caches.ownModifiedEpoch)
        XCTAssertNil(caches.children[0].ownModifiedEpoch)
        XCTAssertEqual(caches.children[0].accountedBytes, 100, "其余字段照常")

        bytes[4] = 99
        XCTAssertNil(SpaceScanCache.decode(bytes), "不认识的版本 = nil(回空态,不误读)")
    }

    // MARK: 卸载残留同闸

    func testUninstallSkipsChangedLeftoverButStillRemovesAppAndOthers() async {
        let home = NSHomeDirectory()
        let good = AppLeftoverRow(
            path: home + "/Library/Caches/com.demo", site: .caches, matchKey: "k",
            source: .generic, sizeBytes: 50, modifiedAtProbe: 100
        )
        let touched = AppLeftoverRow(
            path: home + "/Library/Logs/com.demo", site: .logs, matchKey: "k",
            source: .generic, sizeBytes: 30, modifiedAtProbe: 100
        )
        let plan = AppUninstallPlan(
            appPath: "/Applications/Demo.app", appName: "Demo", appBytes: 1000,
            caskName: nil, permanent: false, leftoverItems: [good, touched]
        )
        let recycled = ["/Applications/Demo.app", good.path]
        let termination = await AppUninstallRunner.run(
            plan,
            recycle: { _ in
                TrashRecycleOutcome(recycled: Dictionary(uniqueKeysWithValues: recycled.map {
                    ($0, home + "/.Trash/x")
                }))
            },
            deletePermanently: { _ in PermanentDeletionOutcome() },
            brewUninstall: { _, _ in .success },
            isAppRunning: { _ in false },
            crossCheckCask: { _ in nil },
            leftoverState: { path in
                path == touched.path ? .present(modifiedEpoch: 999) : .present(modifiedEpoch: 100)
            }
        )
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(report.items.map(\.path), ["/Applications/Demo.app", good.path, touched.path], "确认序不变")
        XCTAssertEqual(report.items[0].isRecycled, true, "app 本体不过闸:意图就是删它")
        XCTAssertEqual(report.items[1].isRecycled, true)
        XCTAssertEqual(
            report.items[2].outcome,
            .failed(reason: PreDeleteCheck.skipReason(.changed, origin: .leftoverProbe) ?? "")
        )
        XCTAssertEqual(report.freedBytes, 1050)
    }

    func testBrewZapOwnBatchStillVerified() async {
        // brew --zap:声明域照 .brew 记;未覆盖的残留走我们直删批次——变动即跳过。
        let home = NSHomeDirectory()
        let declared = AppLeftoverRow(
            path: home + "/Library/Application Support/com.demo", site: .applicationSupport,
            matchKey: "k", source: .generic, sizeBytes: 10, modifiedAtProbe: 100
        )
        let touched = AppLeftoverRow(
            path: home + "/Library/Logs/com.demo", site: .logs, matchKey: "k",
            source: .generic, sizeBytes: 20, modifiedAtProbe: 100
        )
        let plan = AppUninstallPlan(
            appPath: "/Applications/Demo.app", appName: "Demo", appBytes: 1000,
            caskName: "demo", permanent: true,
            leftoverItems: [declared, touched],
            receiptZapPaths: [declared.path]
        )
        let deletedBox = PathsBox()
        var deletedPaths: [[String]] {
            deletedBox.values
        }
        let termination = await AppUninstallRunner.run(
            plan,
            recycle: { _ in TrashRecycleOutcome() },
            deletePermanently: { paths in
                await deletedBox.append(paths)
                return PermanentDeletionOutcome(deleted: Set(paths))
            },
            brewUninstall: { _, _ in .success },
            isAppRunning: { _ in false },
            crossCheckCask: { _ in nil },
            leftoverState: { path in
                path == touched.path ? .present(modifiedEpoch: 999) : .present(modifiedEpoch: 100)
            }
        )
        guard case let .completed(report) = termination else {
            return XCTFail("应完成,得到 \(termination)")
        }
        XCTAssertEqual(deletedPaths, [], "直删批次全被闸拦 = 零调用")
        XCTAssertEqual(report.items[1].outcome, .permanentlyDeleted(route: .brew), "声明域照 .brew 记(brew 内部,不过闸)")
        XCTAssertEqual(
            report.items[2].outcome,
            .failed(reason: PreDeleteCheck.skipReason(.changed, origin: .leftoverProbe) ?? "")
        )
    }
}

/// 跨 @Sendable 闭包记批次用。
private actor PathsBox {
    var values: [[String]] = []

    func append(_ batch: [String]) {
        values.append(batch)
    }
}
