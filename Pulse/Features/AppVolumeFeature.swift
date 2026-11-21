import AppKit
import CoreAudio
import Foundation
import Observation
import PulseCore

// MARK: - 每应用音量功能模块(app-volume/01;ADR-0003 MonitorFeature)

//
// 编排层(reconcile / 看门狗 / 睡眠自愈 Adapted from lishuangqiang/mixbar
// AudioMixer,MIT;See THIRD_PARTY_NOTICES.md),纯逻辑(曲线/归并/载荷)在
// PulseCore `AppVolumeModel`,HAL 与 tap 管线在 Live 引擎缝后面。
//
// 采样纪律:枚举轮询 1.5s 只在外设页可见时跑(`shows(.sound)` 家族闸,
// ADR-0006);已接管的管线**不随可见性拆**——用户调过的音量在窗口关着时也要
// 保持,每 tick 只补一轮本地看门狗(纯内存计数,零 HAL 调用)。睡眠销毁全部
// 管线、唤醒重建(mixbar 实证:睡眠后聚合可能停摆而 tap 还在掐原声)。

@Observable
@MainActor
final class AppVolumeFeature: MonitorFeature {
    /// 混音卡行(核心包条目 + 展示态);空 = 没有正在出声/在跑的音频应用。
    private(set) var entries: [AppVolumeEntry] = []
    /// false = 无音频子系统/无默认输出设备(空态区分「等待播放」与「无设备」)。
    private(set) var hasOutputDevice = true
    /// 行图标缓存(bundleID → app 图标;pid 行无图标,视图回 SF Symbol)。
    private(set) var icons: [String: NSImage] = [:]

    @ObservationIgnored private let engine: any AppVolumeEngineProtocol
    @ObservationIgnored private let store: AppVolumeSettingsStore
    @ObservationIgnored private let iconProvider: @MainActor (String?) -> NSImage?

    @ObservationIgnored private var pipelines: [String: AppAudioPipelineProtocol] = [:]
    @ObservationIgnored private var failedKeys: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var outputID: AudioObjectID = 0
    @ObservationIgnored private var outputUID = ""
    @ObservationIgnored private var outputSignature = ""
    @ObservationIgnored private var renderWatch: [String: (cycles: UInt64, at: Date)] = [:]
    @ObservationIgnored private var stallRebuilds: [String: (count: Int, at: Date)] = [:]
    /// 每行的在途构建 token(拖动不能每 tick 排一个构建)。
    @ObservationIgnored private var buildTokens: [String: Int] = [:]
    @ObservationIgnored private var nextBuildToken = 1
    /// 整批管线换代计数:换代后落地的旧构建直接丢弃,不留双活 tap。
    @ObservationIgnored private var pipelineGeneration = 0
    @ObservationIgnored private var iconAttempts: Set<String> = []

    /// 渲染停摆判定窗与重建上限(mixbar 实证值)。
    static let stallWindow: TimeInterval = 1.6
    static let stallRebuildLimit = 3
    static let tickInterval: TimeInterval = 1.5

    init(
        engine: any AppVolumeEngineProtocol,
        store: AppVolumeSettingsStore,
        iconProvider: @escaping @MainActor (String?) -> NSImage?
    ) {
        self.engine = engine
        self.store = store
        self.iconProvider = iconProvider
    }

    // MARK: MonitorFeature 钩子

    func start(_ host: MonitorHost) {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        // 睡眠前拆光管线(醒来聚合可能停摆而 tap 仍掐原声 = 那只 app 无声);
        // 唤醒后重建。拆 = 停读,原声立刻回来,睡眠期间声音走原始路由。
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.destroyPipelines() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryAll() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.3
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        destroyPipelines()
    }

    func visibilityChanged(_ visibility: MonitorVisibility) {
        let visible = visibility.shows(.sound)
        if visible, !isVisible {
            scan() // 进场沿立即扫一轮,开页不用等下一 tick
        }
        isVisible = visible
    }

    // MARK: 用户操作

    /// 拖某行滑块(0…1 滑块位)。首次把任何 app 拖离 100% 会触发系统「音频捕获」
    /// 授权弹窗(管线第一次建 tap 那一刻);被拒 → 该行错误文案,再拖即重试。
    func setVolume(_ volume: Double, for key: String) {
        store.setVolume(volume, for: key)
        applySettingsRow(key)
    }

    /// 切某行静音(静音 = 接管后播无声,同样需要授权)。
    func toggleMute(for key: String) {
        store.toggleMute(for: key)
        applySettingsRow(key)
    }

    private func applySettingsRow(_ key: String) {
        failedKeys.remove(key)
        if let index = entries.firstIndex(where: { $0.id == key }) {
            entries[index].volume = store.settings.volume(for: key)
            entries[index].isMuted = store.settings.isMuted(key)
            reconcile(index: index)
        }
    }

    // MARK: 轮询与扫描

    /// 每 tick:可见则全量扫,随后本地看门狗巡检。internal 供单测走产品路径
    /// (@testable);产品运行期由 start 的定时器驱动。
    func tick() {
        if isVisible {
            scan()
        }
        checkStalledPipelines(now: Date())
    }

    private func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task { [weak self, engine] in
            let result = await engine.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                isScanning = false
                if let result {
                    apply(result)
                } else {
                    applyNoOutputDevice()
                }
            }
        }
    }

    private func applyNoOutputDevice() {
        hasOutputDevice = false
        if !entries.isEmpty {
            entries = []
        }
        destroyPipelines()
    }

    private func apply(_ scan: AppVolumeScan) {
        hasOutputDevice = true
        outputID = scan.outputID
        outputUID = scan.outputUID
        // 换输出设备 = 全部管线作废(它们聚合的是旧设备),整批换代。
        let signature = "\(scan.outputID):\(scan.outputUID)"
        if outputSignature != signature {
            destroyPipelines()
            outputSignature = signature
        }
        let oldErrors = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in entry.error.map { (entry.id, $0) } }
        )
        var next = AppVolumeGrouping.entries(from: scan.attributed, settings: store.settings)
        for index in next.indices {
            next[index].error = oldErrors[next[index].id]
        }
        if next != entries {
            entries = next
        }
        fetchIcons(for: next)
        let keys = Set(entries.map(\.id))
        failedKeys.formIntersection(keys)
        for key in Array(pipelines.keys) where !keys.contains(key) {
            pipelines.removeValue(forKey: key)?.stop()
            renderWatch[key] = nil
        }
        for index in entries.indices {
            reconcile(index: index)
        }
        checkStalledPipelines(now: Date())
    }

    private func fetchIcons(for entries: [AppVolumeEntry]) {
        for entry in entries where !iconAttempts.contains(entry.id) {
            iconAttempts.insert(entry.id)
            if let icon = iconProvider(entry.bundleID), icons[entry.id] == nil {
                icons[entry.id] = icon
            }
        }
    }

    // MARK: 管线 reconcile(mixbar 同款:unity 不接管、token 防抖、换代丢弃)

    private func reconcile(index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        let gain = entry.desiredGain
        // unity(100% 且未静音)= 原声直通:不建管线——没调过音量的 app 零成本,
        // 也不触发系统音频捕获授权(管线第一次创建才弹)。
        guard abs(gain - 1) > 0.00001 else {
            pipelines.removeValue(forKey: entry.id)?.stop()
            setRow(index, controlled: false, error: nil)
            return
        }
        // 进程组变了(浏览器又起了个 helper)/换了输出设备/管线死了 → 重建。
        if let pipeline = pipelines[entry.id],
           pipeline.processIDs != entry.processIDs || pipeline.outputID != outputID || !pipeline.isAlive {
            pipelines.removeValue(forKey: entry.id)?.stop()
        }
        if let pipeline = pipelines[entry.id] {
            pipeline.setGain(gain)
            setRow(index, controlled: pipeline.hasAudioSignal, error: nil)
            return
        }
        guard !failedKeys.contains(entry.id), buildTokens[entry.id] == nil, !outputUID.isEmpty else { return }
        // 建 tap+聚合 ≈20–25ms,主线程外做;行在同一刻可能又变了,token/generation
        // 双保险丢弃过期构建。
        let token = nextBuildToken
        nextBuildToken += 1
        buildTokens[entry.id] = token
        let generation = pipelineGeneration
        let id = entry.id
        let pipeline = engine.makePipeline(
            processIDs: entry.processIDs,
            outputID: outputID,
            outputUID: outputUID,
            gain: gain
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String?
            do {
                try pipeline.start()
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                self?.finishBuild(
                    id: id, token: token, generation: generation,
                    pipeline: pipeline, failure: failure
                )
            }
        }
    }

    private func finishBuild(
        id: String,
        token: Int,
        generation: Int,
        pipeline: AppAudioPipelineProtocol,
        failure: String?
    ) {
        guard buildTokens[id] == token else { pipeline.stop()
            return
        }
        buildTokens.removeValue(forKey: id)
        guard generation == pipelineGeneration,
              let index = entries.firstIndex(where: { $0.id == id }) else {
            pipeline.stop()
            return
        }
        if let failure {
            pipeline.stop()
            failedKeys.insert(id)
            setRow(index, controlled: false, error: failure)
            return
        }
        let gain = entries[index].desiredGain
        guard entries[index].processIDs == pipeline.processIDs,
              pipeline.outputID == outputID, abs(gain - 1) > 0.00001 else {
            pipeline.stop()
            return
        }
        pipeline.setGain(gain)
        pipelines[id] = pipeline
        setRow(index, controlled: pipeline.hasAudioSignal, error: nil)
    }

    /// 行状态只在真变时写(@Published 元素赋值会重画整卡)。
    private func setRow(_ index: Int, controlled: Bool, error: String?) {
        if entries[index].isControlled != controlled {
            entries[index].isControlled = controlled
        }
        if entries[index].error != error {
            entries[index].error = error
        }
    }

    // MARK: 看门狗(渲染停摆自愈)

    /// 活聚合可能停止回调而 tap 还在掐原声(典型:睡眠后/设备重协商)——那只 app
    /// 会安静掉而管线表面一切正常。播放中的行渲染计数停走超过窗口 → 重建;20s 内
    /// 最多 3 次,仍失败 → 放弃接管原声自回(mixbar 实证机制)。
    /// internal 供单测注入时钟(@testable);产品路径只由 tick 调。
    func checkStalledPipelines(now: Date) {
        for (id, pipeline) in pipelines {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            guard entries[index].isPlaying, !entries[index].isMuted else {
                renderWatch[id] = nil
                continue
            }
            let cycles = pipeline.renderCallbacks
            guard let previous = renderWatch[id], cycles == previous.cycles else {
                renderWatch[id] = (cycles, now)
                continue
            }
            guard now.timeIntervalSince(previous.at) >= Self.stallWindow else { continue }
            renderWatch[id] = nil
            rebuildStalledPipeline(id: id, index: index, now: now)
        }
        renderWatch = renderWatch.filter { pipelines[$0.key] != nil }
    }

    private func rebuildStalledPipeline(id: String, index: Int, now: Date) {
        if let record = stallRebuilds[id], now.timeIntervalSince(record.at) < 20 {
            guard record.count < Self.stallRebuildLimit else {
                pipelines.removeValue(forKey: id)?.stop()
                failedKeys.insert(id)
                setRow(index, controlled: false, error: "音频管线无响应,已停止接管;重拖滑块可重试。")
                return
            }
            stallRebuilds[id] = (record.count + 1, now)
        } else {
            stallRebuilds[id] = (1, now)
        }
        // 拆管线 = 停读 = 原声立刻回来;随后的 reconcile 建新聚合补上。
        pipelines.removeValue(forKey: id)?.stop()
        if entries.indices.contains(index) {
            reconcile(index: index)
        }
    }

    // MARK: 整批收尾 / 重建

    private func destroyPipelines() {
        pipelineGeneration += 1
        for pipeline in pipelines.values {
            pipeline.stop()
        }
        pipelines.removeAll()
        renderWatch.removeAll()
        buildTokens.removeAll()
    }

    /// 唤醒 / 手动重试:清失败账,整批换代重扫重建。
    private func retryAll() {
        failedKeys.removeAll()
        stallRebuilds.removeAll()
        destroyPipelines()
        scan()
    }
}
