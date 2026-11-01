@testable import Pulse
@testable import PulseCore
import XCTest

/// 接缝:AlertCenter 的第四出口(NemoNotch toast)。钉死:触发即发(fire-and-forget)、
/// 归因取触发当轮(正文点名进程)、渠道开关关 = 不发、dev server 不进 toast。
/// 文案与归因本身在 PulseCore 单测(NemoNotchToastContentTests / AlertOffenderTests),
/// 这里只测编排接线。
@MainActor
final class AlertCenterToastTests: XCTestCase {
    // MARK: - 测试替身

    /// 假 toast sender:只记录载荷(锁纪律同 FakeAlertSender)。
    private final class FakeToastSender: NemoNotchToastSending, @unchecked Sendable {
        private let lock = NSLock()
        private var delivered: [NemoNotchToastPayload] = []

        var sent: [NemoNotchToastPayload] {
            lock.lock()
            defer { lock.unlock() }
            return delivered
        }

        func send(_ payload: NemoNotchToastPayload) async {
            lock.lock()
            defer { lock.unlock() }
            delivered.append(payload)
        }
    }

    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) {
            current = start
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    // MARK: - 夹具

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AlertCenterToastTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// 一轮带进程的主干上下文:进程表按原样归组(无项目根 → 孤儿组),
    /// 系统负载按参数——喂食与归因暂存同轮同源。
    private func round(load: Double, processes: [RawProcess]) -> RoundContext {
        let snapshot = ProcessSnapshot(takenAt: Date(), processes: processes)
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: nil, current: snapshot),
            cpu: CPULoadBreakdown(total: load, user: load, system: 0),
            rankings: .empty
        ))
    }

    /// 触发 systemLoad(阈值 70、持续 5 分钟):三轮越阈 + 时钟推过持续窗。
    private func fireSystemLoad(
        _ center: AlertCenter, clock: MutableClock, processes: [RawProcess]
    ) async {
        center.onRound(round(load: 90, processes: processes))
        clock.advance(150)
        center.onRound(round(load: 90, processes: processes))
        clock.advance(150)
        center.onRound(round(load: 90, processes: processes))
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }

    // MARK: - 出口接线

    /// 触发 → toast 发出:标题带组名,正文点名当轮进程,稳定 key 供同主体覆盖。
    func testFiredSystemLoadSendsToastWithOffenderNames() async {
        let toast = FakeToastSender()
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: InertAlertNotificationSender(),
            toastSender: toast,
            clock: { clock.now }
        )
        center.setEnabled(true, for: .systemLoad)
        await fireSystemLoad(center, clock: clock, processes: [
            RawProcess(pid: 100, parentPID: 1, executablePath: "/usr/local/bin/electron", argv: ["electron"]),
        ])

        let sent = toast.sent
        XCTAssertEqual(sent.count, 1, "触发一次只发一张卡")
        let payload = sent[0]
        XCTAssertTrue(payload.title.contains("系统负载过高"))
        XCTAssertTrue(payload.body?.contains("electron") == true, "正文点名当轮进程,拿到就会写")
        XCTAssertEqual(payload.key, "alert|systemLoad|system")
    }

    /// 渠道开关关(规则照常触发)→ 不发 toast。
    func testToastDisabledSkipsDelivery() async {
        let toast = FakeToastSender()
        let clock = MutableClock(t0)
        let store = AlertSettingsStore(defaults: makeDefaults())
        let center = AlertCenter(
            store: store,
            sender: InertAlertNotificationSender(),
            toastSender: toast,
            clock: { clock.now }
        )
        center.setEnabled(true, for: .systemLoad)
        store.setToastDeliveryEnabled(false)
        await fireSystemLoad(center, clock: clock, processes: [])
        XCTAssertTrue(toast.sent.isEmpty)
    }

    /// dev server 闲置触发 → 不进 toast(与「谁在消耗资源」无关)。
    func testDevServerIdleFiresNoToast() async {
        let toast = FakeToastSender()
        let clock = MutableClock(t0)
        let store = AlertSettingsStore(defaults: makeDefaults())
        let center = AlertCenter(
            store: store,
            sender: InertAlertNotificationSender(),
            toastSender: toast,
            clock: { clock.now }
        )
        center.setEnabled(true, for: .devServerIdle)
        center.setThreshold(60, for: .devServerIdle) // 闲置 60 秒即越阈
        for _ in 0 ..< 3 {
            center.ingestDevServers([
                AlertDevServerSnapshot(pid: 42, name: "vite", idleSeconds: 120),
            ])
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertTrue(toast.sent.isEmpty, "dev server 闲置不该弹 NemoNotch 卡")
    }
}

/// 端点发现(纯函数,注入临时目录):端口缺省回落、令牌缺省跳过、首尾空白剥掉。
final class NemoNotchEndpointTests: XCTestCase {
    private func makeDirectory(files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func testReadsPortAndTokenTrimmingWhitespace() throws {
        let directory = try makeDirectory(files: ["hook-port": "45999\n", "hook-token": " tok\n"])
        let endpoint = LiveNemoNotchToastSender.readEndpoint(directory: directory)
        XCTAssertEqual(endpoint.port, 45999)
        XCTAssertEqual(endpoint.token, "tok")
    }

    func testMissingPortFallsBackAndMissingTokenYieldsNil() throws {
        let directory = try makeDirectory(files: ["hook-token": "tok"])
        let endpoint = LiveNemoNotchToastSender.readEndpoint(directory: directory)
        XCTAssertEqual(endpoint.port, LiveNemoNotchToastSender.fallbackPort)
        XCTAssertEqual(endpoint.token, "tok")
    }

    func testEmptyTokenFileYieldsNil() throws {
        let directory = try makeDirectory(files: ["hook-port": "45831", "hook-token": "\n"])
        let endpoint = LiveNemoNotchToastSender.readEndpoint(directory: directory)
        XCTAssertNil(endpoint.token, "空令牌文件与缺失同义:静默跳过")
    }
}
