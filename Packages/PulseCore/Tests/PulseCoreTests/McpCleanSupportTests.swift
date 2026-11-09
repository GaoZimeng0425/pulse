@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// mcp-clean 双端共用数据面(mcp-clean/01):端点文件、求交口径、输出文案。
/// 删除永不真发生——夹具候选全靠公开构造器手搭。
final class McpCleanSupportTests: XCTestCase {
    // MARK: 端点文件

    func testEndpointRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-clean-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = McpCleanEndpoint.url(directory: dir)
        XCTAssertNil(McpCleanEndpoint.load(at: url), "缺失 = nil,不半解")

        let endpoint = McpCleanEndpoint(port: 47613, token: "deadbeef", pid: 4242)
        try endpoint.save(to: url)
        XCTAssertEqual(McpCleanEndpoint.load(at: url), endpoint)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            attributes[.posixPermissions] as? Int, 0o600,
            "令牌文件只许本用户读"
        )
    }

    // MARK: 求交(安全档 ∩ 非在用)

    private func candidate(
        path: String,
        tier: CleanSafetyTier,
        group: JunkGroup = .globalToolCache
    ) -> JunkCandidate {
        JunkCandidate(
            ruleID: "test",
            group: group,
            title: path.split(separator: "/").last.map(String.init) ?? path,
            path: path,
            tier: tier,
            bytes: 100,
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: true,
            rationale: "测试",
            symbolName: "folder"
        )
    }

    func testMatchAcceptsSafeNotInUseAndRejectsTheRest() {
        let safe = candidate(path: "/Users/dev/proj/node_modules", tier: .safe)
        let checkFirst = candidate(path: "/Users/dev/proj/cache", tier: .checkFirst)
        let result = McpCleanMatching.match(
            requestedPaths: [
                "/Users/dev/proj/node_modules",
                "/Users/dev/proj/cache",
                "/no/such/path",
            ],
            candidates: [safe, checkFirst],
            activityEntries: []
        )
        XCTAssertEqual(result.matched.map(\.path), ["/Users/dev/proj/node_modules"])
        XCTAssertEqual(result.unrecognized, ["/Users/dev/proj/cache", "/no/such/path"], "先检查/未知原样退回")
    }

    func testMatchProjectArtifactProtectedByProjectRootActivity() {
        // 终端开在项目根 = 整个项目的产物在用(保护路径 = 产物直接父目录)。
        let artifact = candidate(
            path: "/Users/dev/proj/node_modules",
            tier: .safe,
            group: .projectArtifacts
        )
        let result = McpCleanMatching.match(
            requestedPaths: ["/Users/dev/proj/node_modules"],
            candidates: [artifact],
            activityEntries: [
                CleanActivityEntry(path: "/Users/dev/proj", reasons: [.terminal]),
            ]
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.unrecognized, ["/Users/dev/proj/node_modules"])

        // 活动挪去别的项目 → 不再保护。
        let elsewhere = McpCleanMatching.match(
            requestedPaths: ["/Users/dev/proj/node_modules"],
            candidates: [artifact],
            activityEntries: [
                CleanActivityEntry(path: "/Users/dev/other", reasons: [.terminal]),
            ]
        )
        XCTAssertEqual(elsewhere.matched.map(\.path), ["/Users/dev/proj/node_modules"])
    }

    func testMatchDeduplicatesRequestedPaths() {
        let safe = candidate(path: "/Users/dev/proj/node_modules", tier: .safe)
        let result = McpCleanMatching.match(
            requestedPaths: ["/Users/dev/proj/node_modules", "/Users/dev/proj/node_modules"],
            candidates: [safe],
            activityEntries: []
        )
        XCTAssertEqual(result.matched.count, 1)
        XCTAssertTrue(result.unrecognized.isEmpty)
    }

    // MARK: 文案

    func testCleanableListTextEmptyAndNonEmpty() {
        let empty = McpCleanableListResponse(items: [], scanFinishedAtEpoch: nil)
        XCTAssertTrue(McpCleanText.cleanableList(empty).contains("没有"))

        let list = McpCleanableListResponse(
            items: [
                McpCleanableItem(
                    title: "node_modules",
                    path: "/dev/proj/node_modules",
                    group: "项目产物",
                    bytes: 8_000_000,
                    idleText: "3 天未动"
                ),
            ],
            scanFinishedAtEpoch: Date().timeIntervalSince1970 - 600
        )
        let text = McpCleanText.cleanableList(list)
        XCTAssertTrue(text.contains("1 项"))
        XCTAssertTrue(text.contains("8 MB"), "合计大小:\(text)")
        XCTAssertTrue(text.contains("/dev/proj/node_modules"))
        XCTAssertTrue(text.contains("3 天未动"))
        XCTAssertTrue(text.contains("10 分钟前"), "扫描数据年龄")
        XCTAssertTrue(text.contains("不在此清单"))
    }

    func testCleanResultTextStatuses() {
        let confirmed = McpCleanRunResponse(
            status: .confirmed,
            items: [
                McpCleanRunItem(path: "/a", outcomeText: McpCleanText.recycledText),
                McpCleanRunItem(path: "/b", outcomeText: "失败:扫描后目录有变动,已跳过"),
            ],
            unrecognized: ["/c"]
        )
        let text = McpCleanText.cleanResult(confirmed)
        XCTAssertTrue(text.contains("1/2 项已进废纸篓"))
        XCTAssertTrue(text.contains("/c"), "未识别路径要露面")

        XCTAssertEqual(McpCleanText.cleanResult(McpCleanRunResponse(status: .cancelledByUser)).first, "用")
        XCTAssertTrue(McpCleanText.cleanResult(McpCleanRunResponse(status: .timeout)).contains("超时"))
        XCTAssertTrue(McpCleanText.cleanResult(McpCleanRunResponse(status: .busy)).contains("稍后再试"))
        XCTAssertTrue(McpCleanText.cleanResult(McpCleanRunResponse(status: .emptySelection)).contains("没有可安全清理项"))
    }

    func testRunItemsMapping() {
        let report = CleanRunReport(
            startedAt: Date(),
            finishedAt: Date(),
            items: [
                CleanRunItem(
                    path: "/a",
                    title: "node_modules",
                    bytes: 10,
                    tier: .safe,
                    ruleID: "r",
                    outcome: .recycled(destination: "/trash/a")
                ),
                CleanRunItem(
                    path: "/b",
                    title: "cache",
                    bytes: 10,
                    tier: .safe,
                    ruleID: "r",
                    outcome: .failed(reason: "扫描后目录有变动,已跳过")
                ),
            ]
        )
        let items = McpCleanText.runItems(from: report)
        XCTAssertEqual(items.map(\.outcomeText), [
            McpCleanText.recycledText,
            "失败:扫描后目录有变动,已跳过",
        ])
    }

    func testIdleTextBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        XCTAssertEqual(McpCleanText.idleText(epoch: nil, now: now), "未动时间未知")
        XCTAssertEqual(McpCleanText.idleText(epoch: now.timeIntervalSince1970 - 100, now: now), "今天动过")
        XCTAssertEqual(McpCleanText.idleText(epoch: now.timeIntervalSince1970 - 5 * 86400, now: now), "5 天未动")
        XCTAssertEqual(McpCleanText.idleText(epoch: now.timeIntervalSince1970 - 100 * 86400, now: now), "3 个月未动")
        XCTAssertEqual(McpCleanText.idleText(epoch: now.timeIntervalSince1970 - 400 * 86400, now: now), "1 年未动")
    }
}
