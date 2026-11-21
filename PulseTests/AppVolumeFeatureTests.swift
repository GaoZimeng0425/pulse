import CoreAudio
@testable import Pulse
@testable import PulseCore
import XCTest

// MARK: - 每应用音量功能编排测试(app-volume/01)

//
// 假引擎直驱(ScriptedEngine + FakePipeline),绝不碰 HAL——真 tap 在 hosted
// 宿主会触发 TCC 弹窗且有挂死前科(工单 Comments 拍板:引擎不进自动化)。
// 覆盖:归并×设置应用、unity 不接管、拖动建管线/回 unity 拆管线、失败行错误+
// 重拖重试、换输出设备整批重建、停摆看门狗。

/// 可编排的假引擎:scan 结果外部注入;每次 makePipeline 产一条 FakePipeline。
private final class ScriptedAppVolumeEngine: AppVolumeEngineProtocol, @unchecked Sendable {
    var scanResult: AppVolumeScan?
    /// 非空 → 下一条产出的管线 start 即抛(消费一次);模拟授权被拒/设备失败。
    var nextStartError: Error?
    private(set) var madePipelines: [FakeAppAudioPipeline] = []

    func scan() async -> AppVolumeScan? {
        scanResult
    }

    func makePipeline(
        processIDs: [AudioObjectID],
        outputID: AudioObjectID,
        outputUID: String,
        gain: Float
    ) -> AppAudioPipelineProtocol {
        let pipeline = FakeAppAudioPipeline(
            processIDs: processIDs, outputID: outputID, outputUID: outputUID, gain: gain
        )
        pipeline.startError = nextStartError
        nextStartError = nil
        madePipelines.append(pipeline)
        return pipeline
    }
}

/// 可观测假管线:start/stop/增益都记账;渲染计数固定(看门狗测试用「停走」)。
private final class FakeAppAudioPipeline: AppAudioPipelineProtocol, @unchecked Sendable {
    let processIDs: [AudioObjectID]
    let outputID: AudioObjectID
    let outputUID: String
    private(set) var started = false
    private(set) var stopped = false
    private(set) var gains: [Float] = []
    /// start() 抛这个 = 模拟授权被拒/设备失败。
    var startError: Error?
    /// 恒 false = 看门狗视角「计数停走」;恒 true = 正常在渲染。
    var rendersForever = true

    var renderCallbacks: UInt64 {
        rendersForever ? 1 : 0
    }

    var hasAudioSignal: Bool {
        rendersForever
    }

    var isAlive: Bool {
        started && !stopped
    }

    init(processIDs: [AudioObjectID], outputID: AudioObjectID, outputUID: String, gain: Float) {
        self.processIDs = processIDs
        self.outputID = outputID
        self.outputUID = outputUID
        gains.append(gain)
    }

    func setGain(_ gain: Float) {
        gains.append(gain)
    }

    func start() throws {
        if let startError {
            throw startError
        }
        started = true
    }

    func stop() {
        stopped = true
    }
}

/// 落盘记账盒(Swift 6 隔离:persist 闭包不许捕获 @MainActor 测试类的可变数组,
/// 用锁护的 Sendable 盒承接)。
private final class SettingsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AppVolumeSettings] = []

    func append(_ settings: AppVolumeSettings) {
        lock.lock()
        entries.append(settings)
        lock.unlock()
    }

    var last: AppVolumeSettings? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last
    }
}

@MainActor
final class AppVolumeFeatureTests: XCTestCase {
    private var engine: ScriptedAppVolumeEngine!
    private var store: AppVolumeSettingsStore!
    private var persisted = SettingsLog()

    override func setUp() {
        super.setUp()
        engine = ScriptedAppVolumeEngine()
        persisted = SettingsLog()
        store = AppVolumeSettingsStore(
            load: { AppVolumeSettings() },
            persist: { [persisted] settings in persisted.append(settings) }
        )
    }

    private func makeFeature() -> AppVolumeFeature {
        AppVolumeFeature(engine: engine, store: store, iconProvider: { _ in nil })
    }

    /// 外设页可见性(进场即扫)。
    private let peripheralsVisible = MonitorVisibility(mainWindowTab: .peripherals)

    private func scanWith(
        outputID: UInt32 = 7,
        outputUID: String = "out-uid",
        clients: [AppVolumeClient]
    ) -> AppVolumeScan {
        AppVolumeScan(
            outputID: outputID,
            outputUID: outputUID,
            attributed: clients.map {
                AttributedVolumeClient(
                    client: $0,
                    appKey: $0.bundleID ?? "pid:\($0.pid)",
                    appName: $0.bundleID ?? "pid:\($0.pid)",
                    appBundleID: $0.bundleID
                )
            }
        )
    }

    private let musicClient = AppVolumeClient(
        objectID: 11, pid: 100, bundleID: "com.apple.Music", isPlaying: true
    )
    private let systemSoundsClient = AppVolumeClient(
        objectID: 12, pid: 200, bundleID: "systemsoundserverd", isPlaying: false
    )

    // 异步等待走共享 waitUntil(PulseCoreTestSupport,ub-mode 收批合一)。

    // MARK: 枚举归并 × 设置

    func testScanPopulatesEntriesWithSavedSettings() async {
        store.setVolume(0.5, for: "com.apple.Music")
        store.toggleMute(for: "systemsoundserverd")
        engine.scanResult = scanWith(clients: [musicClient, systemSoundsClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        XCTAssertEqual(feature.entries.map(\.id), ["com.apple.Music", "systemsoundserverd"])
        XCTAssertEqual(feature.entries[0].volume, 0.5)
        XCTAssertEqual(feature.entries[0].isPlaying, true)
        XCTAssertTrue(feature.entries[1].isMuted)
        // 系统提示音没在出声也单列(总滑块语义)。
        XCTAssertEqual(feature.entries[1].isPlaying, false)
    }

    func testUnityAppsTakeOverNothing() async {
        // 全部 100% 且未静音:一行都不接管,零管线、零构建。
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        XCTAssertTrue(engine.madePipelines.isEmpty)
        XCTAssertEqual(feature.entries.first?.isControlled, false)
    }

    // MARK: 接管生命周期

    func testDraggingBuildsPipelineWithSquaredGain() async {
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        feature.setVolume(0.5, for: "com.apple.Music")
        // drain 到 start 落地 + 行已接管(finishBuild 之后),不是 makePipeline 那一刻。
        await waitUntil(engine.madePipelines.first?.started == true && feature.entries.first?.isControlled == true)

        let pipeline = engine.madePipelines[0]
        XCTAssertTrue(pipeline.started)
        XCTAssertFalse(pipeline.stopped)
        // 滑块 0.5 → 增益 0.25(平方曲线)。
        XCTAssertEqual(pipeline.gains.first ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(feature.entries.first?.isControlled, true)
        // 设置已落盘。
        XCTAssertEqual(persisted.last?.volumes["com.apple.Music"] ?? 0, 0.5)
    }

    func testSlideBackToUnityStopsPipeline() async {
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        feature.setVolume(0.5, for: "com.apple.Music")
        await waitUntil(engine.madePipelines.first?.started == true)

        feature.setVolume(1, for: "com.apple.Music")
        await waitUntil(engine.madePipelines[0].stopped)

        XCTAssertTrue(engine.madePipelines[0].stopped)
        XCTAssertEqual(feature.entries.first?.isControlled, false)
        XCTAssertEqual(engine.madePipelines.count, 1, "回 unity 是拆,不是重建")
    }

    func testMuteDragClearsMuteSemantics() async {
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        feature.toggleMute(for: "com.apple.Music")
        await waitUntil(engine.madePipelines.first?.started == true)
        // 静音 = 接管播无声:增益 0,不是拆管线。
        XCTAssertEqual(engine.madePipelines[0].gains.last ?? 1, 0, accuracy: 0.0001)
        XCTAssertFalse(engine.madePipelines[0].stopped)

        // 拖动音量即解除静音(设置层语义在核心包已测,这里过端到端)。
        feature.setVolume(0.5, for: "com.apple.Music")
        await waitUntil(engine.madePipelines[0].gains.last ?? 1 > 0)
        XCTAssertEqual(feature.entries.first?.isMuted, false)
    }

    func testFailedBuildSetsRowErrorAndDragRetries() async {
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        // 首次拖动:建管线即失败(模拟授权被拒 / 设备失败)→ 行错误,不接管。
        engine.nextStartError = AppAudioPipelineError(operation: "获取应用音频", code: -1)
        feature.setVolume(0.5, for: "com.apple.Music")
        // drain 到失败落地(finishBuild 记完行错误/失败账),再重拖才不会被在途 token 挡住。
        await waitUntil(feature.entries.first { $0.id == "com.apple.Music" }?.error != nil)
        XCTAssertFalse(engine.madePipelines[0].started)
        XCTAssertEqual(feature.entries.first { $0.id == "com.apple.Music" }?.isControlled, false)

        // 重拖 = 清失败账重试,新管线成功,行错误消失(drain 到错误真被
        // finishBuild 清掉,started 置位与回主线程清错之间有窗口)。
        feature.setVolume(0.6, for: "com.apple.Music")
        await waitUntil(engine.madePipelines.count == 2
            && engine.madePipelines.last?.started == true
            && feature.entries.first { $0.id == "com.apple.Music" }?.error == nil)
        XCTAssertTrue(engine.madePipelines.last?.started == true)
    }

    // MARK: 设备切换

    func testOutputDeviceChangeRebuildsAllPipelines() async {
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        feature.setVolume(0.5, for: "com.apple.Music")
        await waitUntil(engine.madePipelines.count == 1 && engine.madePipelines[0].started)
        let first = engine.madePipelines[0]

        // 切到新输出设备:老管线必须停(它们聚合的是旧设备)。tick = 产品路径的
        // 可见重扫(visibilityChanged 同值重发不会再扫)。
        engine.scanResult = scanWith(outputID: 9, outputUID: "airpods", clients: [musicClient])
        feature.tick()
        await waitUntil(engine.madePipelines.count == 2)

        XCTAssertTrue(first.stopped)
        XCTAssertTrue(engine.madePipelines[1].started)
        XCTAssertEqual(engine.madePipelines[1].outputUID, "airpods")
    }

    // MARK: 停摆看门狗

    func testStalledRenderingPipelineIsRebuilt() async {
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        feature.setVolume(0.5, for: "com.apple.Music")
        await waitUntil(engine.madePipelines.count == 1 && engine.madePipelines[0].started)
        let stalled = engine.madePipelines[0]
        stalled.rendersForever = false // 播放中但渲染计数停走

        // 记基线(首次巡检只记账不判定),再推到窗口外 → 重建(拆旧建新)。
        feature.checkStalledPipelines(now: Date())
        feature.checkStalledPipelines(now: Date().addingTimeInterval(AppVolumeFeature.stallWindow + 1))
        await waitUntil(engine.madePipelines.count == 2 && engine.madePipelines.last?.started == true)

        XCTAssertTrue(stalled.stopped)
        XCTAssertTrue(engine.madePipelines[1].started)
    }

    func testInvisiblePageKeepsPipelinesAndSkipsScanning() async {
        // 用户调过的音量在窗口关着时也要保持:不可见 = 不扫,但已建管线不拆。
        engine.scanResult = scanWith(clients: [musicClient])
        let feature = makeFeature()
        feature.visibilityChanged(peripheralsVisible)
        await waitUntil(!feature.entries.isEmpty)

        feature.setVolume(0.5, for: "com.apple.Music")
        await waitUntil(engine.madePipelines.count == 1)

        feature.visibilityChanged(MonitorVisibility(mainWindowTab: .cpu))
        feature.checkStalledPipelines(now: Date()) // 不可见时的本地巡检
        XCTAssertFalse(engine.madePipelines[0].stopped, "不可见不拆已接管管线")
    }
}
