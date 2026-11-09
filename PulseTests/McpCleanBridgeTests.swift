@testable import Pulse
@testable import PulseCore
import XCTest

// 夹具(FakeCleanDirectoryEnumerator 等)按 project.yml 纪律直接编进测试包,
// 不 import PulseCoreTestSupport 模块——测试包链接它会把 PulseCore 双份静态链
// 进来(05 记过的双份元数据坑)。

/// mcp-clean/01 桥接编排:确认执行 / 用户取消 / 超时撤单 / 求交拒绝 / busy /
/// 冷开窗等待 / 关窗中断。夹具与 CleanerModelTests 同源(假枚举器 + 假执行器,
/// 绝不真删);窗口拉起闭包注入空实现——开窗路由本身是告警深链既有机制。
@MainActor
final class McpCleanBridgeTests: XCTestCase {
    private func makeModel(
        activity: FakeCleanActivitySource = FakeCleanActivitySource(),
        trash: FakeCleanTrashExecutor = FakeCleanTrashExecutor()
    ) -> CleanerModel {
        CleanerModel(
            scanRoots: CleanScanRootsStore(load: { ["/Users/dev/code"] }, persist: { _ in }),
            trash: trash,
            activity: activity,
            homeDirectory: "/Users/dev",
            markerExists: { _ in true }
        )
    }

    private func scan(_ model: CleanerModel) async {
        let fake = FakeCleanDirectoryEnumerator(listings: CleanFixture.homeListings(
            home: "/Users/dev",
            directories: [
                "code/old-app/node_modules": 8_000_000,
                "code/old-app/src": 10,
                "code/new-tool/node_modules": 1_500_000,
            ]
        ))
        model.startScan(using: fake, roots: ["/Users/dev"])
        await waitUntil { !model.isScanning }
    }

    private func makeBridge(
        shadowModel: CleanerModel? = nil,
        windowWaitSeconds: Int = 2,
        confirmTimeoutSeconds: Int = 60
    ) -> McpCleanBridge {
        McpCleanBridge(
            shadowModel: shadowModel ?? makeModel(),
            focusCleanerTab: {},
            windowWaitSeconds: windowWaitSeconds,
            confirmTimeoutSeconds: confirmTimeoutSeconds,
            pollSeconds: 0.02,
            cacheWaitSeconds: 0
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }

    private let oldAppPath = "/Users/dev/code/old-app/node_modules"
    private let newToolPath = "/Users/dev/code/new-tool/node_modules"

    // MARK: happy path

    func testSubmitConfirmedExecutesAndReplacesSelection() async {
        // 回包要显式配成功项:执行器默认空回包按 fail-closed 记「执行器未报告结果」。
        let trash = FakeCleanTrashExecutor(nextRecycleOutcome: TrashRecycleOutcome(
            recycled: [oldAppPath: "/Users/dev/.Trash/node_modules"]
        ))
        let model = makeModel(trash: trash)
        await scan(model)
        // 预置一个用户手勾项——外部请求必须**替换**而不是叠加。
        if let extra = model.candidates.first(where: { $0.path == newToolPath }) {
            model.toggle(extra)
        }
        let bridge = makeBridge()
        bridge.attachWindowModel(model)

        let submitTask = Task { await bridge.submit(paths: [oldAppPath]) }
        await waitUntil { model.cleanPhase == .confirming }
        XCTAssertEqual(
            model.plan.items.map(\.path), [oldAppPath],
            "确认单只含 AI 请求的项,手勾项被替换"
        )
        model.confirmClean()
        let response = await submitTask.value

        XCTAssertEqual(response.status, .confirmed)
        XCTAssertEqual(response.items.map(\.path), [oldAppPath])
        XCTAssertEqual(response.items.first?.outcomeText, McpCleanText.recycledText)
        let recycled = await trash.recycleCalls
        XCTAssertEqual(recycled.flatMap(\.self), [oldAppPath], "执行器收到且只收到请求项")
    }

    func testSubmitCancelledByUser() async {
        let model = makeModel()
        await scan(model)
        let bridge = makeBridge()
        bridge.attachWindowModel(model)

        let submitTask = Task { await bridge.submit(paths: [oldAppPath]) }
        await waitUntil { model.cleanPhase == .confirming }
        model.cancelClean()
        let response = await submitTask.value

        XCTAssertEqual(response.status, .cancelledByUser)
        XCTAssertEqual(response.unrecognized, [])
    }

    func testSubmitTimeoutWithdrawsConfirmSheet() async {
        let model = makeModel()
        await scan(model)
        let bridge = makeBridge(confirmTimeoutSeconds: 1)
        bridge.attachWindowModel(model)

        let response = await bridge.submit(paths: [oldAppPath])
        XCTAssertEqual(response.status, .timeout)
        XCTAssertEqual(model.cleanPhase, .idle, "超时撤单,确认单关掉")
    }

    // MARK: 拒绝路径

    func testSubmitUnknownPathsGiveEmptySelection() async {
        let model = makeModel()
        await scan(model)
        let bridge = makeBridge()
        bridge.attachWindowModel(model)

        let response = await bridge.submit(paths: ["/no/such/thing"])
        XCTAssertEqual(response.status, .emptySelection)
        XCTAssertEqual(response.unrecognized, ["/no/such/thing"])
        XCTAssertEqual(model.cleanPhase, .idle, "没弹过确认单")
    }

    func testSubmitBusyWhenConfirmSheetAlreadyUp() async {
        let model = makeModel()
        await scan(model)
        let bridge = makeBridge()
        bridge.attachWindowModel(model)
        // 用户自己的确认单在先
        model.applyExternalSelection(model.candidates.filter { $0.path == oldAppPath })
        model.requestClean()
        XCTAssertEqual(model.cleanPhase, .confirming)

        let response = await bridge.submit(paths: [oldAppPath])
        XCTAssertEqual(response.status, .busy)
    }

    func testSubmitWithoutWindowWaitsThenGivesUp() async {
        let model = makeModel()
        await scan(model)
        let bridge = makeBridge(windowWaitSeconds: 0)

        let response = await bridge.submit(paths: [oldAppPath])
        XCTAssertEqual(response.status, .noWindow)
        XCTAssertEqual(model.cleanPhase, .idle, "没碰过任何模型")
    }

    func testSubmitWindowClosedMidConfirmReportsHonestly() async {
        let model = makeModel()
        await scan(model)
        let bridge = makeBridge()
        bridge.attachWindowModel(model)

        let submitTask = Task { await bridge.submit(paths: [oldAppPath]) }
        await waitUntil { model.cleanPhase == .confirming }
        bridge.detachWindowModel() // 用户中途关窗
        let response = await submitTask.value

        XCTAssertEqual(response.status, .appError)
        XCTAssertTrue(response.message?.contains("主窗口被关闭") == true)
    }

    // MARK: 列清单

    func testCleanableListPrefersWindowModelAndFiltersInUse() async {
        let activity = FakeCleanActivitySource(entries: [
            CleanActivityEntry(path: "/Users/dev/code/old-app", reasons: [.terminal]),
        ])
        let model = makeModel(activity: activity)
        await scan(model)
        let bridge = makeBridge()
        bridge.attachWindowModel(model)

        let list = await bridge.cleanableList()
        XCTAssertEqual(list.items.map(\.path), [newToolPath], "在用项目的产物不进 AI 清单")
        XCTAssertEqual(list.items.first?.group, "项目产物")
        XCTAssertNotNil(list.scanFinishedAtEpoch)
    }
}

/// IPC 纯函数(解析/序列化,不碰 socket)。
final class CleanIPCParserTests: XCTestCase {
    func testParseGetWithToken() {
        let raw = Data(
            ("GET /cleanable HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "X-Pulse-Token: abc123\r\n"
                + "\r\n").utf8
        )
        let parsed = CleanIPCService.parseRequest(raw)
        XCTAssertEqual(parsed?.method, "GET")
        XCTAssertEqual(parsed?.path, "/cleanable")
        XCTAssertEqual(parsed?.token, "abc123")
        XCTAssertEqual(parsed?.body, Data())
    }

    func testParsePostBodyByContentLength() {
        let body = #"{"paths":["/a","/b"]}"#
        let raw = Data(
            ("POST /clean HTTP/1.1\r\n"
                + "content-length: \(body.utf8.count)\r\n"
                + "\r\n" + body).utf8
        )
        let parsed = CleanIPCService.parseRequest(raw)
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(String(data: parsed?.body ?? Data(), encoding: .utf8), body)

        // body 没收齐 → nil(调用方继续收)
        let truncated = raw.prefix(raw.count - 3)
        XCTAssertNil(CleanIPCService.parseRequest(truncated))

        // 头没收齐 → nil
        XCTAssertNil(CleanIPCService.parseRequest(Data("GET /cleanable HTTP/1.1\r\n".utf8)))
    }

    func testParseRejectsOversizedBody() {
        let raw = Data(
            ("POST /clean HTTP/1.1\r\n"
                + "content-length: \(CleanIPCService.maxBodyBytes + 1)\r\n"
                + "\r\n").utf8
        )
        XCTAssertNil(CleanIPCService.parseRequest(raw))
    }
}
