@testable import Pulse
import PulseCore
import XCTest

/// 卸载页模型选择 / 排序 / 搜索语义(p4-uninstaller/02,2026-11-04 拍板)。
/// IO 三闭包全假注入——零真盘、零真签名、零真收据(测试纪律)。
@MainActor
final class UninstallModelTests: XCTestCase {
    private func makeModel() -> UninstallModel {
        UninstallModel(
            collectFacts: {
                LiveAppCatalogFacts(
                    candidates: [
                        AppCatalogCandidate(
                            path: "/Applications/Bitwarden.app",
                            directoryName: "Bitwarden.app",
                            bundleID: "com.bitwarden.desktop",
                            displayName: "Bitwarden"
                        ),
                        AppCatalogCandidate(
                            path: "/Applications/Ghostty.app",
                            directoryName: "Ghostty.app",
                            bundleID: "com.mitchellh.ghostty",
                            displayName: "Ghostty",
                            isDeletable: true
                        ),
                        AppCatalogCandidate(
                            path: "/Applications/Stuck.app",
                            directoryName: "Stuck.app",
                            bundleID: "com.stuck.app",
                            displayName: "Stuck",
                            isDeletable: false // 灰行:无权限
                        ),
                    ],
                    brewAppNames: ["Bitwarden.app": "bitwarden"],
                    brewZapPaths: ["bitwarden": [NSHomeDirectory() + "/Library/Application Support/Bitwarden"]]
                )
            },
            scanSizes: { paths, _, _ in
                [
                    "/Applications/Bitwarden.app": (bytes: 100, partial: false),
                    "/Applications/Ghostty.app": (bytes: 900, partial: false),
                    "/Applications/Stuck.app": (bytes: 400, partial: false),
                ].filter { paths.contains($0.key) }
            },
            activityBoard: nil,
            prober: { probes in
                // 两条通用位置 + 一条恒「先检查」(LaunchAgents)。
                _ = probes
                return [
                    AppLeftoverRow(
                        path: NSHomeDirectory() + "/Library/Caches/com.bitwarden.desktop",
                        site: .caches,
                        matchKey: "com.bitwarden.desktop",
                        source: .generic,
                        sizeBytes: 50
                    ),
                    AppLeftoverRow(
                        path: NSHomeDirectory() + "/Library/Application Support/Bitwarden",
                        site: .applicationSupport,
                        matchKey: "Bitwarden",
                        source: .caskZap,
                        sizeBytes: 90
                    ),
                    AppLeftoverRow(
                        path: NSHomeDirectory() + "/Library/LaunchAgents/com.bitwarden.desktop.plist",
                        site: .launchAgents,
                        matchKey: "com.bitwarden.desktop",
                        source: .generic,
                        isCheckFirst: true,
                        sizeBytes: 1
                    ),
                ]
            }
        )
    }

    /// 全假注入下等清单落地(闭包即刻完成,几个 yield 即够;护栏 100 次)。
    private func waitForFinished(_ model: UninstallModel) async {
        for _ in 0 ..< 100 where model.output == nil {
            await Task.yield()
        }
        XCTAssertNotNil(model.output, "清单未在护栏内落地")
    }

    func testDisplayedEntriesDefaultSizeDescending() async {
        let model = makeModel()
        model.loadIfNeeded()
        await waitForFinished(model)
        XCTAssertEqual(model.displayedEntries.map(\.name), ["Ghostty", "Stuck", "Bitwarden"], "Q5:默认占用降序")
    }

    func testToggleSelectAndGrayRowRejection() async throws {
        let model = makeModel()
        model.loadIfNeeded()
        await waitForFinished(model)
        let entries = model.displayedEntries

        // 点行 = 选中 / 取消(原型裁决);灰行(无权限)点不选中。
        let stuck = try XCTUnwrap(entries.first { $0.name == "Stuck" })
        model.toggleSelect(stuck)
        XCTAssertFalse(model.isSelected(stuck), "灰行不可选中")
        XCTAssertFalse(model.isBusy)

        let ghostty = try XCTUnwrap(entries.first { $0.name == "Ghostty" })
        model.toggleSelect(ghostty)
        XCTAssertTrue(model.isSelected(ghostty))
        model.toggleSelect(ghostty)
        XCTAssertFalse(model.isSelected(ghostty), "再点取消")
    }

    func testSearchFiltersDisplayedEntries() async {
        let model = makeModel()
        model.loadIfNeeded()
        await waitForFinished(model)
        model.searchQuery = "ghostty"
        XCTAssertEqual(model.displayedEntries.map(\.name), ["Ghostty"], "Q5:子串过滤大小写不敏感")
        model.searchQuery = ""
        XCTAssertEqual(model.displayedEntries.count, 3, "清空恢复")
    }

    func testSelectAllLeftoversSkipsCheckFirst() async throws {
        let model = makeModel()
        model.loadIfNeeded()
        await waitForFinished(model)
        let bitwarden = try XCTUnwrap(model.displayedEntries.first { $0.name == "Bitwarden" })

        // 展开动作:残留探测(假 prober)+ 彻底删除勾选重置。
        model.onExpand(bitwarden)
        for _ in 0 ..< 100 where model.leftoverCache[bitwarden.path] == nil {
            await Task.yield()
        }
        let rows = model.leftoverCache[bitwarden.path]
        XCTAssertEqual(rows?.count, 3, "假探测器三条")

        model.selectAllLeftovers(for: bitwarden)
        let selected = model.leftoverSelection
        XCTAssertEqual(selected.count, 2, "Q4:全选只收通用位置")
        XCTAssertFalse(
            selected.contains(NSHomeDirectory() + "/Library/LaunchAgents/com.bitwarden.desktop.plist"),
            "LaunchAgents 恒「先检查」不进全选"
        )

        // 先检查项仍可手动勾。
        let launchAgent = try XCTUnwrap(rows?.first { $0.isCheckFirst })
        model.toggleLeftover(launchAgent)
        XCTAssertTrue(model.isLeftoverSelected(launchAgent))
    }

    // MARK: 卸载执行状态机(03;全假边界注入)

    private func makeExecModel(
        recycle: @escaping @Sendable ([String]) async -> TrashRecycleOutcome = { paths in
            TrashRecycleOutcome(recycled: Dictionary(uniqueKeysWithValues: paths.map { ($0, "/Trash/\($0)") }))
        },
        brew: @escaping @Sendable (String, Bool) async -> BrewUninstallResult = { _, _ in .success },
        crossCheck: @escaping @Sendable () async -> [String: String] = { [:] },
        prober: @escaping @Sendable ([LeftoverProbe]) async -> [AppLeftoverRow] = { _ in [] },
        leftoverState: @escaping @Sendable (String) async -> PathSnapshot = { _ in
            .present(modifiedEpoch: 100)
        }
    ) -> UninstallModel {
        UninstallModel(
            collectFacts: {
                LiveAppCatalogFacts(
                    candidates: [
                        AppCatalogCandidate(
                            path: "/Applications/Demo.app", directoryName: "Demo.app",
                            bundleID: "com.demo", displayName: "Demo"
                        ),
                    ],
                    brewAppNames: [:], brewZapPaths: [:]
                )
            },
            scanSizes: { paths, _, _ in
                ["/Applications/Demo.app": (bytes: 1000, partial: false)].filter { paths.contains($0.key) }
            },
            activityBoard: nil,
            prober: prober,
            recycle: recycle,
            deletePermanently: { paths in
                PermanentDeletionOutcome(deleted: Set(paths))
            },
            brewUninstall: brew,
            crossCheckCasks: crossCheck,
            leftoverState: leftoverState
        )
    }

    private func waitIdle(_ model: UninstallModel) async {
        for _ in 0 ..< 200 where model.uninstallPhase == .running {
            await Task.yield()
        }
    }

    func testConfirmFlowCompletesRemovesRowAndClearsSelection() async {
        let model = makeExecModel()
        model.loadIfNeeded()
        await waitForFinished(model)
        let entry = model.displayedEntries[0]
        model.onExpand(entry)
        model.togglePermanentDelete(entry) // 彻底删除 → 直删路径
        model.requestUninstall(entry)
        guard case .confirming = model.uninstallPhase else {
            return XCTFail("应进确认态")
        }
        model.confirmUninstall()
        await waitIdle(model)
        guard case .finished = model.uninstallPhase else {
            return XCTFail("应完成,得到 \(model.uninstallPhase)")
        }
        XCTAssertTrue(model.removedAppPaths.contains(entry.path), "Q14:即移行")
        XCTAssertTrue(model.displayedEntries.isEmpty, "清单即时不再列出")
        XCTAssertFalse(model.isPermanentDeleteSelected(entry), "勾选随执行清空")
    }

    func testBrewMissingAbortsAndKeepsRow() async {
        let model = UninstallModel(
            collectFacts: {
                LiveAppCatalogFacts(
                    candidates: [
                        AppCatalogCandidate(
                            path: "/Applications/Demo.app", directoryName: "Demo.app",
                            bundleID: "com.demo", displayName: "Demo"
                        ),
                    ],
                    brewAppNames: ["Demo.app": "demo"], brewZapPaths: ["demo": []]
                )
            },
            scanSizes: { _, _, _ in ["/Applications/Demo.app": (bytes: 1000, partial: false)] },
            activityBoard: nil,
            prober: { _ in [] },
            recycle: { _ in TrashRecycleOutcome() },
            deletePermanently: { _ in PermanentDeletionOutcome() },
            brewUninstall: { _, _ in .brewMissing },
            crossCheckCasks: { [:] }
        )
        model.loadIfNeeded()
        await waitForFinished(model)
        let entry = model.displayedEntries[0]
        XCTAssertEqual(entry.brewCaskName, "demo", "brew 应用")
        model.requestUninstall(entry)
        model.confirmUninstall()
        await waitIdle(model)
        guard case .aborted = model.uninstallPhase else {
            return XCTFail("缺 brew 应中止,得到 \(model.uninstallPhase)")
        }
        XCTAssertFalse(model.removedAppPaths.contains(entry.path), "零文件动作,行保留")
    }

    func testReroutePromptAndProceed() async {
        let model = makeExecModel(crossCheck: { ["Demo.app": "demo"] })
        model.loadIfNeeded()
        await waitForFinished(model)
        let entry = model.displayedEntries[0]
        model.requestUninstall(entry)
        model.confirmUninstall()
        await waitIdle(model)
        guard case let .reroute(_, cask) = model.uninstallPhase else {
            return XCTFail("应触发改道,得到 \(model.uninstallPhase)")
        }
        XCTAssertEqual(cask, "demo")
        model.proceedAfterReroute()
        await waitIdle(model)
        guard case .finished = model.uninstallPhase else {
            return XCTFail("确认后应完成,得到 \(model.uninstallPhase)")
        }
    }

    func testPermanentDeleteResetsOnEachExpand() async throws {
        let model = makeModel()
        model.loadIfNeeded()
        await waitForFinished(model)
        let bitwarden = try XCTUnwrap(model.displayedEntries.first { $0.name == "Bitwarden" })

        model.onExpand(bitwarden)
        model.togglePermanentDelete(bitwarden)
        XCTAssertTrue(model.isPermanentDeleteSelected(bitwarden))

        // Q6:每次展开重置,不记忆跨次。
        model.onExpand(bitwarden)
        XCTAssertFalse(model.isPermanentDeleteSelected(bitwarden))
    }

    // MARK: 删前复核接线(p5-cleaner/03:模型 → Runner 的探针注入与如实报)

    func testChangedLeftoverSkippedButStillReported() async throws {
        let home = NSHomeDirectory()
        let stale = AppLeftoverRow(
            path: home + "/Library/Caches/com.demo", site: .caches, matchKey: "k",
            source: .generic, sizeBytes: 50, modifiedAtProbe: 100
        )
        let fresh = AppLeftoverRow(
            path: home + "/Library/Logs/com.demo", site: .logs, matchKey: "k",
            source: .generic, sizeBytes: 30, modifiedAtProbe: 100
        )
        let box = BatchBox()
        let model = makeExecModel(
            recycle: { paths in
                await box.append(paths)
                return TrashRecycleOutcome(recycled: Dictionary(uniqueKeysWithValues: paths.map {
                    ($0, "/Trash/\($0)")
                }))
            },
            prober: { _ in [stale, fresh] },
            leftoverState: { path in
                path == stale.path ? .present(modifiedEpoch: 999) : .present(modifiedEpoch: 100)
            }
        )
        model.loadIfNeeded()
        await waitForFinished(model)
        let entry = try XCTUnwrap(model.displayedEntries.first)
        model.onExpand(entry)
        for _ in 0 ..< 100 where model.leftoverCache[entry.path] == nil {
            await Task.yield()
        }
        model.selectAllLeftovers(for: entry)
        model.requestUninstall(entry)
        model.confirmUninstall()
        await waitIdle(model)
        guard case let .finished(report) = model.uninstallPhase else {
            return XCTFail("应完成,得到 \(model.uninstallPhase)")
        }
        let batches = await box.batches
        XCTAssertEqual(batches, [["/Applications/Demo.app", fresh.path]], "变动项不进执行器批次")
        XCTAssertEqual(report.items.map(\.path), ["/Applications/Demo.app", stale.path, fresh.path], "战报保持确认序")
        XCTAssertEqual(report.items[0].isRecycled, true, "app 本体豁免复核")
        guard case let .failed(reason) = report.items[1].outcome else {
            return XCTFail("变动残留应按失败如实报,得到 \(report.items[1].outcome)")
        }
        XCTAssertTrue(reason.contains("跳过"), "人话里说明已跳过:\(reason)")
        XCTAssertEqual(report.items[2].isRecycled, true)
    }
}

/// 跨 @Sendable 闭包记批次用。
private actor BatchBox {
    var batches: [[String]] = []

    func append(_ batch: [String]) {
        batches.append(batch)
    }
}
