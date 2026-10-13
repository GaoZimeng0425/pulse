import SwiftUI

@main
struct PulseApp: App {
    /// 采样管线持有者:app 生命周期内常驻(@State 在 App 中只创建一次)。
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
                // 弹窗开/关 = 采样节奏 1s/5s 的切换信号(合盖省电)。
                .onAppear { monitor.setPopoverVisible(true) }
                .onDisappear { monitor.setPopoverVisible(false) }
                .task { monitor.start() }
        } label: {
            MenuBarLoadLabel(monitor: monitor)
                // 菜单栏标签常驻:app 拉起即开始采样(start 幂等)。
                .task { monitor.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏标签:系统 CPU 负载真实数字,超过 70% 变红。
/// 独立成 View,保证 @Observable 的读取落在视图 body 内——负载变化即时刷新菜单栏。
struct MenuBarLoadLabel: View {
    let monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path.ecg")
            Text(PulseFormat.cpuPercent(monitor.systemCPULoad))
                .monospacedDigit()
        }
        .foregroundStyle(
            monitor.systemCPULoad > SystemMonitor.redThreshold ? Color.red : Color.primary
        )
    }
}
