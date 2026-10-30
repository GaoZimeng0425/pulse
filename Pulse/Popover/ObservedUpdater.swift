import AppKit
import Observation

// MARK: - 观察回路(popover-appkit/01)

/// AppKit 面板的刷新机制:`update` 闭包在 `withObservationTracking` 里运行,
/// 只要它读过的 observable 属性有变化,下一拍主线程重放一次——同一拍内的多次
/// 变化只触发一次重放(onChange 每轮追踪只回调一次)。不轮询、不定时:没变化
/// 就零开销,这正是换掉 SwiftUI 的目的(每轮采样全树 diff,spec 依据表)。
@MainActor
final class ObservedUpdater {
    private let update: @MainActor () -> Void
    private var isActive = false
    /// 停止 / 重启时自增:旧追踪轮迟到的回调认不出新一代,直接丢弃。
    private var generation = 0

    init(_ update: @escaping @MainActor () -> Void) {
        self.update = update
    }

    /// 立即跑一次并开始追踪(幂等)。
    func start() {
        guard !isActive else { return }
        isActive = true
        generation += 1
        run(generation)
    }

    /// 停止追踪:之后到达的变化不再重放。
    func stop() {
        isActive = false
        generation += 1
    }

    private func run(_ token: Int) {
        guard isActive, token == generation else { return }
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.run(token)
            }
        }
    }
}

/// 自带观察回路的视图基类:上窗即开始追踪、离窗即停——面板收起卸下内容树时
/// 回路随之停止,不在无窗状态下继续重画(popover-leak/01 同病同防)。
/// 子类覆写 `update()`,只读本卡要画的数据。
@MainActor
class ObservingView: FlippedView {
    private lazy var updater = ObservedUpdater { [weak self] in self?.update() }

    /// 读模型、写子视图。在观察回路里调用,读到的属性变化后自动重放。
    func update() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            updater.stop()
        } else {
            updater.start()
        }
    }
}
