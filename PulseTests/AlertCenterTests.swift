import XCTest
@testable import Pulse

/// 接缝:AlertCenter 编排(注入假 sender 与时钟)。钉死工单的授权时序与降级:
/// 授权以系统三态为准(没问过 / 已拒绝 / 已授权)——有规则开着而系统没问过
/// 就请求(开规则时或启动时);拒绝后规则照常判定、只走应用内提示;发送前现查
/// 授权(系统设置里打开即生效);resolved 清应用内列表。引擎状态机本身已在
/// AlertEngineTests 钉死,这里只测编排。
@MainActor
final class AlertCenterTests: XCTestCase {

    // MARK: - 测试替身

    /// 假 sender:模拟系统授权三态——请求前为 `status`(默认没问过),请求后按
    /// `grantResult` 落定(系统侧幂等:已落定不再变);记录请求次数与已发通知。
    /// 锁的临界区收进同步私有方法(锁不可落在 async 词法上下文,SensorSchedulerTests
    /// 的 FakeSleeper 同款纪律)。
    private final class FakeAlertSender: AlertNotificationSending, @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0
        private var delivered: [AlertNotificationPayload] = []
        private var current: NotificationAuthorization = .notDetermined
        var grantResult = true

        var authorizationRequestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        var sent: [AlertNotificationPayload] {
            lock.lock(); defer { lock.unlock() }
            return delivered
        }

        /// 系统侧现状(测试可直接改:模拟用户在系统设置里开关通知)。
        var status: NotificationAuthorization {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); defer { lock.unlock() }; current = newValue }
        }

        func requestAuthorization() async -> Bool {
            recordRequest()
        }

        func authorizationStatus() async -> NotificationAuthorization {
            status
        }

        func send(_ payload: AlertNotificationPayload) async {
            record(payload)
        }

        /// 没问过才"弹窗"并按 grantResult 落定;已落定原样返回。
        private func recordRequest() -> Bool {
            lock.lock(); defer { lock.unlock() }
            requests += 1
            if current == .notDetermined {
                current = grantResult ? .authorized : .denied
            }
            return current == .authorized
        }

        private func record(_ payload: AlertNotificationPayload) {
            lock.lock(); defer { lock.unlock() }
            delivered.append(payload)
        }
    }

    /// 注入时钟的可变盒子(@Sendable 闭包经它读当前时刻,测试推进)。
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        var now: Date {
            readNow()
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
        private func readNow() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }
    }

    /// 每测独立 suite(ProjectRootsStoreTests 同款)。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AlertCenterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 组快照快捷构造。
    private func group(
        _ id: GroupIdentity, name: String = "组", cpu: Double = 0, memoryGB: Double = 0
    ) -> AlertGroupSnapshot {
        AlertGroupSnapshot(
            id: id, name: name, cpuPercent: cpu, memoryBytes: UInt64(memoryGB * 1_073_741_824)
        )
    }

    /// 让 setEnabled 里授权 Task 跑完(同 actor yield 数次足够)。
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    // MARK: - 授权时序

    func testAuthorizationRequestedOnceOnFirstEnable() async {
        let sender = FakeAlertSender()
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { clock.now }
        )

        center.setEnabled(true, for: .systemLoad)
        await settle()
        XCTAssertEqual(sender.authorizationRequestCount, 1, "首次开启任一规则 → 请求授权")
        XCTAssertTrue(center.notificationsAuthorized)

        // 再开别的规则 / 关了再开:不再请求(系统已落定为已授权)。
        center.setEnabled(true, for: .groupCPU)
        center.setEnabled(false, for: .systemLoad)
        center.setEnabled(true, for: .systemLoad)
        await settle()
        XCTAssertEqual(sender.authorizationRequestCount, 1, "只此一次")
    }

    func testDenialStillEvaluatesAndShowsInAppOnly() async {
        let sender = FakeAlertSender()
        sender.grantResult = false
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { clock.now }
        )

        center.setEnabled(true, for: .systemLoad)
        await settle()
        XCTAssertTrue(center.authorizationDenied, "拒绝 → 明确降级提示")

        // 规则照常判定:负载 80% 持续过 5 分钟(sustain 300s)→ 触发。
        for _ in 0..<63 {
            center.ingestSampling(systemCPULoad: 80, groups: [])
            clock.advance(5)
        }
        XCTAssertEqual(center.activeAlerts.count, 1, "拒绝授权不影响判定,应用内提示照常")
        XCTAssertEqual(sender.sent.count, 0, "拒绝后不发系统通知")
    }

    /// 2026-10-19 真机:规则早已开着、本地也记过"请求过",系统里却从未登记
    /// (没问过)——旧逻辑据本地标记误判"已拒绝"、永不再问,告警只剩应用内提示。
    /// 现以系统三态为准:启动时没问过且有规则开着 → 补一次真请求。
    func testLaunchWithRulesEnabledButNeverAskedRequestsAuthorization() async {
        let sender = FakeAlertSender()
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { Date() }
        )
        center.store.setEnabled(true, for: .diskAvailable) // 上次会话已开的规则
        await center.refreshAuthorization()
        XCTAssertEqual(sender.authorizationRequestCount, 1, "没问过 + 有规则 → 启动即请求")
        XCTAssertTrue(center.notificationsAuthorized)
        XCTAssertFalse(center.authorizationDenied)
    }

    func testLaunchWithAllRulesDisabledDoesNotPrompt() async {
        // 首开任一规则才请求(spec):全关时启动不弹窗,也不误报拒绝。
        let sender = FakeAlertSender()
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { Date() }
        )
        await center.refreshAuthorization()
        XCTAssertEqual(sender.authorizationRequestCount, 0)
        XCTAssertFalse(center.authorizationDenied, "没问过 ≠ 已拒绝")
    }

    func testSystemDeniedIsReportedWithoutPrompting() async {
        let sender = FakeAlertSender()
        sender.status = .denied
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { Date() }
        )
        center.store.setEnabled(true, for: .diskAvailable)
        await center.refreshAuthorization()
        XCTAssertEqual(sender.authorizationRequestCount, 0, "已拒绝:系统不会再弹窗,不请求")
        XCTAssertTrue(center.authorizationDenied)
    }

    func testSyncOnReturnPicksUpSystemSettingsChangeWithoutPrompting() async {
        // 用户经「打开系统通知设置」入口改完授权、切回 app:同步现状,降级提示
        // 随之消失;同步只读不请求(app 每次回前台都会同步,请求会刷屏日志)。
        let sender = FakeAlertSender()
        sender.status = .denied
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { Date() }
        )
        center.store.setEnabled(true, for: .diskAvailable)
        await center.refreshAuthorization()
        XCTAssertTrue(center.authorizationDenied)

        sender.status = .authorized
        await center.syncAuthorizationStatus()
        XCTAssertTrue(center.notificationsAuthorized)
        XCTAssertFalse(center.authorizationDenied)

        sender.status = .notDetermined
        await center.syncAuthorizationStatus()
        XCTAssertEqual(sender.authorizationRequestCount, 0, "同步从不请求")
    }

    func testEnablingInSystemSettingsTakesEffectOnNextFire() async {
        // 启动时已拒绝;用户随后在系统设置里打开通知——下一次触发即发,无需重启。
        let sender = FakeAlertSender()
        sender.status = .denied
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { Date() }
        )
        center.store.setEnabled(true, for: .diskAvailable)
        await center.refreshAuthorization()
        sender.status = .authorized

        for _ in 0..<AlertEngine.minimumConsecutiveEnter {
            center.ingestDisk(availableBytes: 1_073_741_824)
        }
        await settle()
        XCTAssertEqual(sender.sent.count, 1, "发送前现查授权")
        XCTAssertTrue(center.notificationsAuthorized)
        XCTAssertFalse(center.authorizationDenied, "现查结果回写状态,降级提示随之消失")
    }

    // MARK: - 已授权:发通知带路由

    func testAuthorizedFireSendsNotificationWithRoute() async {
        let sender = FakeAlertSender()
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { clock.now }
        )
        await center.refreshAuthorization()
        center.setEnabled(true, for: .systemLoad)
        await settle()

        for _ in 0..<63 {
            center.ingestSampling(systemCPULoad: 80, groups: [])
            clock.advance(5)
        }
        await settle() // 发送是 Task 出口:让它在断言前跑完
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(sender.sent.first?.route, .overview, "系统负载 → 总览")
        XCTAssertEqual(sender.sent.first?.identifier, "systemLoad|system")

        // 解除:应用内列表清空(通知本身不撤,系统横幅语义)。
        for _ in 0..<6 {
            center.ingestSampling(systemCPULoad: 10, groups: [])
            clock.advance(5)
        }
        XCTAssertTrue(center.activeAlerts.isEmpty, "resolved 清应用内提示")
    }

    // MARK: - 喂食粘合:磁盘与组

    func testDiskIngestFiresWithStorePolicy() async {
        let sender = FakeAlertSender()
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { clock.now }
        )
        await center.refreshAuthorization()
        center.setEnabled(true, for: .diskAvailable)
        await settle()

        // 阈值改动即时生效(经 store → 引擎):阈值改成 100GB,19GB 必然越阈。
        center.setThreshold(100 * 1_073_741_824, for: .diskAvailable)
        for _ in 0..<3 {
            center.ingestDisk(availableBytes: 19 * 1_073_741_824)
            clock.advance(30)
        }
        await settle() // 发送是 Task 出口:让它在断言前跑完
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(sender.sent.first?.route, .disk, "磁盘 → 磁盘页")
    }

    func testGroupIngestNamesSubjectAndRoutesToCPU() async {
        let sender = FakeAlertSender()
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { clock.now }
        )
        await center.refreshAuthorization()
        center.setEnabled(true, for: .groupCPU)
        await settle()

        let id = GroupIdentity.app(bundlePath: "/Applications/X.app")
        // preset sustain 600s:时钟快进满足时长。
        for _ in 0..<125 {
            center.ingestSampling(systemCPULoad: 20, groups: [group(id, name: "Xcode", cpu: 320)])
            clock.advance(5)
        }
        await settle() // 发送是 Task 出口:让它在断言前跑完
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(sender.sent.first?.route, .cpu, "组 CPU → CPU 页")
        XCTAssertTrue(sender.sent.first?.title.contains("X") ?? false, "通知标题带组名")
    }

    // MARK: - 未开启的规则不评估

    func testNoEvaluationWhenAllRulesDisabled() async {
        let sender = FakeAlertSender()
        let clock = MutableClock(t0)
        let center = AlertCenter(
            store: AlertSettingsStore(defaults: makeDefaults()),
            sender: sender,
            clock: { clock.now }
        )
        await center.refreshAuthorization()
        for _ in 0..<20 {
            center.ingestSampling(systemCPULoad: 100, groups: [group(GroupIdentity.system, cpu: 999, memoryGB: 99)])
            center.ingestDisk(availableBytes: 0)
            clock.advance(300)
        }
        XCTAssertTrue(center.activeAlerts.isEmpty)
        XCTAssertTrue(sender.sent.isEmpty)
    }
}
