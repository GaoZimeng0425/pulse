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

        // 设置窗(工单 07):项目根目录列表增删;入口在弹窗头部齿轮按钮。
        Settings {
            ProjectRootsSettingsView(store: rootsStore)
        }
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
    /// 菜单栏深浅外观:正常态文字用白/黑随外观,警示态固定系统色。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 用户拍板(2026-10-15):菜单栏双读数——CPU / RAM,小标签在数字上方。
        // CPU 口径 = 系统 CPU 负载(0–100%);RAM = 已用占总内存百分比,
        // 颜色联动内存压力(偏高橙/紧张红,数据来自 host_statistics64)。
        HStack(spacing: 5) {
            menuBadge(
                caption: "CPU",
                value: PulseFormat.cpuPercent(monitor.systemCPULoad),
                color: monitor.systemCPULoad > SystemMonitor.redThreshold ? .red : nil
            )
            menuBadge(
                caption: "RAM",
                value: ramPercentText,
                color: ramColor
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("系统状态")
        .accessibilityValue("CPU \(PulseFormat.cpuPercent(monitor.systemCPULoad)),内存 \(ramPercentText)")
    }

    private var ramPercentText: String {
        guard let memory = monitor.memory, memory.totalBytes > 0 else { return "–" }
        return PulseFormat.cpuPercent(Double(memory.usedBytes) / Double(memory.totalBytes) * 100)
    }

    /// RAM 徽标色:内存压力偏高 → 橙,紧张 → 红;正常 → 随外观墨色。
    private var ramColor: Color? {
        switch monitor.memory?.pressure {
        case .critical: .red
        case .warning: .orange
        default: nil
        }
    }

    private func menuBadge(caption: String, value: String, color: Color?) -> some View {
        Image(
            nsImage: MenuBarBadgeRenderer.stackedImage(
                caption: caption,
                valueText: value,
                valueColor: color,
                colorScheme: colorScheme
            )
        )
        .renderingMode(.original)
    }
}

/// 菜单栏徽标位图渲染器:SwiftUI 视图 → ImageRenderer → NSImage,按
/// (标签, 数字, 颜色, 外观) 缓存——每轮采样最多一次位图化,值不变时零开销。
/// 双读数形态(用户拍板):小标签在数字上方(CPU / RAM),整体高约 22pt 贴菜单栏。
@MainActor
enum MenuBarBadgeRenderer {
    private static var cache: [String: NSImage] = [:]

    static func stackedImage(
        caption: String,
        valueText: String,
        valueColor: Color?,
        colorScheme: ColorScheme
    ) -> NSImage {
        let ink = colorScheme == .dark ? Color.white : Color.black
        let value = valueColor ?? ink
        let key = "\(caption)|\(valueText)|\(valueDescription(valueColor))|\(colorScheme)"
        if let cached = cache[key] { return cached }

        let renderer = ImageRenderer(
            content: VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.55))
                Text(valueText)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(value)
            }
            .padding(.horizontal, 1)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let rendered: NSImage
        if let nsImage = renderer.nsImage {
            rendered = nsImage
        } else {
            // ImageRenderer 失效兜底:退回单行纯文本(不变色,但数字可见)。
            let fallback = NSImage(size: NSSize(width: 48, height: 18))
            fallback.lockFocus()
            (valueText as NSString).draw(
                at: NSPoint(x: 1, y: 2),
                withAttributes: [
                    .font: NSFont.menuBarFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            fallback.unlockFocus()
            rendered = fallback
        }
        rendered.isTemplate = false // 绝不让系统把颜色又模板化掉
        cache[key] = rendered
        return rendered
    }

    /// 缓存键里的颜色标识(nil = 墨色随外观)。
    private static func valueDescription(_ color: Color?) -> String {
        guard let color else { return "ink" }
        if color == .red { return "red" }
        if color == .orange { return "orange" }
        return "custom"
    }
}
