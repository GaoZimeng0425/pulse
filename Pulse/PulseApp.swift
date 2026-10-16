import SwiftUI
import AppKit

@main
struct PulseApp: App {
    /// 项目根配置(工单 07):UserDefaults 持久,设置窗编辑的唯一事实来源。
    @State private var rootsStore: ProjectRootsStore
    /// 采样管线持有者:app 生命周期内常驻(@State 在 App 中只创建一次)。
    /// 拉起即喂入已持久化的项目根——重启后项目归因即刻可用。
    @State private var monitor: SystemMonitor

    init() {
        _ = LogService.shared // 拉起即建文件日志通道(~/.Pulse/logs,含退出留痕观察者)
        let store = ProjectRootsStore()
        _rootsStore = State(initialValue: store)
        _monitor = State(initialValue: SystemMonitor(projectRoots: store.projectRoots))
        LogService.info("Pulse 启动(项目根 \(store.projectRoots.count) 个)", category: "App")
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

        // 主窗口(工单 P0.5-01):全部组 + 可排序进程表 + 详情下钻。
        // 入口在弹窗底部"打开主窗口"按钮(用户拍板:合并为单一菜单栏项);
        // 窗口内容不触碰 setPopoverVisible:关窗只藏窗,采样节奏不受影响(spec)。
        Window("Pulse", id: MainWindowSceneID.value) {
            MainWindowView(monitor: monitor)
                // 菜单栏标签拉起即启动采样(start 幂等);此处再提一次,
                // 让预览 / 理论上的窗口先行场景同样有数据。
                .task { monitor.start() }
        }
        .defaultSize(width: 880, height: 620)

        // 设置窗(工单 07 → 2026-10-16 扩为系统设置式双栏,见 SettingsView):
        // 通用(登录自启/日志/诊断报告/版本)+ 项目根目录;入口在弹窗头部齿轮按钮。
        Settings {
            SettingsView(rootsStore: rootsStore, monitor: monitor)
        }
    }
}

/// 菜单栏标签:槽位可配置(工单 09)——默认 CPU / RAM,小标签在数字上方;
/// 槽位顺序、四选一从设置「菜单栏」页来(@AppStorage 同键共享,配置改动
/// 即时生效、重启保留)。CPU 超 70% 变红,RAM 联动内存压力变色。独立成
/// View,保证 @Observable 的读取落在视图 body 内——负载变化即时刷新菜单栏。
///
/// 位图路径的由来(工单 09 实机走查修正):MenuBarExtra 的 label 会被系统重绘成
/// NSStatusItem 内容,SwiftUI 的 foregroundStyle / AttributedString 颜色一律被
/// 剥掉(实测 macOS 26 上数字永远是默认色,只有 Shape 能保住颜色)。因此徽标
/// 用 ImageRenderer 预绘成**带颜色的位图**,以 `.renderingMode(.original)` 交给
/// 系统——这是 SwiftUI 栈下唯一可靠的方式。渲染器与合成逻辑见 MenuBarBadge.swift。
struct MenuBarLoadLabel: View {
    let monitor: SystemMonitor
    /// 菜单栏深浅外观:正常态文字用白/黑随外观,警示态固定系统色。
    @Environment(\.colorScheme) private var colorScheme
    /// 槽位配置(工单 09):与设置页同键共享,非法值回默认。
    @AppStorage("settings.menuBarBadge") private var badgeConfigRaw = MenuBarBadgeConfiguration.default.rawValue

    var body: some View {
        // 用户拍板(2026-10-15):菜单栏双读数——CPU / RAM,小标签在数字上方。
        // 工单 09 起读数清单可配置(1–3 槽四选一),默认 [CPU, RAM] 与该形态
        // 逐像素一致;数据快照在此从 SystemMonitor 折叠,映射在纯函数层。
        let contents = MenuBarBadgeComposer.compose(
            MenuBarBadgeConfiguration(rawValue: badgeConfigRaw) ?? .default,
            data: MenuBarBadgeData(
                cpuLoadPercent: monitor.systemCPULoad,
                memory: monitor.memory,
                diskAvailableBytes: monitor.diskCapacity?.availableForImportantUsageBytes,
                networkRate: monitor.networkRate
            )
        )
        Image(
            nsImage: MenuBarBadgeRenderer.image(for: contents, colorScheme: colorScheme)
        )
        .renderingMode(.original)
        .accessibilityLabel("系统状态")
        .accessibilityValue(contents.map { "\($0.caption) \($0.text)" }.joined(separator: ","))
    }
}
