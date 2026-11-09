import SwiftUI

// 主窗口内容门控(popover-leak/01 主窗口同病同修):Window 场景关闭后 SwiftUI
// 不销毁内容视图树——AX 已 0 窗,排行行仍随采样轮逐轮重算(实测 25 点/15s,
// 2026-10-21 验收指纹)。与弹窗门控(MenuBarPopoverGate)同款机制:按
// monitor.mainWindowVisible(单一事实源 = MonitorVisibility.mainWindowTab 派生)
// 条件渲染,隐藏时只放同尺寸透明占位,不读任何逐轮变化源。
// p2-review/05:写路径收成 tab 槽——关窗 = nil 一次写清在场与所在页;进场
// 引导值与 MainWindowView.init 的初值**同式**(pendingTab ?? 总览),深链开窗
// 不闪错误闸;随后 MainWindowView.onAppear 按实际选中续报(同值 no-op)。
//
// 行为取舍(票内记档):主窗口的页面选择等 @State 随关窗丢弃——与标准 macOS
// "关窗即弃内容"一致;泄漏时代"跨开关记住页面"的副作用就此取消。

/// 弹窗齿轮 → 设置窗的桥信号(2026-11-02):弹窗宿主是 NSPanel,场景环境的
/// openSettings 到不了那里;原先兜底的 AppKit 私有选择子
/// (showSettingsWindow:/showPreferencesWindow:)在本系统上也不再响应(用户实测
/// 点不动)。改由本 Gate(Window 场景内容,启动即建、常驻)接收通知后在
/// Scene 环境里调 openSettings()——与主窗口齿轮同一条已验证通路。
extension Notification.Name {
    static let pulseOpenSettings = Notification.Name("pulseOpenSettings")
}

/// 主窗口内容根:可见性门控 + 启动接线。
struct MainWindowGate: View {
    let monitor: SystemMonitor
    let alertRouter: AlertNotificationRouter
    /// 清理页排除目录(p4-cleaner/04):app 级单实例,与设置页「清理」同源。
    let cleanExclusions: CleanExclusionsStore
    /// 清理扫描根(p4-cleaner/05):app 级单实例,与设置页「清理」同源。
    let cleanScanRoots: CleanScanRootsStore
    /// AI 清理桥(mcp-clean/01):窗口可见期把清理页模型挂给它(列清单活数据 /
    /// clean 请求落确认单);关窗即摘。
    let mcpClean: McpCleanBridge

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if monitor.mainWindowVisible {
                MainWindowView(
                    monitor: monitor,
                    alertRouter: alertRouter,
                    cleanExclusions: cleanExclusions,
                    cleanScanRoots: cleanScanRoots,
                    mcpClean: mcpClean
                )
            } else {
                // 与 Window 场景 defaultSize 同尺寸:窗框在恢复 / 深链路径上不跳动。
                Color.clear.frame(width: 880, height: 620)
            }
        }
        .onAppear { monitor.setMainWindowTab(alertRouter.pendingTab ?? .overview) }
        .onDisappear { monitor.setMainWindowTab(nil) }
        // 菜单栏标签拉起即启动采样(start 幂等);此处再提一次,让预览 /
        // 理论上的窗口先行场景同样有数据。
        .task { monitor.start() }
        // 弹窗齿轮的设置桥(常驻接收;LaunchHiddenWindow 保证本场景内容启动即建)
        .onReceive(NotificationCenter.default.publisher(for: .pulseOpenSettings)) { _ in
            openSettings()
        }
    }
}
