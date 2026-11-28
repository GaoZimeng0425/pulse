import PulseCore
import SwiftUI

// 弹窗内容门控(popover-leak/01):MenuBarExtra(.window) 的内容视图在弹窗关闭后
// 不销毁——排行 / 走势整页在无窗状态下继续随采样轮逐轮重算(隐形观看态,直到
// 进程重启;证据见票)。本视图按 monitor.popoverVisible(单一事实源 =
// MonitorVisibility,写路径 setPopoverTab)条件渲染:不可见时只放一块与
// 上次同尺寸的透明占位,不读任何逐轮变化的 observable——采样轮落地不再翻搅
// 弹窗视图树,常驻回到真稳态。
// p2-review/05:上报**所在 tab** 而非裸布尔——弹窗停在 CPU 等无传感器内容的
// tab 不再白开 GPU/SMC/蓝牙/容器采集(MonitorVisibility.shows)。

/// 弹窗内容根:可见性门控 + 会话状态持有。tab 选择与 DashboardModel(展开组、
/// 处置请求等)提升到本层——条件渲染会随关闭销毁 DashboardView 的 @State,不提升
/// 则每次重开都回总览、丢展开(泄漏时代反而有这份"记忆",不得倒退)。占位帧与面板
/// 同尺寸(`DashboardView.panelSize` 令牌;面板定高后不再实测内容,popover-header/01)。
struct MenuBarPopoverGate: View {
    let monitor: SystemMonitor

    /// 两窗共用呈现模型(评审 F4):弹窗这一份在本层常驻,重开不重建。
    @State private var model: DashboardModel
    /// 上次所在 tab,重开还原。
    @State private var lastTab: MetricTab = .overview

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        _model = State(initialValue: DashboardModel(monitor: monitor))
    }

    var body: some View {
        Group {
            if monitor.popoverVisible {
                DashboardView(
                    monitor: monitor,
                    initialTab: lastTab,
                    model: model,
                    onTabChange: {
                        lastTab = $0
                        monitor.setPopoverTab($0)
                    }
                )
            } else {
                Color.clear.frame(
                    width: DashboardView.panelSize.width,
                    height: DashboardView.panelSize.height
                )
            }
        }
        // 可见性开合只由 AppKit 层 MenuBarController.openPanel / closePanel 上报,本视图
        // 只续报弹窗开着时的 tab 切换(onTabChange)。不在 onAppear / onDisappear 里写:
        // 面板从没上屏时 onAppear 照样触发、onDisappear 永不触发(phantom-popover,
        // 2026-11-28 探针实测)——「重开主窗口」路径会顺手建出面板,Pulse 便认定弹窗
        // 开着,采样卡 1s、隐形弹窗每秒整页重算(实测 ~15% CPU → 复位后 1.6%)。
        // 菜单栏标签常驻:app 拉起即开始采样(start 幂等)。
        .task { monitor.start() }
    }
}
