import AppKit
import PulseCore
import SwiftUI
import UserNotifications

/// 进程入口:xctest 宿主只起空壳 App(TestHostApp),真实运行才走完整装配。
/// 单元测试托管在 app 内(TEST_HOST 同进程),宿主若走 PulseApp,拉起即建
/// SystemMonitor → 以读写方式打开生产历史库、启动真实采样与落库、读真实
/// 项目根与告警设置——与 /Applications 里的常驻实例同写一份库
/// (2026-10-19 实测,回归钉见 TestHostIsolationTests)。
@main
enum PulseMain {
    @MainActor
    static func main() {
        if LogService.isRunningTests() {
            TestHostApp.main()
        } else {
            PulseApp.main()
        }
    }
}

/// 测试宿主空壳:无菜单栏项、无采样、无历史库、无通知 delegate——
/// 测试需要的对象一律在用例内自行注入构造。
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct PulseApp: App {
    /// 项目根配置(工单 07):UserDefaults 持久,设置窗编辑的唯一事实来源。
    @State private var rootsStore: ProjectRootsStore
    /// 采样管线持有者:app 生命周期内常驻(@State 在 App 中只创建一次)。
    /// 拉起即喂入已持久化的项目根——重启后项目归因即刻可用。
    @State private var monitor: SystemMonitor
    /// 菜单栏徽标显示快照(badge-hysteresis/01):标签唯一数据源,原始读数折算
    /// 出这里(迟滞后值不变不赋值,标签属性图不逐轮翻搅)。观察在 `.task` 里启动。
    @State private var badgeDisplay: MenuBarBadgeDisplayModel
    /// 告警通知路由(工单 07):UNUserNotificationCenter delegate,点通知直达。
    @State private var alertRouter: AlertNotificationRouter
    /// 开窗环境(点通知广播的响应点在标签视图修饰链上)。
    @Environment(\.openWindow) private var openWindow

    init() {
        _ = LogService.shared // 拉起即建文件日志通道(~/.Pulse/logs,含退出留痕观察者)
        let store = ProjectRootsStore()
        _rootsStore = State(initialValue: store)
        let monitor = SystemMonitor.live(projectRoots: store.projectRoots)
        _monitor = State(initialValue: monitor)
        // 原始读数折叠与标签旧 body 同源同口径(CPU / 内存 / 磁盘容量 / 网络速率);
        // 读数源的每次变化都驱动一次折算,折算结果不变就不发布。
        _badgeDisplay = State(initialValue: MenuBarBadgeDisplayModel {
            MenuBarBadgeData(
                cpuLoadPercent: monitor.systemCPULoad,
                memory: monitor.memory,
                diskAvailableBytes: monitor.disk.capacity?.availableForImportantUsageBytes,
                diskTotalBytes: monitor.disk.capacity?.containerTotalBytes,
                networkRate: monitor.network.reading?.rates
            )
        })
        // delegate 必须在通知到达前挂上(app 拉起即挂;点开横幅 → 路由到主窗口)。
        let router = AlertNotificationRouter()
        UNUserNotificationCenter.current().delegate = router
        _alertRouter = State(initialValue: router)
        // 主窗口可见即守卫一次(2026-10-16 验收走查:外接屏断电时窗口被系统恢复到
        // 幻影屏坐标,AppKit 层观察比 SwiftUI 视图钩子更早更稳);启动后延迟一拍
        // 兜底覆盖状态恢复创建的窗口。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == MainWindowSceneID.value || window.title == "Pulse"
            else { return }
            MainWindowView.repositionIfOffscreen()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainWindowView.repositionIfOffscreen()
        }
        LogService.info("Pulse 启动(项目根 \(store.projectRoots.count) 个)", category: "App")
    }

    var body: some Scene {
        MenuBarExtra {
            // 弹窗内容经可见性门控(popover-leak/01):关闭后视图树不再逐轮重算;
            // onAppear/onDisappear(采样节奏 1s/5s)与 .task(start)都在门控根上。
            MenuBarPopoverGate(monitor: monitor)
        } label: {
            MenuBarLoadLabel(display: badgeDisplay)
                // 菜单栏标签常驻:app 拉起即开始采样(start 幂等)。
                .task { monitor.start() }
                // 设置窗(唯一的项目根编辑入口)增删后,标签视图在此捕获变更,
                // 下一轮采样即以新根归组(工单 07,≤1 轮生效)。
                .onChange(of: rootsStore.projectRoots) { _, roots in
                    monitor.setProjectRoots(roots)
                }
                // 告警通知点开(工单 07):常驻的标签视图响应开窗广播——
                // 激活已由路由完成,这里只负责 openWindow(环境值只存在于视图)。
                .onReceive(NotificationCenter.default.publisher(
                    for: AlertNotificationRouter.openMainWindowNotification
                )) { _ in
                    openWindow(id: MainWindowSceneID.value)
                }
                // 回前台同步授权现状:用户经「打开系统设置」改完切回来,通知降级提示
                // 与蓝牙卡态即时更新(常驻标签是全 app 唯一常在的挂点)。蓝牙是静默
                // 类属性读,不弹窗。
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    Task { await monitor.alerts.syncAuthorizationStatus() }
                    monitor.bluetooth.refreshAuthorization()
                }
        }
        .menuBarExtraStyle(.window)

        // 主窗口(工单 P0.5-01):全部组 + 可排序进程表 + 详情下钻。
        // 入口在弹窗底部"打开主窗口"按钮(用户拍板:合并为单一菜单栏项);
        // 窗口内容不触碰 setPopoverTab:关窗只藏窗,采样节奏不受影响(spec)。
        // 内容经可见性门控(popover-leak/01 主窗口同病同修):关闭后视图树不再
        // 逐轮重算;.task(start)在门控根上。
        Window("Pulse", id: MainWindowSceneID.value) {
            MainWindowGate(monitor: monitor, alertRouter: alertRouter)
        }
        .defaultSize(width: 880, height: 620)

        // 设置窗(工单 07 → 2026-10-16 扩为系统设置式双栏,见 SettingsView):
        // 通用 + 告警(工单 P1-07)+ 项目根目录;入口在弹窗头部齿轮按钮。
        Settings {
            SettingsView(rootsStore: rootsStore, monitor: monitor)
        }
    }
}

/// 菜单栏标签:槽位可配置(工单 09)——默认 CPU / RAM,小标签在数字上方;
/// 槽位顺序、四选一从设置「菜单栏」页来(@AppStorage 同键共享,配置改动
/// 即时生效、重启保留)。CPU 超 70% 变红,RAM 联动内存压力变色。
///
/// 数据源 = 显示快照模型(badge-hysteresis/01):迟滞后的读数是唯一输入,
/// 原始读数每轮在模型内折算、值不变不赋值——本视图的属性图不再逐轮重评估,
/// 位图缓存键随之稳定。colorScheme 与槽位配置两个低频依赖仍由视图直接观察。
///
/// 位图路径的由来(工单 09 实机走查修正):MenuBarExtra 的 label 会被系统重绘成
/// NSStatusItem 内容,SwiftUI 的 foregroundStyle / AttributedString 颜色一律被
/// 剥掉(实测 macOS 26 上数字永远是默认色,只有 Shape 能保住颜色)。因此徽标
/// 用 ImageRenderer 预绘成**带颜色的位图**,以 `.renderingMode(.original)` 交给
/// 系统——这是 SwiftUI 栈下唯一可靠的方式。渲染器见 MenuBarBadge.swift,合成逻辑见 MenuBarBadgeComposer.swift。
struct MenuBarLoadLabel: View {
    /// 显示快照模型(badge-hysteresis/01):见上方"数据源"说明;`.task` 启动观察。
    let display: MenuBarBadgeDisplayModel
    /// 菜单栏深浅外观:正常态文字用白/黑随外观,警示态固定系统色。
    @Environment(\.colorScheme) private var colorScheme
    /// 槽位配置(工单 09):与设置页同键共享,非法值回默认。
    @AppStorage("settings.menuBarBadge") private var badgeConfigRaw = MenuBarBadgeConfiguration.default.rawValue

    var body: some View {
        let contents = MenuBarBadgeComposer.compose(
            MenuBarBadgeConfiguration(rawValue: badgeConfigRaw) ?? .default,
            data: display.data
        )
        Image(
            nsImage: MenuBarBadgeRenderer.image(for: contents, colorScheme: colorScheme)
        )
        .renderingMode(.original)
        .accessibilityLabel("系统状态")
        .accessibilityValue(contents.map { "\($0.caption) \($0.text)" }.joined(separator: ","))
        .task { display.start() }
    }
}
