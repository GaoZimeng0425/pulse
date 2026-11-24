import AppKit
import CoreAudio
import Foundation
import PulseCore

// MARK: - 每应用音量引擎缝 + Live 实现(app-volume/01;ADR-0004 测试缝同款)

//
// 归因(HAL 客户端 → 宿主 app)Adapted from lishuangqiang/mixbar AudioMixer
// (MIT),间接基于 pantafive/fader。See THIRD_PARTY_NOTICES.md.

extension AppAudioPipeline: AppAudioPipelineProtocol {}

/// Live 引擎:HAL 进程对象枚举 + NSWorkspace 归因 + 管线工厂。
struct LiveAppVolumeEngine: AppVolumeEngineProtocol {
    func scan() async -> AppVolumeScan? {
        let raw = await Task.detached(priority: .utility) { Self.readRawClients() }.value
        guard let raw else { return nil }
        let attributed = await MainActor.run { Self.attribute(raw.clients) }
        return AppVolumeScan(outputID: raw.outputID, outputUID: raw.outputUID, attributed: attributed)
    }

    func makePipeline(
        processIDs: [AudioObjectID],
        outputID: AudioObjectID,
        outputUID: String,
        gain: Float
    ) -> AppAudioPipelineProtocol {
        AppAudioPipeline(processIDs: processIDs, outputID: outputID, outputUID: outputUID, gain: gain)
    }

    // MARK: HAL 快照(后台线程)

    /// 后台线程读回的原始载荷:默认输出设备身份 + 全部音频进程对象。
    private struct RawClients: Sendable {
        let outputID: UInt32
        let outputUID: String
        let clients: [AppVolumeClient]
    }

    /// 系统对象上的全部音频进程对象 → PID/bundleID/是否在出声。原样透传公开
    /// 属性,折算(归并)在 PulseCore `AppVolumeGrouping`(ADR-0004)。
    private nonisolated static func readRawClients() -> RawClients? {
        guard let output = AppAudioCA.defaultOutputDevice(),
              let uid = AppAudioCA.deviceUID(output) else { return nil }
        let objects = AppAudioCA.array(
            AppAudioCA.systemObject,
            AppAudioCA.address(kAudioHardwarePropertyProcessObjectList),
            AudioObjectID.self
        )
        var clients: [AppVolumeClient] = []
        clients.reserveCapacity(objects.count)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in objects {
            let pid = AppAudioCA.scalar(object, AppAudioCA.address(kAudioProcessPropertyPID), pid_t(-1))
            guard pid > 0, pid != ownPID else { continue }
            let bundleID = AppAudioCA.cfString(object, AppAudioCA.address(kAudioProcessPropertyBundleID))
            let playing = AppAudioCA.scalar(
                object,
                AppAudioCA.address(kAudioProcessPropertyIsRunningOutput),
                UInt32(0)
            ) != 0
            clients.append(AppVolumeClient(objectID: object, pid: pid, bundleID: bundleID, isPlaying: playing))
        }
        return RawClients(outputID: output, outputUID: uid, clients: clients)
    }

    // MARK: 归因(主线程;NSWorkspace)

    /// macOS 所有通知/提示音都从这个守门进程出:永远单列一行,是系统提示音总滑块。
    static let systemSoundsBundleID = "systemsoundserverd"

    @MainActor
    static func attribute(_ clients: [AppVolumeClient]) -> [AttributedVolumeClient] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var result: [AttributedVolumeClient] = []
        result.reserveCapacity(clients.count)
        for client in clients {
            let owner = ownerApplication(pid: client.pid, bundleID: client.bundleID, regular: regular)
            let appBundleID = owner?.bundleIdentifier ?? client.bundleID
            guard appBundleID != Bundle.main.bundleIdentifier else { continue } // 不列自己
            let isSystemSounds = appBundleID == systemSoundsBundleID
                || client.bundleID == systemSoundsBundleID
            // 常规 app 在跑就列(没出声也能先调好);静默系统 agent 只在出声时列。
            guard owner?.activationPolicy == .regular || client.isPlaying || isSystemSounds else { continue }
            let name = isSystemSounds
                ? "系统提示音"
                : (owner?.localizedName ?? appBundleID ?? "音频进程 \(client.pid)")
            let key = appBundleID ?? "pid:\(client.pid)"
            // appBundleID = 宿主 bundle(浏览器 helper 归因后身份跟宿主走),
            // 图标查宿主才对;pid 行 = nil。
            result.append(AttributedVolumeClient(
                client: client, appKey: key, appName: name, appBundleID: appBundleID
            ))
        }
        return result
    }

    /// 音频进程 → 宿主常规 app:直配 pid → bundleID 精确 → bundle 前缀 → 可选
    /// 归因 SPI(浏览器 WebKit helper 不一定共享前缀)→ 自身兜底。
    @MainActor
    private static func ownerApplication(
        pid: pid_t,
        bundleID: String?,
        regular: [NSRunningApplication]
    ) -> NSRunningApplication? {
        if let direct = regular.first(where: { $0.processIdentifier == pid }) {
            return direct
        }
        if let bundleID {
            if let exact = regular.first(where: { $0.bundleIdentifier == bundleID }) {
                return exact
            }
            if let prefix = regular
                .filter({ app in app.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false })
                .max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) {
                return prefix
            }
        }
        // 动态解析的 macOS 归因 SPI(mixbar 经 Fader 借用):缺失即退回,不依赖。
        if let resolve = responsiblePIDFunction {
            let owner = resolve(pid)
            if owner > 0, let app = NSRunningApplication(processIdentifier: owner),
               app.activationPolicy == .regular {
                return app
            }
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    // MARK: 图标(feature 行缓存用)

    /// bundleID → app 图标(bundleID 缺失的 pid 行给 nil,视图回 SF Symbol)。
    @MainActor
    static func appIcon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.hasPrefix("pid:"),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
