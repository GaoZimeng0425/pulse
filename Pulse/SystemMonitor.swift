import Foundation
import Observation

/// 呈现层模型(spec 命名 SystemMonitor):持有采样管线,把每轮采样变成可观察状态。
/// 菜单栏数字 = 系统 CPU 负载(GLOSSARY:0–100%,全部核的占用率);
/// 弹窗 = Top-5 组(组 CPU% 降序,系统组参榜)。
///
/// UI 粘合层,按 spec 测试决策不写单元测试;采样 / 差分 / 归组 / 截取逻辑分别在
/// Sampler / CPUDiffer / GroupingEngine / GroupingPipeline 里被单测覆盖。
@Observable
@MainActor
final class SystemMonitor {
    /// 系统 CPU 负载超过该值菜单栏变红(spec:70%)。
    static let redThreshold: Double = 70
    /// 弹窗展示组数(spec:Top-5)。
    static let displayGroupLimit = 5

    /// 系统 CPU 负载,0–100%,随采样跳动。
    private(set) var systemCPULoad: Double = 0
    /// Top-5 组(GLOSSARY 组),组 CPU% 降序;首轮采样前为空,弹窗呈空态。
    private(set) var topGroups: [ProcessGroup] = []
    /// 最近一轮采样留下的下钻输入(工单 06):组卡展开 / 进程详情从这里只读取数,
    /// 下钻不触发额外采集;首轮采样前为 nil(与 topGroups 同空态)。
    private(set) var drilldown: DrilldownState?

    private let sampler: Sampler
    private var pipeline: GroupingPipeline
    private var samplingTask: Task<Void, Never>?
    private var started = false

    init(
        source: any ProcessSource = LiveProcessSource(),
        logicalCoreCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        projectRoots: [String] = []
    ) {
        self.sampler = Sampler(source: source, logicalCoreCount: logicalCoreCount)
        self.pipeline = GroupingPipeline(
            configuration: GroupingConfiguration(
                projectRoots: projectRoots,
                bundleDisplayName: BundleDisplayNameReader.shared.displayName
            ),
            displayLimit: Self.displayGroupLimit
        )
    }

    /// 启动采样循环(默认弹窗关闭节奏 5s):菜单栏数字与组卡从拉起就是真的。
    /// 幂等;由 UI 的 `.task` 触发。weak self:循环与 app 同寿命,不构成保留环。
    func start() {
        guard !started else { return }
        started = true
        let sampler = self.sampler
        samplingTask = Task { [weak self] in
            await sampler.run { [weak self] update in
                guard let self else { return }
                Task { @MainActor in
                    self.apply(update)
                }
            }
        }
    }

    /// 弹窗可见性变化:采样节奏在 5s/1s 间切换(合盖省电,spec)。
    func setPopoverVisible(_ visible: Bool) {
        let sampler = self.sampler
        Task { await sampler.setPopoverVisible(visible) }
    }

    /// 项目根变更(工单 07 设置窗):立即写入管线配置,**下一轮采样即以新根归组**
    /// (增删 ≤1 轮生效);清空列表 = 回到 03 的降级路径。传播逻辑在
    /// GroupingPipelineTests"项目根热更新"用例单测,此处仅 MainActor 粘合。
    func setProjectRoots(_ roots: [String]) {
        pipeline.setProjectRoots(roots)
    }

    /// 一轮采样落地:菜单栏负载 + 出生登记、归组、截 Top-5(纯逻辑在 GroupingPipeline),
    /// 同时构账下钻输入(快照 + 累计登记表 + 进程差分,同轮一致)。
    private func apply(_ update: SamplingUpdate) {
        systemCPULoad = update.diff.systemCPULoad
        topGroups = pipeline.update(
            snapshot: update.snapshot,
            processCPU: update.diff.processCPU
        )
        drilldown = DrilldownState(
            snapshot: update.snapshot,
            lineage: pipeline.lineage,
            processCPU: update.diff.processCPU
        )
    }
}
