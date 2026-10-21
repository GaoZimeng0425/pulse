import Observation
import PulseCore

// 菜单栏徽标显示快照(badge-hysteresis/01):迟滞状态机(BadgeDisplayHysteresis,
// PulseCore)的 app 薄壳——观察原始读数源,每轮折算成显示快照,**值不变不赋值**。
// 这是压掉稳态残差的关键一跳:标签视图只读这里的快照,不再直读 SystemMonitor /
// 各功能模块的原始读数,原始读数每轮变化不再触发标签的 SwiftUI 属性图失效。

/// 菜单栏徽标的显示快照模型:原始读数 → `BadgeDisplayHysteresis` → `data`。
/// 观察靠 `withObservationTracking` 自续环:onChange 跳回 MainActor 读新值、
/// 折算、再挂下一轮观察(reads 发生在视图 body 之外,不构成任何视图依赖)。
/// 每轮成本 = 一次取值 + 一次纯值折算(微秒级);状态发布只在显示值真变时发生。
@MainActor
@Observable
final class MenuBarBadgeDisplayModel {
    /// 当前显示快照。初值全占位;`start()` 立即整体采纳首读(nil→值立即)。
    /// 每次赋值 = 标签一次合法刷新(数字换了 / 强调级变了 / 网络槽刷新)。
    private(set) var data = MenuBarBadgeData()

    /// 原始读数折叠(与标签旧 body 的取数同源):读到的正是被观察的属性。
    private let raw: () -> MenuBarBadgeData
    private var started = false

    init(raw: @escaping () -> MenuBarBadgeData) {
        self.raw = raw
    }

    /// 启动观察(幂等;由标签视图的 `.task` 触发,app 拉起即生效)。
    func start() {
        guard !started else { return }
        started = true
        refresh()
        arm()
    }

    /// 挂一轮观察:onChange 在属性 willSet 时同步触发,值尚未落定——跳一拍
    /// MainActor Task 再读,顺手重挂(连续多属性同轮变更会排队多次,折算幂等,
    /// 微秒级,合并无必要)。weak self:模型与 app 同寿命,防保留环只为例行。
    private func arm() {
        withObservationTracking {
            _ = raw()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.arm()
            }
        }
    }

    /// 折算 + 条件赋值:输出与当前显示快照相等就不赋值——不赋值即无 SwiftUI
    /// 失效,属性图 / CA 提交 / 位图缓存全部不动(resident-cost/01 残差的靶子)。
    private func refresh() {
        let next = BadgeDisplayHysteresis.update(displayed: data, incoming: raw())
        if next != data {
            data = next
        }
    }
}
