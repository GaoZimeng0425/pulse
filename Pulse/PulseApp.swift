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

        // 主窗口(工单 P0.5-01):全部组(非 Top-5)+ 可排序进程表 + 详情下钻。
        // 两个入口打开它——弹窗头部"在窗口中打开"按钮 + 下方第二菜单栏项;
        // 窗口内容不触碰 setPopoverVisible:关窗只藏窗,采样节奏不受影响(spec)。
        Window("Pulse", id: MainWindowSceneID.value) {
            MainWindowView(monitor: monitor)
                // 菜单栏标签拉起即启动采样(start 幂等);此处再提一次,
                // 让预览 / 理论上的窗口先行场景同样有数据。
                .task { monitor.start() }
        }
        .defaultSize(width: 880, height: 620)

        // 第二菜单栏项(工单 P0.5-01 入口二):紧凑图标 + 原生下拉菜单——
        // 打开主窗口 / 设置… / 退出 Pulse(终于有体面的退出)。
        // 原有 CPU 数字弹窗项保持不动(spec:上方 MenuBarExtra)。
        MenuBarExtra {
            AppMenuExtraContent()
        } label: {
            Image(systemName: "waveform.path.ecg")
        }
        .menuBarExtraStyle(.menu)

        // 设置窗(工单 07):项目根目录列表增删;入口在弹窗头部齿轮按钮
        //(P0.5 起菜单栏菜单亦有"设置…"入口)。
        Settings {
            ProjectRootsSettingsView(store: rootsStore)
        }
    }
}

/// 第二菜单栏项内容(工单 P0.5-01):原生菜单三件套。`.menu` 样式下
/// 内容即菜单项(Button 渲染为菜单项);退出走 NSApplication.terminate,
/// LSUIElement 应用由菜单栏体系持有,terminate 是唯一体面的退出路径。
struct AppMenuExtraContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("打开主窗口") {
            openWindow(id: MainWindowSceneID.value)
        }
        Button("设置…") {
            openSettings()
        }
        Divider()
        Button("退出 Pulse") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// 菜单栏标签:系统 CPU 负载真实数字,超过 70% 变红。
/// 独立成 View,保证 @Observable 的读取落在视图 body 内——负载变化即时刷新菜单栏。
///
/// 变红的实现路径(工单 09 实机走查修正):MenuBarExtra 的 label 会被系统重绘成
/// NSStatusItem 标题,SwiftUI 的 foregroundStyle / AttributedString 颜色一律被
/// 剥掉(实测 macOS 26 上数字永远是默认色,只有 Shape 能保住颜色)。因此把
/// 「单一数字」(spec:菜单栏只放一个数字,评审 S2 去掉波形符号——图标与
/// 名称仍保留在弹窗头部)用 ImageRenderer 预绘成**带颜色的位图**,以
/// `.renderingMode(.original)` 交给系统——这是 SwiftUI 栈下唯一可靠的方式。
struct MenuBarLoadLabel: View {
    let monitor: SystemMonitor
    /// 菜单栏深浅外观:正常态文字用白/黑随外观,红色态固定系统红。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let loadText = PulseFormat.cpuPercent(monitor.systemCPULoad)
        Image(
            nsImage: MenuBarBadgeRenderer.image(
                loadText: loadText,
                isRed: monitor.systemCPULoad > SystemMonitor.redThreshold,
                colorScheme: colorScheme
            )
        )
        .renderingMode(.original)
        .accessibilityLabel("系统 CPU 负载")
        .accessibilityValue(loadText)
    }
}

/// 菜单栏徽标位图渲染器:SwiftUI 视图 → ImageRenderer → NSImage,按
/// (数字, 是否红, 外观) 缓存——每轮采样最多一次位图化,且值不变时零开销。
/// 徽标只含数字本身(spec 单一数字口径)。
@MainActor
enum MenuBarBadgeRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(loadText: String, isRed: Bool, colorScheme: ColorScheme) -> NSImage {
        let key = "\(loadText)|\(isRed)|\(colorScheme)"
        if let cached = cache[key] { return cached }

        let color: Color = isRed ? .red : (colorScheme == .dark ? .white : .black)
        let renderer = ImageRenderer(
            content: Text(loadText).monospacedDigit()
                // 与系统菜单栏字号对齐(约 13pt 小号)。
                .font(.system(size: NSFont.systemFontSize(for: .small)))
                .foregroundStyle(color)
                .padding(1)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let rendered: NSImage
        if let nsImage = renderer.nsImage {
            rendered = nsImage
        } else {
            // ImageRenderer 失效兜底:退回纯文本 label(不变色,但数字可见)。
            let fallback = NSImage(size: NSSize(width: 56, height: 18))
            fallback.lockFocus()
            (loadText as NSString).draw(
                at: NSPoint(x: 1, y: 2),
                withAttributes: [
                    .font: NSFont.menuBarFont(ofSize: 0),
                    .foregroundColor: isRed ? NSColor.systemRed : NSColor.labelColor,
                ]
            )
            fallback.unlockFocus()
            rendered = fallback
        }
        rendered.isTemplate = false // 绝不让系统把颜色又模板化掉
        cache[key] = rendered
        return rendered
    }
}
