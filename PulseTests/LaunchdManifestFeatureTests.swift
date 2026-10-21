@testable import Pulse
@testable import PulseCore
import XCTest

/// launchd-attribution/01 的 app 侧薄壳:LaunchdManifestProvider 的节奏钉子、lastGood 交付口径、
/// 状态沿日志只记切换,以及 LaunchdManifestFeature 把交付接进 MonitorHost。纯逻辑(解析 /
/// 两层缓存 / 健康态折算)在核心包 LaunchdManifestTests;真机 corplink 命中留验收目验。
@MainActor
final class LaunchdManifestFeatureTests: XCTestCase {
    private let corplink = "/usr/local/corplink/corplink-service"
    private let fakeDirectory = "/fake/LaunchDaemons"

    // MARK: - 测试替身

    /// 单目录假源,响应可随时切换(模拟目录由可读变不可读再恢复)。
    private final class SwitchablePlistSource: LaunchdPlistSource, @unchecked Sendable {
        private let lock = NSLock()
        private var response: LaunchdPlistDirectoryRead

        init(_ response: LaunchdPlistDirectoryRead) {
            self.response = response
        }

        func set(_ response: LaunchdPlistDirectoryRead) {
            lock.lock()
            defer { lock.unlock() }
            self.response = response
        }

        func read(directory: String) -> LaunchdPlistDirectoryRead {
            lock.lock()
            defer { lock.unlock() }
            return response
        }
    }

    /// 跨并发域的交付 / 日志收件箱。
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Value] = []

        func append(_ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            items.append(value)
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// 宿主侧接收清单的记录器(MainActor,与 SystemMonitor.spine 同位置)。
    private final class ManifestRecorder {
        var sets: [Set<String>] = []
    }

    private func plist(program: String) -> Data {
        // 测试夹具:字典字面量序列化不会失败,失败即崩是期望行为
        // swiftlint:disable:next force_try
        try! PropertyListSerialization.data(
            fromPropertyList: ["Label": "test", "Program": program], format: .xml, options: 0
        )
    }

    private func makeProvider(
        source: any LaunchdPlistSource,
        log: Box<LaunchdManifestHealthLog.Entry>
    ) -> LaunchdManifestProvider {
        LaunchdManifestProvider(
            source: source,
            sealedDirectories: [],
            mutableDirectories: [fakeDirectory],
            resolveSymlinks: { $0 },
            log: { log.append($0) }
        )
    }

    // MARK: - 节奏钉子(票面验收:刷新间隔 ≥ 60s;节奏归 SensorScheduler 管,provider 不自带节流)

    func testRefreshCadenceIsAtLeastSixtySeconds() {
        XCTAssertGreaterThanOrEqual(LaunchdManifestProvider.refreshInterval, 60)
        let provider = makeProvider(source: SwitchablePlistSource(.absent), log: Box())
        XCTAssertEqual(provider.cadence, .every(seconds: LaunchdManifestProvider.refreshInterval))
    }

    // MARK: - 交付口径(ADR-0004 lastGood;ADR-0005:读失败保留上次好清单而非空清单)

    func testDriverDeliversManifestThenLastGoodOnFailureAndLogsOnlyTransitions() async {
        let source = SwitchablePlistSource(.plists([plist(program: corplink)]))
        let log = Box<LaunchdManifestHealthLog.Entry>()
        let provider = makeProvider(source: source, log: log)
        let deliveries = Box<Set<String>?>()
        let driver = provider.driver { deliveries.append($0) }

        await driver.tick()
        source.set(.unreadable)
        await driver.tick()
        await driver.tick()

        XCTAssertEqual(deliveries.values, [[corplink], [corplink], [corplink]])
        XCTAssertEqual(provider.lastGood, [corplink])
        XCTAssertEqual(log.values.map(\.level), [.error], "进入失败记一条 error;第三轮同态静默")

        source.set(.plists([plist(program: corplink)]))
        await driver.tick()
        XCTAssertEqual(log.values.map(\.level), [.error, .info], "恢复记一条 info")
    }

    func testDriverDeliversNilBeforeAnySuccess() async {
        let provider = makeProvider(source: SwitchablePlistSource(.unreadable), log: Box())
        let deliveries = Box<Set<String>?>()

        await provider.driver { deliveries.append($0) }.tick()

        XCTAssertEqual(deliveries.values.count, 1)
        XCTAssertNil(deliveries.values[0])
        XCTAssertNil(provider.lastGood)
    }

    // MARK: - 功能模块 → 宿主接线

    func testFeatureFeedsManifestIntoHost() async {
        let provider = makeProvider(source: SwitchablePlistSource(.plists([plist(program: corplink)])), log: Box())
        let feature = LaunchdManifestFeature(provider: provider)
        let recorder = ManifestRecorder()
        feature.start(MonitorHost(
            restoreBirths: { _ in },
            setLaunchdServiceExecutablePaths: { recorder.sets.append($0) },
            setRankingsActive: { _ in },
            broadcast: { _ in }
        ))

        let drivers = feature.sensorDrivers()
        XCTAssertEqual(drivers.count, 1)
        await drivers[0].tick()
        // 交付经 Task { @MainActor } 跳回主线程:让出若干次直到到达。
        for _ in 0 ..< 200 where recorder.sets.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(recorder.sets, [[corplink]])
    }

    /// 从未成功读过:交付 nil,主干保持现有清单(初值空集),宿主回调不被调用。
    func testFeatureIgnoresNilDeliveryBeforeAnySuccess() async {
        let provider = makeProvider(source: SwitchablePlistSource(.unreadable), log: Box())
        let feature = LaunchdManifestFeature(provider: provider)
        let recorder = ManifestRecorder()
        feature.start(MonitorHost(
            restoreBirths: { _ in },
            setLaunchdServiceExecutablePaths: { recorder.sets.append($0) },
            setRankingsActive: { _ in },
            broadcast: { _ in }
        ))

        await feature.sensorDrivers()[0].tick()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(recorder.sets, [])
    }
}
