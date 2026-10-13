import SwiftUI

@main
struct PulseApp: App {
    /// 项目根配置(工单 07):UserDefaults 持久,设置窗编辑的唯一事实来源。
    @State private var rootsStore: ProjectRootsStore
    /// 采样管线持有者:app 生命周期内常驻(@State 在 App 中只创建一次)。
    /// 拉起即喂入已持久化的项目根——重启后项目归因即刻可用。
    @State private var monitor: SystemMonitor

    init() {
        let store = ProjectRootsStore()
        _rootsStore = State(initialValue: store)
        _monitor = State(initialValue: SystemMonitor(projectRoots: store.projectRoots))
    }

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
                // 设置窗(唯一的项目根编辑入口)增删后,标签视图在此捕获变更,
                // 下一轮采样即以新根归组(工单 07,≤1 轮生效)。
                .onChange(of: rootsStore.projectRoots) { _, roots in
                    monitor.setProjectRoots(roots)
                }
        }
        .menuBarExtraStyle(.window)

        // 设置窗(工单 07):项目根目录列表增删;入口在弹窗头部齿轮按钮。
        Settings {
            ProjectRootsSettingsView(store: rootsStore)
        }
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
