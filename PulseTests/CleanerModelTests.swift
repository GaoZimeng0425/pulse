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
            "Library/Developer/Xcode/DerivedData": 28000,
            "Library/Caches/Homebrew": 3100,
            "Documents/DerivedData": 9999, // 似是而非:不在白名单
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
        XCTAssertEqual(report.freedBytes, 28000)
        XCTAssertTrue(report.failed.isEmpty)
        let calls = await spy.recycleCalls
        XCTAssertEqual(calls, [[derivedPath]], "spy 收到恰好选中的那一条,绝不多")
        XCTAssertEqual(model.candidates.map(\.ruleID), ["homebrew.cache"], "已回收项不再列")
        XCTAssertTrue(model.selection.isEmpty, "勾选随清单收敛")
        XCTAssertEqual(model.recycledPaths, [derivedPath])

        let runs = try await history.runs()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].freedBytes, 28000)
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
            using: makeHomeEnumerator(extra: ["Library/Caches/JetBrains": 5400]),
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
                "code/old-app/node_modules": 800,
                "code/old-app/src": 10,
                "code/old-app/target": 300,
                "code/new-tool/node_modules": 100,
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
        XCTAssertEqual(artifacts.first?.projectName, "old-app")
        XCTAssertEqual(
            artifacts.first?.newestChangeEpoch.map { Int($0) },
            Int(oldAge),
            "年龄 = 项目源码的最后变动;产物自身 mtime 再新也不算(重装依赖不刷新年龄)"
        )

        model.artifactSort = .age
        let byAge = model.candidates.filter { $0.group == .projectArtifacts }
        XCTAssertEqual(byAge.map(\.projectName).first, "old-app", "按新旧 = 最久未动在前")
        XCTAssertEqual(byAge.map(\.projectName).last, "new-tool")
    }

    func testInUseProjectFilteredFromPlanWithFreshRecheck() async throws {
        let fake = FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(
            home: "/Users/dev",
            directories: [
                "code/old-app/node_modules": 800,
                "code/new-app/node_modules": 400,
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
                CleanFixture.file("b.bin", allocated: 512, reclaimable: 512),
            ]),
        ])
        let model = CleanerModel(homeDirectory: "/Users/me")
        model.startScan(using: fake)
        await waitUntil { !model.isScanning }

        XCTAssertEqual(model.candidates.map(\.ruleID), ["homebrew.cache"], "规范域树 + 规范家目录:清单不再为空")
        XCTAssertEqual(model.candidates.first?.path, "/Users/me/Library/Caches/Homebrew")
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
                CleanFixture.file("b.bin", allocated: 512, reclaimable: 512),
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

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 500 {
            if condition() {
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
}
