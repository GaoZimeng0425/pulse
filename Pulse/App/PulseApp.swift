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
    /// 清理页排除目录(p4-cleaner/04):UserDefaults 持久;主窗口清理页右键与设置窗
    /// 「清理」页共用这一实例(排除只收窄,两处同源才不会各看一份)。
    @State private var cleanExclusions = CleanExclusionsStore()
    /// 采样管线持有者:app 生命周期内常驻(@State 在 App 中只创建一次)。
    /// 拉起即喂入已持久化的项目根——重启后项目归因即刻可用。
    @State private var monitor: SystemMonitor
    /// 菜单栏徽标显示快照(badge-hysteresis/01):标签唯一数据源,原始读数折算
    /// 出这里(迟滞后值不变不赋值,标签属性图不逐轮翻搅)。观察在 `.task` 里启动。
    @State private var badgeDisplay: MenuBarBadgeDisplayModel
    /// 告警通知路由(工单 07):UNUserNotificationCenter delegate,点通知直达。
    @State private var alertRouter: AlertNotificationRouter
    /// 菜单栏宿主(popover-layout-loop/01 换轨,stats 路线):NSStatusItem +
    /// NSPopover 承载弹窗与徽标;原常驻标签视图的四件事(采样启动 / 项目根
    /// 变更 / 告警开窗 / 回前台授权同步)全部迁居其内,全 app 常在挂点不缺失。
    @State private var menuBar: MenuBarController
    /// 常驻代理:拒绝「最后窗口关闭即终止」(见 MenuBarController.KeepAliveAppDelegate)。
    @NSApplicationDelegateAdaptor(KeepAliveAppDelegate.self) private var keepAlive

    init() {
        _ = LogService.shared // 拉起即建文件日志通道(~/.Pulse/logs,含退出留痕观察者)
        let store = ProjectRootsStore()
        _rootsStore = State(initialValue: store)
        let monitor = SystemMonitor.live(projectRoots: store.projectRoots)
        _monitor = State(initialValue: monitor)
        // 原始读数折叠与标签旧 body 同源同口径(CPU / 内存 / 磁盘容量 / 网络速率);
        // 读数源的每次变化都驱动一次折算,折算结果不变就不发布。
        let badgeDisplay = MenuBarBadgeDisplayModel {
            MenuBarBadgeData(
                cpuLoadPercent: monitor.systemCPULoad,
                memory: monitor.memory,
                diskAvailableBytes: monitor.disk.capacity?.availableForImportantUsageBytes,
                diskTotalBytes: monitor.disk.capacity?.containerTotalBytes,
                networkRate: monitor.network.reading?.rates
            )
        }
        _badgeDisplay = State(initialValue: badgeDisplay)
        // delegate 必须在通知到达前挂上(app 拉起即挂;点开横幅 → 路由到主窗口)。
        let router = AlertNotificationRouter()
        UNUserNotificationCenter.current().delegate = router
        _alertRouter = State(initialValue: router)
        // 菜单栏宿主:创建即接管状态项 / 弹窗 / 徽标与四件迁居事项。
        _menuBar = State(initialValue: MenuBarController(
            monitor: monitor,
            badgeDisplay: badgeDisplay,
            rootsStore: store
        ))
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
        // 菜单栏(弹窗 + 徽标)由 MenuBarController 承载(popover-layout-loop/01
        // 换轨:macOS 26 上 MenuBarExtra(.window) 弹窗打开期间系统逐帧重排其
        // 窗口树,内容/徽标三轮对照证伪后弃用,改 NSStatusItem + NSPopover)。

        // 主窗口(工单 P0.5-01):全部组 + 可排序进程表 + 详情下钻。
        // 入口在弹窗底部"打开主窗口"按钮(用户拍板:合并为单一菜单栏项);
        // 窗口内容不触碰 setPopoverTab:关窗只藏窗,采样节奏不受影响(spec)。
        // 内容经可见性门控(popover-leak/01 主窗口同病同修):关闭后视图树不再
        // 逐轮重算;.task(start)在门控根上。根部挂开窗桥捕获(AppKit 侧
        // 告警路由/弹窗按钮经 MainWindowBridge 调用)。
        Window("Pulse", id: MainWindowSceneID.value) {
            MainWindowGate(monitor: monitor, alertRouter: alertRouter, cleanExclusions: cleanExclusions)
                .background(MainWindowOpenWindowCapture())
        }
        .defaultSize(width: 880, height: 620)
        // 摘除 MenuBarExtra 后本场景成了首个窗口场景,macOS 启动即呈现主窗
        // (实机 880×672 在屏=实锤)——原行为是常驻菜单栏、主窗只按需开,
        // 抑制启动呈现回到原语义。开窗桥若因此不再启动即捕获(见
        // MainWindowOpenWindowCapture 打点),退回「启动即藏」方案。
        .defaultLaunchBehavior(.suppressed)

        // 设置窗(工单 07 → 2026-10-16 扩为系统设置式双栏,见 SettingsView):
        // 通用 + 告警(工单 P1-07)+ 项目根目录 + 清理(p4-cleaner/04 排除目录);入口在弹窗头部齿轮按钮。
        // 根部同挂开窗桥(主窗口内容若尚未建,这里兜底捕获)。
        Settings {
            SettingsView(rootsStore: rootsStore, cleanExclusions: cleanExclusions, monitor: monitor)
                .background(MainWindowOpenWindowCapture())
        }
    }
}
