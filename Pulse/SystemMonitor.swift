import Foundation
import Observation

/// 呈现层模型(spec 命名 SystemMonitor):持有采样管线,把差分结果变成可观察状态。
/// 菜单栏数字 = 系统 CPU 负载(GLOSSARY:0–100%,全部核的占用率)。
///
/// UI 粘合层,按 spec 测试决策不写单元测试;管线逻辑全部在
/// Sampler / CPUDiffer / SamplingScheduler 里被单测覆盖。
@Observable
@MainActor
final class SystemMonitor {
    /// 系统 CPU 负载超过该值菜单栏变红(spec:70%)。
    static let redThreshold: Double = 70

    /// 系统 CPU 负载,0–100%,随采样跳动。
    private(set) var systemCPULoad: Double = 0

    private let sampler: Sampler
    private var samplingTask: Task<Void, Never>?
    private var started = false

    init(
        source: any ProcessSource = LiveProcessSource(),
        logicalCoreCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.sampler = Sampler(source: source, logicalCoreCount: logicalCoreCount)
    }

    /// 启动采样循环(默认弹窗关闭节奏 5s):菜单栏数字从拉起就是真的。
    /// 幂等;由 UI 的 `.task` 触发。weak self:循环与 app 同寿命,不构成保留环。
    func start() {
        guard !started else { return }
        started = true
        let sampler = self.sampler
        samplingTask = Task { [weak self] in
            await sampler.run { [weak self] diff in
                guard let self else { return }
                Task { @MainActor in
                    self.systemCPULoad = diff.systemCPULoad
                }
            }
        }
    }

    /// 弹窗可见性变化:采样节奏在 5s/1s 间切换(合盖省电,spec)。
    func setPopoverVisible(_ visible: Bool) {
        let sampler = self.sampler
        Task { await sampler.setPopoverVisible(visible) }
    }
}
