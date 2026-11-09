import AppKit
import PulseCore

// MARK: - mcp-clean/01:AI 清理请求的 app 侧中枢(@MainActor,app 常驻)

//
// 分工(见 .scratch/mcp-clean/spec.md):
// - 列清单:主窗口活模型优先(含实时重扫);关窗退影子模型(同装配,restoreCache
//   只读,永不扫描/不清删——p4「关窗即销毁、稳态零增量」的架构不动)。
// - 真清理:勾选**替换**为求交后的安全档 → requestClean 弹既有确认单 → 轮询
//   cleanPhase 等用户点头;超时 cancelClean 撤单,关窗如实报失败。
// 求交/文案在 PulseCore McpCleanSupport(可测),本类只做编排。

@MainActor
final class McpCleanBridge {
    /// 主窗口清理页模型(窗口可见期间由 MainWindowView attach;nil = 关窗)。
    private(set) weak var windowModel: CleanerModel?
    /// 影子模型(常驻):关窗时列清单的数据面。只读缓存,别的不干。
    private let shadowModel: CleanerModel
    /// 拉起主窗口到清理页(生产 = AlertNotificationRouter.activate(tab: .cleaner),
    /// 激活 + 记落点 + 广播开窗三合一;测试注入空闭包)。
    private let focusCleanerTab: @MainActor () -> Void
    /// 冷开窗后等窗口模型 attach 的上限(秒)。
    private let windowWaitSeconds: Int
    /// 确认单等待上限(秒);到点 cancelClean 撤单。
    private let confirmTimeoutSeconds: Int
    /// 等待轮询步长(测试注小值加快收敛)。
    private let pollSeconds: Double
    /// 影子模型缓存装载的等待上限(秒)。
    private let cacheWaitSeconds: Int

    /// 单飞:同一时刻只受理一个 clean 请求(第二个直接 busy)。
    private var inFlightClean = false

    init(
        shadowModel: CleanerModel,
        focusCleanerTab: @escaping @MainActor () -> Void,
        windowWaitSeconds: Int = 60,
        confirmTimeoutSeconds: Int = 600,
        pollSeconds: Double = 0.3,
        cacheWaitSeconds: Int = 10
    ) {
        self.shadowModel = shadowModel
        self.focusCleanerTab = focusCleanerTab
        self.windowWaitSeconds = windowWaitSeconds
        self.confirmTimeoutSeconds = confirmTimeoutSeconds
        self.pollSeconds = pollSeconds
        self.cacheWaitSeconds = cacheWaitSeconds
    }

    // MARK: 窗口模型挂接

    func attachWindowModel(_ model: CleanerModel) {
        windowModel = model
    }

    func detachWindowModel() {
        windowModel = nil
    }

    // MARK: 列清单(/cleanable)

    func cleanableList() async -> McpCleanableListResponse {
        if let model = windowModel {
            return list(from: model)
        }
        // 关窗:影子模型按需装载缓存(幂等;已在装/已有结果都直接走)。
        shadowModel.loadCachedScan()
        let deadline = Date().addingTimeInterval(TimeInterval(cacheWaitSeconds))
        while shadowModel.isRestoringCache, Date() < deadline {
            try? await Task.sleep(for: .seconds(pollSeconds))
        }
        return list(from: shadowModel)
    }

    private func list(from model: CleanerModel) -> McpCleanableListResponse {
        let entries = model.currentActivityEntries()
        let now = Date()
        let items = model.candidates
            .filter { $0.tier == .safe && model.inUseReasons(for: $0, entries: entries) == nil }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            .map {
                McpCleanableItem(
                    title: $0.title,
                    path: $0.path,
                    group: $0.group.title,
                    bytes: $0.bytes,
                    idleText: McpCleanText.idleText(epoch: $0.newestChangeEpoch, now: now)
                )
            }
        return McpCleanableListResponse(
            items: items,
            scanFinishedAtEpoch: model.scanFinishedAt?.timeIntervalSince1970
        )
    }

    // MARK: 清理(/clean)

    func submit(paths: [String]) async -> McpCleanRunResponse {
        guard !inFlightClean else {
            return McpCleanRunResponse(status: .busy)
        }
        inFlightClean = true
        defer { inFlightClean = false }

        // 1) 找执行模型:窗口活着直连;不活先拉窗(用户要看到确认单),等 attach。
        let model: CleanerModel
        if let windowModel {
            model = windowModel
        } else {
            focusCleanerTab()
            let deadline = Date().addingTimeInterval(TimeInterval(windowWaitSeconds))
            while windowModel == nil, Date() < deadline {
                try? await Task.sleep(for: .seconds(pollSeconds))
            }
            guard let attached = windowModel else {
                return McpCleanRunResponse(status: .noWindow)
            }
            model = attached
        }

        // 2) busy 拦截:app 里已有确认单/清理在跑(用户自己或上一个请求)。
        guard model.isCleanPhaseIdleOrFinished else {
            return McpCleanRunResponse(status: .busy)
        }

        // 3) 求交(安全档 ∩ 非在用,现查活动):不安全路径原样退回。
        let matched = McpCleanMatching.match(
            requestedPaths: paths,
            candidates: model.candidates,
            activityEntries: model.currentActivityEntries()
        )
        guard !matched.matched.isEmpty else {
            return McpCleanRunResponse(status: .emptySelection, unrecognized: matched.unrecognized)
        }

        // 4) 替换勾选 → 弹既有确认单 → 等用户。
        model.applyExternalSelection(matched.matched)
        model.requestClean()
        guard model.cleanPhase == .confirming else {
            // requestClean 的空计划护栏(求交后到弹单之间全转为在用)——如实说。
            return McpCleanRunResponse(
                status: .emptySelection,
                unrecognized: matched.unrecognized,
                message: "这些项刚刚转入在用保护,未弹确认单"
            )
        }

        // 5) 等终态:finished = 执行完;idle = 用户取消;窗口中途被关 = 如实失败。
        let deadline = Date().addingTimeInterval(TimeInterval(confirmTimeoutSeconds))
        while Date() < deadline {
            if windowModel !== model {
                return McpCleanRunResponse(
                    status: .appError,
                    items: [],
                    unrecognized: matched.unrecognized,
                    message: "主窗口被关闭,确认单未完成"
                )
            }
            switch model.cleanPhase {
            case let .finished(report, _):
                return McpCleanRunResponse(
                    status: .confirmed,
                    items: McpCleanText.runItems(from: report),
                    unrecognized: matched.unrecognized
                )
            case .idle:
                return McpCleanRunResponse(
                    status: .cancelledByUser,
                    unrecognized: matched.unrecognized
                )
            case .confirming, .running:
                break
            }
            try? await Task.sleep(for: .seconds(pollSeconds))
        }

        // 6) 超时撤单(只在还停在确认时撤;running 不打断——用户点了就让它跑完)。
        if model.cleanPhase == .confirming {
            model.cancelClean()
        }
        return McpCleanRunResponse(status: .timeout, unrecognized: matched.unrecognized)
    }
}

// MARK: - 阶段判据小助手

extension CleanerModel {
    /// mcp-clean:外部请求只认空态/结果态;确认中/执行中一律 busy。
    var isCleanPhaseIdleOrFinished: Bool {
        switch cleanPhase {
        case .idle, .finished: true
        case .confirming, .running: false
        }
    }
}
