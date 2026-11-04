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
}
