@testable import Pulse
import PulseCore
import XCTest

/// 清理页状态机(p4-cleaner/03):生命周期 / 结果缓存 / FDA 判据来自台账 /
/// 重扫替换。枚举器走协议注入(TestSupport 假实现)——零真盘、零等待真扫描。
@MainActor
final class CleanerModelTests: XCTestCase {
    func testScanFinishesAndCachesResultWithFDAHint() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("a.bin", allocated: 512, reclaimable: 512),
                CleanFixture.directory("sub", fileID: 9),
                CleanFixture.directory("locked", fileID: 10),
            ]),
            "/r/sub": .entries([CleanFixture.file("b.bin", allocated: 256, reclaimable: 256)]),
            "/r/locked": .failure(.tccDenied),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])

        await waitUntil { !model.isScanning }

        guard case let .finished(result) = model.phase else {
            XCTFail("应到 finished,实际 \(model.phase)")
            return
        }
        XCTAssertEqual(result.stats.files, 2)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(model.permissionDeniedCount, 1)
        XCTAssertTrue(model.permissionHint?.contains("1 个目录") == true, "FDA 判据来自台账,非预探测")
        // 结果缓存:不重扫 phase 不变,重进 tab 沿用
        XCTAssertEqual(model.result?.stats.files, 2)
        XCTAssertNotNil(model.scanFinishedAt)
    }

    func testRescanReplacesResult() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("v1.bin", allocated: 128, reclaimable: 128)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertEqual(model.result?.stats.files, 1)

        await fake.set("/r", .entries([
            CleanFixture.file("v2a.bin", allocated: 128, reclaimable: 128),
            CleanFixture.file("v2b.bin", allocated: 128, reclaimable: 128),
        ]))
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(model.result?.stats.files, 2, "重扫替换旧结果")
    }

    /// root/他属主目录(EACCES)不该出「去授权」横幅——FDA 帮不了它们,
    /// 引导是误导(2026-11-03 拆分后横幅只认 TCC 的 EPERM)。
    func testUnixPermissionDeniedDoesNotShowAuthorizationBanner() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("a.bin", allocated: 512, reclaimable: 512),
                CleanFixture.directory("root-owned", fileID: 900),
            ]),
            "/r/root-owned": .failure(.permissionDenied),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertEqual(model.permissionDeniedCount, 0, "EACCES 不进 TCC 计数")
        XCTAssertNil(model.permissionHint)
        XCTAssertTrue(model.result?.ledger.contains { $0.reason == .permissionDenied } == true, "台账里如实保留")
    }

    /// 零权限失败 → 无 FDA 横幅(不骚扰)。
    func testNoHintWhenNoPermissionFailures() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("a.bin", allocated: 64, reclaimable: 64)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertNil(model.permissionHint)
    }

    // MARK: 删除管线(p4-cleaner/04)——清单 → 勾选 → 确认 → spy 执行 → 历史 → 清单收敛

    private let home = "/Users/test"

    private func makeHomeEnumerator(extra: [String: Int64] = [:]) -> FakeCleanDirectoryEnumerator {
        var dirs: [String: Int64] = [
            "Library/Developer/Xcode/DerivedData": 28_000_000,
            "Library/Caches/Homebrew": 3_100_000,
            "Documents/DerivedData": 9_999_000, // 似是而非:不在白名单
        ]
        dirs.merge(extra) { _, new in new }
        return FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(home: home, directories: dirs))
    }

    private func waitForCleanFinished(_ model: CleanerModel) async {
        await waitUntil {
            if case .finished = model.cleanPhase {
                true
            } else {
                false
            }
        }
    }

    /// 整条竖井:白名单清单(似是而非不出现)、默认全不勾、确认后 spy 收到恰好选中的路径、
    /// 历史落库与清单内容一致、已回收项从清单消失、勾选收敛。
    func testCleanPipelineEndToEndWithSpyAndInMemoryHistory() async throws {
        let derivedPath = home + "/Library/Developer/Xcode/DerivedData"
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [derivedPath: home + "/.Trash/DerivedData"]
        ))
        let history = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let model = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            history: history,
            trash: spy,
            homeDirectory: home
        )
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(
            model.candidates.map(\.ruleID),
            ["xcode.derivedData", "homebrew.cache"],
            "似是而非的 Documents/DerivedData 不出现"
        )
        XCTAssertTrue(model.selection.isEmpty, "默认全不勾")
        XCTAssertTrue(model.plan.isEmpty)
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .idle, "没选东西就没有确认清单")

        let derived = model.candidates[0]
        model.toggle(derived)
        XCTAssertTrue(model.isSelected(derived))
        XCTAssertEqual(model.plan.items.map(\.path), [derivedPath])
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .confirming)
        model.confirmClean()
        await waitForCleanFinished(model)

        guard case let .finished(report, historyRecorded) = model.cleanPhase else {
            XCTFail("应到 finished,实际 \(model.cleanPhase)")
            return
        }
        XCTAssertTrue(historyRecorded)
        XCTAssertEqual(report.freedBytes, 28_000_000)
        XCTAssertTrue(report.failed.isEmpty)
        let calls = await spy.recycleCalls
        XCTAssertEqual(calls, [[derivedPath]], "spy 收到恰好选中的那一条,绝不多")
        XCTAssertEqual(model.candidates.map(\.ruleID), ["homebrew.cache"], "已回收项不再列")
        XCTAssertTrue(model.selection.isEmpty, "勾选随清单收敛")
        XCTAssertEqual(model.recycledPaths, [derivedPath])

        let runs = try await history.runs()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].freedBytes, 28_000_000)
        let items = try await history.items(runID: runs[0].id)
        XCTAssertEqual(items.map(\.path), [derivedPath], "历史写入与清单内容一致")
        XCTAssertEqual(items[0].outcome, .recycled(destination: home + "/.Trash/DerivedData"))

        await model.loadHistory()
        XCTAssertEqual(model.historyRuns?.count, 1)
        await model.loadHistoryItems(runID: runs[0].id)
        XCTAssertEqual(model.historyItems[runs[0].id]?.count, 1)

        model.dismissCleanReport()
        XCTAssertEqual(model.cleanPhase, .idle)
    }

    /// 失败项如实报:仍留在清单里(没进废纸篓),战报与历史都记失败原因。
    func testFailedItemsStayListedAndAreReported() async throws {
        let derivedPath = home + "/Library/Developer/Xcode/DerivedData"
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            failures: [derivedPath: "Operation not permitted"]
        ))
        let history = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let model = CleanerModel(history: history, trash: spy, homeDirectory: home)
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        model.toggle(model.candidates[0])
        model.requestClean()
        model.confirmClean()
        await waitForCleanFinished(model)

        guard case let .finished(report, _) = model.cleanPhase else {
            XCTFail("应到 finished")
            return
        }
        XCTAssertEqual(report.failed.map(\.path), [derivedPath])
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertTrue(model.candidates.contains { $0.path == derivedPath }, "没删掉的仍在清单")
        let runs = try await history.runs()
        let items = try await history.items(runID: runs[0].id)
        XCTAssertEqual(items[0].outcome, .failed(reason: "Operation not permitted"))
    }

    /// 历史库缺席:照常清理,战报标"未记录"。
    func testHistoryUnavailableStillCleans() async {
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [home + "/Library/Caches/Homebrew": home + "/.Trash/Homebrew"]
        ))
        let model = CleanerModel(history: nil, trash: spy, homeDirectory: home)
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        XCTAssertFalse(model.historyAvailable)
        model.toggle(model.candidates[1])
        model.requestClean()
        model.confirmClean()
        await waitForCleanFinished(model)

        guard case let .finished(report, historyRecorded) = model.cleanPhase else {
            XCTFail("应到 finished")
            return
        }
        XCTAssertFalse(historyRecorded)
        XCTAssertEqual(report.recycled.count, 1)
    }

    /// 右键排除:清单即时收窄(不重扫)、勾选脱落、持久化;再扫描该目录不被碰。
    func testExcludeNarrowsImmediatelyPersistsAndSkipsOnRescan() async throws {
        var persisted: [[String]] = []
        let exclusions = CleanExclusionsStore(load: { [] }, persist: { persisted.append($0) })
        let model = CleanerModel(exclusions: exclusions, trash: FakeCleanTrashExecutor(), homeDirectory: home)
        let fake = makeHomeEnumerator()
        model.startScan(using: fake, roots: [home])
        await waitUntil { !model.isScanning }
        let homebrew = try XCTUnwrap(model.candidates.first { $0.ruleID == "homebrew.cache" })
        model.toggle(homebrew)
        XCTAssertEqual(model.plan.items.count, 1)

        model.exclude(homebrew.path)

        XCTAssertEqual(model.candidates.map(\.ruleID), ["xcode.derivedData"], "排除立即生效,不必重扫")
        XCTAssertTrue(model.plan.isEmpty, "被排除的项即使勾过也不进计划")
        XCTAssertEqual(persisted, [[homebrew.path]])
        XCTAssertEqual(model.excludedPathPrefixes, [homebrew.path])

        let requestsBefore = await fake.requestedPathCount(homebrew.path)
        model.startScan(using: fake, roots: [home])
        await waitUntil { !model.isScanning }
        let requestsAfter = await fake.requestedPathCount(homebrew.path)
        XCTAssertEqual(requestsAfter, requestsBefore, "重扫时排除目录不再被枚举(扫描侧生效)")
        XCTAssertEqual(model.candidates.map(\.ruleID), ["xcode.derivedData"])
    }

    func testCancelFromConfirmReturnsToIdle() async {
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), homeDirectory: home)
        model.startScan(using: makeHomeEnumerator(), roots: [home])
        await waitUntil { !model.isScanning }
        model.toggle(model.candidates[0])
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .confirming)
        model.cancelClean()
        XCTAssertEqual(model.cleanPhase, .idle)
        XCTAssertEqual(model.plan.items.count, 1, "取消确认不动勾选")
    }

    // MARK: 整组勾选(2026-10-30 拍板 B:只勾组内「可安全清理」项,先检查项单独勾)

    func testGroupToggleSelectsOnlySafeTierAndCyclesBack() async {
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), homeDirectory: home)
        model.startScan(
            using: makeHomeEnumerator(extra: ["Library/Caches/JetBrains": 5_400_000]),
            roots: [home]
        )
        await waitUntil { !model.isScanning }

        let safe = model.candidates.filter { $0.tier == .safe }
        let checkFirst = model.candidates.filter { $0.tier == .checkFirst }
        XCTAssertEqual(Set(safe.map(\.ruleID)), ["xcode.derivedData", "homebrew.cache"])
        XCTAssertEqual(checkFirst.map(\.ruleID), ["jetbrains.caches"])

        // none → 一键全勾:只勾 safe 档,先检查项不被带上
        XCTAssertEqual(model.groupState(of: safe), .none)
        model.toggleGroup(safe)
        XCTAssertEqual(model.groupState(of: safe), .all)
        XCTAssertEqual(model.plan.items.count, 2)
        XCTAssertFalse(model.plan.items.contains { $0.tier == .checkFirst }, "先检查项必须逐个手勾")

        // all → 一键全清:用户手勾的先检查项保留
        model.toggle(checkFirst[0])
        model.toggleGroup(safe)
        XCTAssertEqual(model.groupState(of: safe), .none)
        XCTAssertEqual(model.plan.items.map(\.ruleID), ["jetbrains.caches"], "组全清不碰组外的勾")

        // mixed(手勾一个再点组头)→ 全勾
        model.toggleGroup(safe)
        model.toggle(safe[0])
        XCTAssertEqual(model.groupState(of: safe), .mixed)
        model.toggleGroup(safe)
        XCTAssertEqual(model.groupState(of: safe), .all)
        XCTAssertEqual(model.plan.items.count, 3)
    }

    // MARK: 空间地图(07):显示树在扫描任务侧构建,firmlink 提升 + 密封折叠

    func testScanBuildsMapTreesWithHoistingAndSealedFold() async throws {
        // 真机树形复刻:Users 埋在 /System/Volumes/Data 之下(顶层 firmlink 被
        // double-visit 跳过),System 自有 SSV 文件 80。
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/": .entries([
                CleanFixture.directory("System", fileID: 100),
                CleanFixture.directory("bin", fileID: 101),
            ]),
            "/System": .entries([
                CleanFixture.file("ssv.bin", allocated: 80, reclaimable: 80),
                CleanFixture.directory("Volumes", fileID: 102),
            ]),
            "/System/Volumes": .entries([CleanFixture.directory("Data", fileID: 103)]),
            "/System/Volumes/Data": .entries([CleanFixture.directory("Users", fileID: 104)]),
            "/System/Volumes/Data/Users": .entries([
                CleanFixture.file("me.bin", allocated: 200, reclaimable: 200),
            ]),
            "/bin": .entries([CleanFixture.file("sh.bin", allocated: 4, reclaimable: 4)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/"])

        await waitUntil { !model.isScanning }

        guard case .finished = model.phase else {
            XCTFail("应到 finished,实际 \(model.phase)")
            return
        }
        let map = try XCTUnwrap(model.mapTrees.first)
        XCTAssertEqual(map.name, "整卷")
        let users = map.children.first { $0.name == "Users" }
        XCTAssertEqual(users?.path, "/Users", "被埋的 Users 拼回顶层 + 规范路径")
        XCTAssertEqual(users?.bytes, 200)
        let sealed = map.children.first { $0.isSealed }
        XCTAssertEqual(sealed?.name, "系统(密封)")
        XCTAssertEqual(sealed?.bytes, 80, "System 余量 = 自有 SSV 文件,Data 子树不计两次")
        XCTAssertEqual(map.children.first { $0.name == "bin" }?.isSealed, true, "/bin 密封只读")
    }

    // MARK: 项目产物 + 在用保护(05)

    private func makeProjectsModel(
        activity: FakeCleanActivitySource,
        trash: FakeCleanTrashExecutor = FakeCleanTrashExecutor()
    ) -> CleanerModel {
        CleanerModel(
            scanRoots: CleanScanRootsStore(load: { ["/Users/dev/code"] }, persist: { _ in }),
            trash: trash,
            activity: activity,
            homeDirectory: "/Users/dev",
            markerExists: { _ in true } // 本组测分组 / 年龄 / 在用,标记口径见 ProjectArtifactTests
        )
    }

    func testProjectArtifactsGroupedSortedAndAgeIgnoresReinstall() async {
        let oldAge = 1_700_000_000.0 - 40 * 86400
        let fake = FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(
            home: "/Users/dev",
            directories: [
                "code/old-app/node_modules": 8_000_000,
                "code/old-app/src": 10,
                "code/old-app/target": 3_000_000,
                "code/new-tool/node_modules": 1_500_000,
                "code/new-tool/src": 5,
            ],
            modifiedByDir: [
                "code/old-app/node_modules": 1_700_100_000, // 产物文件新(像刚重装过依赖)
                "code/old-app/src": oldAge,
                "code/old-app/target": 1_700_050_000,
                "code/new-tool/node_modules": 1_700_200_000,
                "code/new-tool/src": 1_700_200_000,
            ]
        ))
        let model = makeProjectsModel(activity: FakeCleanActivitySource())
        model.startScan(using: fake, roots: ["/Users/dev"])
        await waitUntil { !model.isScanning }

        let artifacts = model.candidates.filter { $0.group == .projectArtifacts }
        XCTAssertEqual(artifacts.map(\.path), [
            "/Users/dev/code/old-app/node_modules",
            "/Users/dev/code/old-app/target",
            "/Users/dev/code/new-tool/node_modules",
        ], "默认按大小,组内大到小")
        XCTAssertEqual(artifacts.first?.projectName, "/Users/dev/code/old-app")
        XCTAssertEqual(
            artifacts.first?.newestChangeEpoch.map { Int($0) },
            Int(oldAge),
            "年龄 = 项目源码的最后变动;产物自身 mtime 再新也不算(重装依赖不刷新年龄)"
        )

        model.artifactSort = .age
        let byAge = model.candidates.filter { $0.group == .projectArtifacts }
        XCTAssertEqual(byAge.map(\.projectName).first, "/Users/dev/code/old-app", "按新旧 = 最久未动在前")
        XCTAssertEqual(byAge.map(\.projectName).last, "/Users/dev/code/new-tool")
    }

    func testInUseProjectFilteredFromPlanWithFreshRecheck() async throws {
        let fake = FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(
            home: "/Users/dev",
            directories: [
                "code/old-app/node_modules": 8_000_000,
                "code/new-app/node_modules": 4_000_000,
            ]
        ))
        let oldPath = "/Users/dev/code/old-app/node_modules"
        let newPath = "/Users/dev/code/new-app/node_modules"
        let activity = FakeCleanActivitySource(entries: [])
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(recycled: [
            oldPath: "/Users/dev/.Trash/old",
            newPath: "/Users/dev/.Trash/new",
        ]))
        let model = makeProjectsModel(activity: activity, trash: spy)
        model.startScan(using: fake, roots: ["/Users/dev"])
        await waitUntil { !model.isScanning }

        let oldNM = try XCTUnwrap(model.candidates.first { $0.path == oldPath })
        let newNM = try XCTUnwrap(model.candidates.first { $0.path == newPath })
        XCTAssertNil(model.inUseReasons(for: oldNM), "无活动 = 不在用")

        model.toggle(oldNM)
        model.toggle(newNM)
        XCTAssertEqual(model.plan.items.count, 2)

        // 扫描后新开终端进项目(活动变化,不重扫):判定现查立即翻转——
        // 在用项目绝不进删除计划(展示仍如实灰列)。
        activity.entries = [CleanActivityEntry(path: "/Users/dev/code/old-app", reasons: [.terminal])]
        XCTAssertEqual(model.inUseReasons(for: oldNM), [.terminal])
        XCTAssertEqual(model.plan.items.map(\.path), [newPath], "计划此刻剔除在用项")
        XCTAssertEqual(model.candidates.count, 2, "清单仍展示在用行(灰显),只是不可勾")

        // 确认执行:只有不在用的那项真的去废纸篓。
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .confirming)
        model.confirmClean()
        await waitForCleanFinished(model)
        let calls = await spy.recycleCalls
        XCTAssertEqual(calls.map { Set($0) }, [Set([newPath])], "在用项绝不到执行器")
    }

    /// 清单快照(cleaner-hardening/05):重复读取不重跑匹配器(标记探测次数当计数器);
    /// 输入一变(排除目录)立即重算——设置页改动即时反映的语义不丢。
    func testCandidatesMemoizedUntilInputsChange() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func bump() {
                lock.withLock { count += 1 }
            }

            var value: Int {
                lock.withLock { count }
            }
        }
        let probes = Counter()
        let exclusions = CleanExclusionsStore(load: { [] }, persist: { _ in })
        let model = CleanerModel(
            exclusions: exclusions,
            scanRoots: CleanScanRootsStore(load: { ["/Users/dev/code"] }, persist: { _ in }),
            trash: FakeCleanTrashExecutor(),
            homeDirectory: "/Users/dev",
            markerExists: { _ in probes.bump()
                return true
            }
        )
        let fake = FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(
            home: "/Users/dev",
            directories: ["code/a/node_modules": 8_000_000, "code/b/node_modules": 4_000_000]
        ))
        model.startScan(using: fake, roots: ["/Users/dev"])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(model.candidates.count, 2)
        let afterFirst = probes.value
        for _ in 0 ..< 5 {
            _ = model.candidates
        }
        XCTAssertEqual(probes.value, afterFirst, "输入不变,重复读取不重算")

        exclusions.add("/Users/dev/code/a/node_modules")
        XCTAssertEqual(model.candidates.map(\.path), ["/Users/dev/code/b/node_modules"], "排除即时生效")
    }

    // MARK: 方案 A(票 10):默认根 = Data 卷 + 卷级密封注入

    func testDefaultScanRootIsDataVolumeWithSealedVolumeInjection() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/System/Volumes/Data": .entries([
                CleanFixture.directory("Users", fileID: 210),
            ]),
            "/System/Volumes/Data/Users": .entries([
                CleanFixture.file("me.bin", allocated: 200, reclaimable: 200),
            ]),
        ])
        let model = CleanerModel(
            volumeSummaries: {
                [SpaceMapVolumeSummary(label: "SSV", usedBytes: 80)]
            },
            homeDirectory: "/Users/me"
        )
        model.startScan(using: fake) // 不传 roots:生产默认 = Data 卷
        await waitUntil { !model.isScanning }

        guard let map = model.mapTrees.first else {
            XCTFail("应有显示树")
            return
        }
        XCTAssertEqual(map.path, "/")
        XCTAssertEqual(map.bytes, 280, "文件级 200 + 卷级密封 80")
        XCTAssertEqual(map.children.first { $0.name == "Users" }?.path, "/Users")
        XCTAssertEqual(map.children.first { $0.isSealed }?.bytes, 80)
    }

    // MARK: 方案 A 路径域修正(2026-11-02 实机回归:Data 根扫描后清单为空)

    func testCanonicalDataScanFindsJunkCandidatesForCanonicalHome() async {
        // 生产扫描 = Data 物理根 + 规范根 "/"。夹具按物理路径铺,规则/家目录按规范路径找:
        // 树路径与用户可见路径同域,白名单定位不再因前缀失配而空手而归。
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/System/Volumes/Data": .entries([
                CleanFixture.directory("Users", fileID: 700),
            ]),
            "/System/Volumes/Data/Users": .entries([
                CleanFixture.directory("me", fileID: 705),
            ]),
            "/System/Volumes/Data/Users/me": .entries([
                CleanFixture.directory("Library", fileID: 701),
            ]),
            "/System/Volumes/Data/Users/me/Library": .entries([
                CleanFixture.directory("Caches", fileID: 702),
            ]),
            "/System/Volumes/Data/Users/me/Library/Caches": .entries([
                CleanFixture.directory("Homebrew", fileID: 703),
            ]),
            "/System/Volumes/Data/Users/me/Library/Caches/Homebrew": .entries([
                CleanFixture.file("b.bin", allocated: 1_500_000, reclaimable: 1_500_000),
            ]),
        ])
        let model = CleanerModel(homeDirectory: "/Users/me")
        model.startScan(using: fake)
        await waitUntil { !model.isScanning }

        XCTAssertEqual(model.candidates.map(\.ruleID), ["homebrew.cache"], "规范域树 + 规范家目录:清单不再为空")
        XCTAssertEqual(model.candidates.first?.path, "/Users/me/Library/Caches/Homebrew")
    }

    /// 亚兆候选照列(2026-11-06 用户拍板:0 KB 的产物/缓存也是该清的东西;
    /// 曾误加 <1MB 上榜下限,同日撤销——显示层走 memory() KB 档给真实读数)。
    func testSubMegabyteCandidatesStillListed() async {
        let fake = FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(
            home: home,
            directories: [
                "Library/Developer/Xcode/DerivedData": 28_000_000,
                "Library/Caches/Homebrew": 400_000, // 亚兆:照列
            ]
        ))
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), homeDirectory: home)
        model.startScan(using: fake, roots: [home])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(
            model.candidates.map(\.ruleID),
            ["xcode.derivedData", "homebrew.cache"],
            "亚兆条目不上榜的旧下限不得回潮"
        )
    }

    // MARK: 扫描结果落盘缓存(p4-cleaner/11)

    private func makeCacheFixture() -> FakeCleanDirectoryEnumerator {
        // 物理域铺 Data 根(canonical 模式),规范域断言清单
        FakeCleanDirectoryEnumerator(listings: [
            "/System/Volumes/Data": .entries([
                CleanFixture.directory("Users", fileID: 800),
            ]),
            "/System/Volumes/Data/Users": .entries([
                CleanFixture.directory("me", fileID: 801),
            ]),
            "/System/Volumes/Data/Users/me": .entries([
                CleanFixture.directory("Library", fileID: 802),
            ]),
            "/System/Volumes/Data/Users/me/Library": .entries([
                CleanFixture.directory("Caches", fileID: 803),
            ]),
            "/System/Volumes/Data/Users/me/Library/Caches": .entries([
                CleanFixture.directory("Homebrew", fileID: 804),
            ]),
            "/System/Volumes/Data/Users/me/Library/Caches/Homebrew": .entries([
                CleanFixture.file("b.bin", allocated: 1_500_000, reclaimable: 1_500_000),
            ]),
        ])
    }

    func testScanResultSurvivesRelaunchViaCache() async {
        // 内存"文件":锁保护的盒子模拟落盘/重启(Sendable 闭包捕获得体)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var payload: SpaceScanCachePayload?
            var value: SpaceScanCachePayload? {
                get { lock.lock()
                    defer { lock.unlock() }
                    return payload
                }
                set { lock.lock()
                    defer { lock.unlock() }
                    payload = newValue
                }
            }
        }
        let box = Box()
        let cache = CleanScanResultStore(load: { box.value }, save: { box.value = $0 })

        // 第一次会话:扫描 → 落盘
        let first = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        first.startScan(using: makeCacheFixture())
        await waitUntil { !first.isScanning }
        XCTAssertEqual(first.candidates.map(\.ruleID), ["homebrew.cache"])
        XCTAssertNotNil(box.value, "扫完即落盘")

        // 第二次会话(新模型 = 关窗/重启语义):空态装载缓存 → 结果复活
        let second = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        second.loadCachedScan()
        await waitUntil { second.result != nil }
        XCTAssertTrue(second.loadedFromCache)
        XCTAssertEqual(second.candidates.map(\.ruleID), ["homebrew.cache"], "清单从缓存复活(路径域一致)")
        XCTAssertEqual(second.candidates.first?.path, "/Users/me/Library/Caches/Homebrew")
        XCTAssertNil(second.cacheStalenessHint, "配置未变,无过期提示")
        XCTAssertNotNil(second.mapTrees.first, "地图同样复活")

        // 重扫:缓存态复位,结果照常刷新
        second.startScan(using: makeCacheFixture())
        await waitUntil { !second.isScanning && !second.loadedFromCache }
        XCTAssertFalse(second.loadedFromCache)
    }

    /// 取消的扫描是半棵树:不得覆盖上一份完整缓存(cleaner-hardening/04)。
    func testCancelledScanDoesNotOverwriteCache() async {
        final class SaveCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func bump() {
                lock.withLock { count += 1 }
            }

            var value: Int {
                lock.withLock { count }
            }
        }
        // 每进一个目录慢 50ms:保证取消落在扫描中途。
        actor SlowEnumerator: CleanDirectoryEnumerator {
            let inner: FakeCleanDirectoryEnumerator
            init(_ inner: FakeCleanDirectoryEnumerator) {
                self.inner = inner
            }

            func entries(ofDirectory path: String) async throws -> [FsEntrySnapshot] {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return try await inner.entries(ofDirectory: path)
            }
        }
        let saves = SaveCounter()
        let cache = CleanScanResultStore(load: { nil }, save: { _ in saves.bump() })
        let model = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        model.startScan(using: SlowEnumerator(makeCacheFixture()))
        model.cancelScan()
        await waitUntil { !model.isScanning }
        XCTAssertEqual(saves.value, 0, "取消的扫描不落盘")
    }

    func testCacheStalenessHintWhenExclusionsChangedAfterScan() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var payload: SpaceScanCachePayload?
            var value: SpaceScanCachePayload? {
                get { lock.lock()
                    defer { lock.unlock() }
                    return payload
                }
                set { lock.lock()
                    defer { lock.unlock() }
                    payload = newValue
                }
            }
        }
        let box = Box()
        let cache = CleanScanResultStore(load: { box.value }, save: { box.value = $0 })
        let first = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        first.startScan(using: makeCacheFixture())
        await waitUntil { !first.isScanning }
        XCTAssertNotNil(box.value)

        // 新会话:排除清单与扫描时不同 → 过期提示(数字只可能偏大方向)
        let second = CleanerModel(
            exclusions: CleanExclusionsStore(
                load: { ["/Users/me/Library/Caches/Homebrew"] },
                persist: { _ in }
            ),
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        second.loadCachedScan()
        await waitUntil { second.result != nil }
        XCTAssertNotNil(second.cacheStalenessHint, "排除配置变了要提示建议重扫")

        // 没有缓存的模型不落盘也不装载(旧测试路径零影响)
        let bare = CleanerModel(homeDirectory: "/Users/me")
        bare.loadCachedScan()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(bare.result, "无缓存 store:装载零动作")
    }

    // MARK: 清理生命周期(p4-cleaner/11 补丁,2026-11-03 用户实案)

    func testCleanedItemsFilteredAfterRelaunchFromCache() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var payload: SpaceScanCachePayload?
            var value: SpaceScanCachePayload? {
                get { lock.lock()
                    defer { lock.unlock() }
                    return payload
                }
                set { lock.lock()
                    defer { lock.unlock() }
                    payload = newValue
                }
            }
        }
        let box = Box()
        let cache = CleanScanResultStore(load: { box.value }, save: { box.value = $0 })

        // 会话 1:扫描 → 勾选 → 清理(spy 全部成功)
        let homebrew = "/Users/me/Library/Caches/Homebrew"
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [homebrew: "/Users/me/.Trash/Homebrew"]
        ))
        let first = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            trash: spy,
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        first.startScan(using: makeCacheFixture())
        await waitUntil { !first.isScanning }
        first.toggle(first.candidates[0])
        first.requestClean()
        first.confirmClean()
        await waitForCleanFinished(first)
        XCTAssertEqual(first.candidates.isEmpty, true, "清完的项不再列(会话内)")

        // 清后缓存被增量更新:cleanedPaths 含该路径
        await waitUntil { box.value?.meta.cleanedPaths.contains(homebrew) == true }

        // 会话 2(重启语义):装载 → 已清项过滤,不回列表
        let second = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            scanCache: cache,
            homeDirectory: "/Users/me"
        )
        second.loadCachedScan()
        await waitUntil { second.result != nil }
        XCTAssertEqual(second.candidates.isEmpty, true, "缓存带来的已清项照旧过滤(修复:不再回列)")
        XCTAssertEqual(second.sessionCleanedCount, 0, "历史清理不计入「本次已清理」")
    }

    func testCleanActivityBroadcastFlipsRunning() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var running = false
            func set(_ v: Bool) {
                lock.lock()
                defer { lock.unlock() }
                running = v
            }
        }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: CleanerModel.cleanActivityNotification,
            object: nil,
            queue: .main
        ) { note in
            box.set((note.userInfo?["running"] as? Bool) == true)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let homebrew = "/Users/me/Library/Caches/Homebrew"
        let spy = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [homebrew: "/Users/me/.Trash/Homebrew"]
        ))
        let model = CleanerModel(
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            trash: spy,
            homeDirectory: "/Users/me"
        )
        model.startScan(using: makeCacheFixture())
        await waitUntil { !model.isScanning }
        XCTAssertFalse(box.running, "未在清理时不得广播 running")

        model.toggle(model.candidates[0])
        model.requestClean()
        model.confirmClean()
        await waitUntil { box.running } // 开始即广播 true(quit 门卫依赖)
        await waitForCleanFinished(model)
        await waitUntil { !box.running } // 结束回落 false
    }

    /// 等待条件成立(异步条件可 await,如读 actor 的调用计数);同步闭包照常可传。
    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 500 {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待条件超时(10s)")
    }

    // MARK: 清空废纸篓状态机(p4-uninstaller/04;fake 注入,绝不真删)

    private func waitTrashPhase(
        _ model: CleanerModel,
        where predicate: (CleanerModel.TrashPhase) -> Bool,
        _ label: String
    ) async {
        for _ in 0 ..< 200 where !predicate(model.trashPhase) {
            await Task.yield()
        }
        XCTAssertTrue(predicate(model.trashPhase), label)
    }

    func testEmptyTrashInventoryEmptyGivesNoticeWithoutSheetOrDeletion() async {
        let spy = FakeCleanTrashExecutor()
        let model = CleanerModel(trash: spy, trashInventory: {
            TrashInventory(volumes: [.init(name: "启动卷", items: 0, bytes: 0)])
        })
        model.beginEmptyTrash()
        await waitTrashPhase(model, where: { $0 == .idle }, "空废纸篓回 idle")
        XCTAssertEqual(model.trashNotice, "废纸篓是空的")
        let emptyCalls = await spy.emptyCalls
        XCTAssertEqual(emptyCalls, 0, "空废纸篓零删除")
        model.dismissTrashFeedback()
        XCTAssertNil(model.trashNotice)
    }

    func testEmptyTrashConfirmFlowRunsExecutorOnce() async {
        let spy = FakeCleanTrashExecutor(
            nextEmptySummary: TrashEmptySummary(volumes: [
                TrashVolumeEmptySummary(volume: "启动卷", emptiedItems: 3, freedBytes: 1000),
            ])
        )
        let model = CleanerModel(trash: spy, trashInventory: {
            TrashInventory(volumes: [.init(name: "启动卷", items: 3, bytes: 1000)])
        })
        model.beginEmptyTrash()
        await waitTrashPhase(model, where: {
            if case .confirming = $0 {
                true
            } else {
                false
            }
        }, "进确认态")
        guard case let .confirming(inventory) = model.trashPhase else { return }
        XCTAssertEqual(inventory.totalItems, 3, "确认弹窗吃清点数字")
        model.confirmEmptyTrash()
        await waitTrashPhase(model, where: {
            if case .finished = $0 {
                true
            } else {
                false
            }
        }, "执行完成")
        guard case let .finished(summary) = model.trashPhase else { return }
        XCTAssertEqual(summary.totalItems, 3, "战报透传")
        let emptyCalls = await spy.emptyCalls
        XCTAssertEqual(emptyCalls, 1, "恰好执行一次")
        model.dismissTrashFeedback()
        if case .idle = model.trashPhase {} else {
            XCTFail("关闭横幅应回 idle")
        }
    }

    func testEmptyTrashCancelKeepsEverything() async {
        let spy = FakeCleanTrashExecutor()
        let model = CleanerModel(trash: spy, trashInventory: {
            TrashInventory(volumes: [.init(name: "启动卷", items: 2, bytes: 5)])
        })
        model.beginEmptyTrash()
        await waitTrashPhase(model, where: {
            if case .confirming = $0 {
                true
            } else {
                false
            }
        }, "进确认态")
        model.cancelEmptyTrash()
        if case .idle = model.trashPhase {} else {
            XCTFail("取消回 idle")
        }
        let emptyCalls = await spy.emptyCalls
        XCTAssertEqual(emptyCalls, 0, "取消零删除")
    }

    // MARK: 总览废纸篓读数(p6-review-fixes)——读不到 ≠ 空 / 授权门卫 / 过期读数不覆盖

    /// 废纸篓清点源的可控假件:按调用序交付预设结果并计数;`holdFirst` 让第一次
    /// 调用挂起到 `releaseFirst()`,用来排出「旧任务晚到」的时序。actor 串行化全部状态。
    private actor TrashSourceProbe {
        private var results: [TrashInventory?]
        private let holdFirst: Bool
        private var calls = 0
        private var held: CheckedContinuation<Void, Never>?

        init(results: [TrashInventory?], holdFirst: Bool = false) {
            self.results = results
            self.holdFirst = holdFirst
        }

        var callCount: Int {
            calls
        }

        func next() async -> TrashInventory? {
            calls += 1
            let result = results.isEmpty ? nil : results.removeFirst()
            if holdFirst, calls == 1 {
                await withCheckedContinuation { held = $0 }
            }
            return result
        }

        func releaseFirst() {
            held?.resume()
            held = nil
        }
    }

    private func trashInventory(items: Int, bytes: Int64) -> TrashInventory {
        TrashInventory(volumes: [.init(name: "启动卷", items: items, bytes: bytes)])
    }

    /// 读失败 → 占位,不是 0:清点源交 nil(权限被拒 / 宗卷不可用)时总览落 `.failed`,
    /// 读数通道为 nil(视图走「—」)——绝不能变成一份「0 项 · 0 字节」的空清点。
    func testOverviewTrashReadFailureIsPlaceholderNotZero() async {
        let probe = TrashSourceProbe(results: [nil])
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), trashInventory: { await probe.next() })
        XCTAssertEqual(model.overviewTrashPhase, .notCounted, "没查就是没查,不预置读数")
        XCTAssertNil(model.overviewTrash)

        model.refreshOverviewTrash()
        await waitUntil { model.overviewTrashPhase == .failed }

        XCTAssertNil(model.overviewTrash, "读不到 = nil 穿透到占位")
        XCTAssertNotEqual(
            model.overviewTrashPhase,
            .counted(TrashInventory(volumes: [])),
            "读不到不许伪造成空清点(0 是真读数)"
        )
    }

    /// 点「清空废纸篓」时清点读不到:如实提示,不谎报「废纸篓是空的」,不进确认单、零删除。
    func testEmptyTrashUnreadableInventoryIsNotReportedAsEmpty() async {
        let spy = FakeCleanTrashExecutor()
        let model = CleanerModel(trash: spy, trashInventory: { nil })
        model.beginEmptyTrash()
        await waitUntil { model.trashNotice != nil }

        XCTAssertEqual(model.trashPhase, .idle, "读不到不进确认单")
        XCTAssertNotEqual(model.trashNotice, "废纸篓是空的", "读不到 ≠ 空")
        XCTAssertTrue(model.trashNotice?.contains("读不到") == true)
        XCTAssertEqual(model.overviewTrashPhase, .failed, "总览同步落占位")
        let emptyCalls = await spy.emptyCalls
        XCTAssertEqual(emptyCalls, 0, "读不到零删除")
    }

    /// 授权门卫四条路径(CODING_STANDARDS 权限纪律):默认关——进总览的自动入口不碰
    /// 清点源;用户动作处读一次;读成功后自动入口才放行;读失败回落,不自动重试。
    func testOverviewTrashAutoRefreshGatedBehindSuccessfulUserCount() async {
        let first = trashInventory(items: 3, bytes: 1000)
        let second = trashInventory(items: 5, bytes: 2000)
        let probe = TrashSourceProbe(results: [first, second, nil])
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), trashInventory: { await probe.next() })

        // 默认关:可见性切换(自动入口)零读取,态不动。
        model.refreshOverviewTrashIfUnlocked()
        await settle()
        var calls = await probe.callCount
        XCTAssertEqual(calls, 0, "没有用户动作,自动入口不许碰清点源")
        XCTAssertEqual(model.overviewTrashPhase, .notCounted)

        // 用户动作(废纸篓卡「清点」):恰好读一次。
        model.refreshOverviewTrash()
        await waitUntil { model.overviewTrashPhase == .counted(first) }
        calls = await probe.callCount
        XCTAssertEqual(calls, 1)

        // 读成功过:自动入口放行;刷新在飞期间继续交付上次读数,不闪占位。
        model.refreshOverviewTrashIfUnlocked()
        XCTAssertEqual(model.overviewTrash, first, "刷新期间显示上次读数")
        await waitUntil { model.overviewTrashPhase == .counted(second) }
        calls = await probe.callCount
        XCTAssertEqual(calls, 2)

        // 读失败(第三次交 nil):落占位、门卫回落——之后的自动入口不再重试。
        model.refreshOverviewTrashIfUnlocked()
        await waitUntil { model.overviewTrashPhase == .failed }
        XCTAssertNil(model.overviewTrash, "失败后上次读数作废,不挂旧数字")
        model.refreshOverviewTrashIfUnlocked()
        await settle()
        calls = await probe.callCount
        XCTAssertEqual(calls, 3, "被拒不自动重试")
        XCTAssertEqual(model.overviewTrashPhase, .failed)
    }

    /// 点「清空废纸篓」的清点也是用户动作:读成功即放行自动入口,并顺手落总览读数。
    func testEmptyTrashInventoryUnlocksAutoRefreshAndFeedsOverview() async {
        let inventory = trashInventory(items: 2, bytes: 5)
        let probe = TrashSourceProbe(results: [inventory, inventory])
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), trashInventory: { await probe.next() })
        model.beginEmptyTrash()
        await waitUntil { model.trashPhase == .confirming(inventory) }
        XCTAssertEqual(model.overviewTrashPhase, .counted(inventory), "同一次清点落总览,不多读一遍")
        var calls = await probe.callCount
        XCTAssertEqual(calls, 1)

        model.refreshOverviewTrashIfUnlocked()
        await waitUntil { await probe.callCount == 2 }
        calls = await probe.callCount
        XCTAssertEqual(calls, 2, "用户动作处读成功过,自动入口放行")
    }

    /// 不重复发起、过期读数不覆盖:第一次清点还挂着时再点一次,旧任务作废——它晚到的
    /// 结果不许盖掉新读数(原实现双入口各写各的,后到者赢)。
    func testOverviewTrashStaleCountDoesNotOverwriteNewerOne() async {
        let stale = trashInventory(items: 9, bytes: 9000)
        let fresh = trashInventory(items: 1, bytes: 100)
        let probe = TrashSourceProbe(results: [stale, fresh], holdFirst: true)
        let model = CleanerModel(trash: FakeCleanTrashExecutor(), trashInventory: { await probe.next() })

        model.refreshOverviewTrash()
        await waitUntil { await probe.callCount == 1 } // 第一次清点已发起并挂起
        model.refreshOverviewTrash()
        await waitUntil { model.overviewTrashPhase == .counted(fresh) }

        await probe.releaseFirst() // 旧任务此刻才读完
        await settle()
        XCTAssertEqual(model.overviewTrashPhase, .counted(fresh), "被取代的任务读完也不写态")
    }

    /// 给后台任务与主 actor 回跳留出落定时间(用于「什么都不该发生」的断言)。
    private func settle() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: AI 模型域(p6-cleaner/02)——Ollama 内容寻址记账 + 服务进程在用第四路

    /// 两模型共享一层:模型层端到端(扫描带文件保留前缀 → 匹配 → manifest 重算)
    /// 数字 = 私有层之和 + 共享层一次 + 清单文件;ollama 服务在跑 → AI 候选灰行、
    /// 计划剔除(删前重查语义与项目在用同一条管线)。
    func testOllamaCandidateManifestAccountedAndServiceInUse() async {
        let store = home + "/.ollama/models"
        var listings = CleanFixture.homeListings(home: home, directories: [
            ".ollama/models/blobs": 0,
            ".ollama/models/manifests/registry.ollama.ai/library/llama3": 0,
            ".ollama/models/manifests/registry.ollama.ai/library/mistral": 0,
        ])
        listings[store + "/blobs"] = .entries([
            CleanFixture.file("sha256-a1", allocated: 1000, reclaimable: 1000),
            CleanFixture.file("sha256-b1", allocated: 2000, reclaimable: 2000),
            CleanFixture.file("sha256-shared", allocated: 4000, reclaimable: 4000),
            CleanFixture.file("sha256-orphan", allocated: 999, reclaimable: 999),
        ])
        listings[store + "/manifests/registry.ollama.ai/library/llama3"] = .entries([
            CleanFixture.file("latest", allocated: 100, reclaimable: 100),
        ])
        listings[store + "/manifests/registry.ollama.ai/library/mistral"] = .entries([
            CleanFixture.file("latest", allocated: 100, reclaimable: 100),
        ])
        let manifests = [
            store + "/manifests/registry.ollama.ai/library/llama3/latest":
                #"{"config":{"digest":"sha256:a1"},"layers":[{"digest":"sha256:shared"},{"digest":"sha256:a1"}]}"#,
            store + "/manifests/registry.ollama.ai/library/mistral/latest":
                #"{"config":{"digest":"sha256:b1"},"layers":[{"digest":"sha256:shared"}]}"#,
        ]
        let activity = FakeCleanActivitySource(entries: [])
        let model = CleanerModel(
            activity: activity,
            homeDirectory: home,
            aiManifestReader: { manifests[$0] }
        )
        model.startScan(using: FakeCleanDirectoryEnumerator(listings: listings), roots: [home])
        await waitUntil { !model.isScanning }

        guard let ollama = model.candidates.first(where: { $0.ruleID == "ai.ollama" }) else {
            XCTFail("ai.ollama 候选应在场")
            return
        }
        XCTAssertEqual(ollama.bytes, 7200, "共享层只计一次,无主 blob 不计入")
        XCTAssertEqual(ollama.tier, .checkFirst)
        XCTAssertNil(ollama.accountingNote)
        XCTAssertNil(model.inUseReasons(for: ollama), "服务不在场 = 不在用")

        // 服务在跑(launchd 直起,cwd=/、argv 无用户路径):AI 候选灰行 + 计划剔除。
        activity.entries = [CleanActivityEntry(path: home, reasons: [.aiService])]
        XCTAssertEqual(model.inUseReasons(for: ollama), [.aiService])
        model.toggle(ollama)
        XCTAssertTrue(model.plan.isEmpty, "在用的 AI 候选绝不进删除计划")
        XCTAssertEqual(
            model.candidates.first { $0.ruleID == "ai.ollama" }?.bytes,
            7200,
            "清单仍展示(灰显),判定不缓存不重扫"
        )
    }

    /// manifest 损坏 → 整目录口径兜底,候选带标注(行副标如实说)。
    func testOllamaCorruptManifestFallsBackWithNote() async {
        let store = home + "/.ollama/models"
        var listings = CleanFixture.homeListings(home: home, directories: [
            ".ollama/models/manifests/registry.ollama.ai/library/llama3": 0,
        ])
        listings[store + "/manifests/registry.ollama.ai/library/llama3"] = .entries([
            CleanFixture.file("latest", allocated: 100, reclaimable: 100),
            CleanFixture.file("blob-elsewhere", allocated: 5000, reclaimable: 5000),
        ])
        let model = CleanerModel(
            homeDirectory: home,
            aiManifestReader: { _ in #"{"broken"# }
        )
        model.startScan(using: FakeCleanDirectoryEnumerator(listings: listings), roots: [home])
        await waitUntil { !model.isScanning }

        let ollama = model.candidates.first { $0.ruleID == "ai.ollama" }
        XCTAssertEqual(ollama?.bytes, 5100, "兜底 = 整目录字节")
        XCTAssertEqual(ollama?.accountingNote, OllamaStoreAccounting.fallbackNote)
    }
}
