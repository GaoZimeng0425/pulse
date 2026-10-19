import XCTest
@testable import Pulse

/// 功能模块扩展点(ADR-0003)经 SystemMonitor 注册表的接线:可见性值真变化才派发;
/// start 时并入模块自有传感器、启动模块一次;每轮 onRound 收到主干同轮上下文,且
/// 此刻 monitor 的既有发布状态已是同一轮。采集源全部注入惰性源(InertSources):
/// 不读进程 / tick / 内存 / 网络 / 电池 / 磁盘、不起 nettop、不开历史库。仍会碰到的
/// 只读系统面:电池 provider 的 IOPS 事件流、唤醒观察者(start 用例以 stop 收尾
/// 摘除)与 BundleDisplayNameReader 读 Info.plist 显示名(读不到回落 bundle 名)。
@MainActor
final class MonitorFeatureRegistryTests: XCTestCase {
    private let takenAt = Date(timeIntervalSinceReferenceDate: 2_000)

    // MARK: - 测试替身

    /// 跨并发域计数盒:调度器 actor 上 tick,MainActor 上读。
    private final class TickCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// 记录型替身模块:四个钩子各记一笔;onRound 时顺手读 monitor 的发布状态。
    @MainActor
    private final class SpyFeature: MonitorFeature {
        weak var monitor: SystemMonitor?
        private(set) var rounds: [RoundContext] = []
        /// onRound 时刻 monitor 已发布的组名与下钻快照时刻。
        private(set) var publishedGroupNames: [[String]] = []
        private(set) var publishedDrilldownTakenAt: [Date?] = []
        private(set) var visibilities: [MonitorVisibility] = []
        private(set) var startCount = 0
        let driverTicks = TickCounter()

        func onRound(_ context: RoundContext) {
            rounds.append(context)
            publishedGroupNames.append(monitor?.allGroups.map(\.name) ?? [])
            publishedDrilldownTakenAt.append(monitor?.drilldown?.snapshot.takenAt)
        }

        func visibilityChanged(_ visibility: MonitorVisibility) {
            visibilities.append(visibility)
        }

        func sensorDrivers() -> [SensorDriver] {
            let ticks = driverTicks
            return [SensorDriver(cadence: .every(seconds: 3600), tick: { ticks.increment() }, wakeups: nil)]
        }

        func start() {
            startCount += 1
        }
    }

    private func makeMonitor() -> SystemMonitor {
        SystemMonitor(
            source: SyntheticProcessSource(snapshots: [
                ProcessSnapshot(takenAt: takenAt, processes: [
                    RawProcess(
                        pid: 50,
                        parentPID: 1,
                        executablePath: "/Applications/WaifuX.app/Contents/MacOS/WaifuX"
                    ),
                ]),
            ]),
            coreTicks: InertCoreTickSource(),
            memoryStats: InertMemoryStatsSource(),
            networkCounters: InertNetworkCountersSource(),
            projectRoots: [],
            killService: InertKillService(),
            birthScanSource: InertBirthScanSource(),
            historyEngine: nil,
            batterySource: InertBatterySource(),
            diskCapacitySource: InertDiskCapacitySource(),
            diskThroughputSource: { _ in InertDiskThroughputSource() },
            nettopSource: InertNettopCSVSource(),
            devServerPortScanner: InertDevServerPortScanner(),
            alertCenter: AlertCenter.inert()
        )
    }

    /// 等到条件成立(MainActor 让出,monitor 的跳回任务得以执行);超时记失败。
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            XCTFail("等待超时(\(timeout)s):\(what)")
        }
    }

    // MARK: - 可见性折算(纯值)

    func testAnyWindowIsTrueWhenEitherSignalIsOn() {
        XCTAssertFalse(MonitorVisibility().anyWindow)
        XCTAssertTrue(MonitorVisibility(popover: true, moduleRankings: false).anyWindow)
        XCTAssertTrue(MonitorVisibility(popover: false, moduleRankings: true).anyWindow)
        XCTAssertTrue(MonitorVisibility(popover: true, moduleRankings: true).anyWindow)
    }

    // MARK: - 注册表派发

    /// 弹窗开 → 重复开(同值,不派发)→ 模块页开 → 弹窗关 → 模块页关。
    func testVisibilityIsDispatchedOnlyWhenItActuallyChanges() {
        let monitor = makeMonitor()
        let spy = SpyFeature()
        monitor.register(spy)

        monitor.setPopoverVisible(true)
        monitor.setPopoverVisible(true)
        monitor.setModuleRankingsVisible(true)
        monitor.setPopoverVisible(false)
        monitor.setModuleRankingsVisible(false)

        XCTAssertEqual(spy.visibilities, [
            MonitorVisibility(popover: true, moduleRankings: false),
            MonitorVisibility(popover: true, moduleRankings: true),
            MonitorVisibility(popover: false, moduleRankings: true),
            MonitorVisibility(popover: false, moduleRankings: false),
        ])
    }

    /// 登记前弹窗已开:登记当场补发现值;回到初值(全不可见)时登记则不发。
    func testFeatureRegisteredAfterAVisibilityChangeLearnsTheCurrentValue() {
        let monitor = makeMonitor()
        monitor.setPopoverVisible(true)
        let late = SpyFeature()
        monitor.register(late)

        let other = makeMonitor()
        other.setPopoverVisible(true)
        other.setPopoverVisible(false)
        let atInitial = SpyFeature()
        other.register(atInitial)

        XCTAssertEqual(late.visibilities, [MonitorVisibility(popover: true, moduleRankings: false)])
        XCTAssertEqual(atInitial.visibilities, [])
    }

    /// start 两次(幂等):模块只启动一次,自有传感器登记进调度器(首 tick 立即到)。
    func testStartRegistersFeatureSensorsAndStartsFeatureOnce() async {
        let monitor = makeMonitor()
        let spy = SpyFeature()
        monitor.register(spy)

        monitor.start()
        defer { monitor.stop() }
        monitor.start()
        await waitUntil("模块传感器首 tick") { spy.driverTicks.value >= 1 }

        XCTAssertEqual(spy.startCount, 1)
        XCTAssertEqual(spy.driverTicks.value, 1)
    }

    /// 首轮心跳落地:模块收到主干同轮上下文;此刻 monitor 的组与下钻已是同一轮。
    func testEveryRoundReachesFeatureAfterPublishedStateIsUpdated() async throws {
        let monitor = makeMonitor()
        let spy = SpyFeature()
        spy.monitor = monitor
        monitor.register(spy)

        monitor.start()
        defer { monitor.stop() }
        await waitUntil("首轮 onRound") { !spy.rounds.isEmpty }

        let context = try XCTUnwrap(spy.rounds.first)
        XCTAssertEqual(context.takenAt, takenAt)
        XCTAssertEqual(context.groups.map(\.name), ["WaifuX"])
        XCTAssertEqual(context.drilldown.snapshot.takenAt, takenAt)
        XCTAssertEqual(spy.publishedGroupNames.first, ["WaifuX"])
        XCTAssertEqual(spy.publishedDrilldownTakenAt.first, takenAt)
    }
}
