import AppKit
import PulseCore
import SwiftUI

/// 菜单栏宿主(popover-layout-loop/01 换轨,stats 路线):macOS 26 上
/// MenuBarExtra(.window) 的弹窗打开期间,系统对其窗口树逐帧重排——弹窗内容
/// 与徽标经 A/B/C 三轮对照全部证伪(静态内容照样 40-60%),NSPopover 探针承载
/// 同款内容实测 0-1%(证据与哨兵日志见票)。唯一解是弃用 MenuBarExtra:
///
/// - 弹窗内容与可见性门控(MenuBarPopoverGate)原样复用;门控的 onDisappear
///   之外,popoverWillClose 在 AppKit 层先清一次旗标(popover-leak/01 的教训:
///   关闭信号必须双保险);
/// - 徽标位图(渲染器 + LRU 缓存,值不变返回同一实例)原样复用,产物直接挂
///   `button.image`——NSStatusBarButton 不剥位图颜色;
/// - 原常驻 MenuBarExtra 标签视图承担的四件事(采样启动 / 项目根变更喂给
///   归组 / 告警通知开主窗 / 回前台授权同步)全部迁居到本控制器——全 app
///   唯一常在的挂点从 SwiftUI 视图换成 AppKit 对象,生命周期与 app 同寿。
@MainActor
final class MenuBarController: NSObject {
    private let monitor: SystemMonitor
    private let badgeDisplay: MenuBarBadgeDisplayModel
    private let rootsStore: ProjectRootsStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var badgeConfigRaw: String

    /// 与设置页同键共享(p1-history/09 槽位配置契约)。
    private static let badgeConfigKey = "settings.menuBarBadge"

    init(monitor: SystemMonitor, badgeDisplay: MenuBarBadgeDisplayModel, rootsStore: ProjectRootsStore) {
        self.monitor = monitor
        self.badgeDisplay = badgeDisplay
        self.rootsStore = rootsStore
        badgeConfigRaw = UserDefaults.standard.string(forKey: Self.badgeConfigKey)
            ?? MenuBarBadgeConfiguration.default.rawValue
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // 弹窗:transient = 点外部自动收起(stats 同款);内容即既有门控视图,
        // 面板尺寸跟随 NSHostingController 的 preferredContentSize 自适应,
        // 首开尺寸与门控内占位帧口径一致(DashboardView 定宽 360)。
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = CGSize(width: 360, height: 648)
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverGate(monitor: monitor))

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        monitor.start() // 幂等;app 拉起即采样(原标签视图 .task 迁居)
        badgeDisplay.start() // 徽标观察自续环(幂等;原 MenuBarLoadLabel.task 迁居)
        updateBadgeImage()
        armBadgeObservation()
        armRootsObservation()

        let center = NotificationCenter.default
        // 告警通知点开 → 开主窗口(激活已由路由完成,这里只开窗)。
        center.addObserver(
            forName: AlertNotificationRouter.openMainWindowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in MainWindowBridge.open() }
        }
        // 回前台同步授权现状:用户经「打开系统设置」改完切回来,通知降级提示
        // 与蓝牙卡态即时更新(蓝牙是静默类属性读,不弹窗)。
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.monitor.alerts.syncAuthorizationStatus()
                self.monitor.bluetooth.refreshAuthorization()
            }
        }
        // 槽位配置(设置页写 UserDefaults)→ 徽标重算。didChange 对任何 defaults
        // 写入都响,读回配置键比对幂等收窄。
        center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let raw = UserDefaults.standard.string(forKey: Self.badgeConfigKey)
                    ?? MenuBarBadgeConfiguration.default.rawValue
                if raw != self.badgeConfigRaw {
                    self.badgeConfigRaw = raw
                    self.updateBadgeImage()
                }
            }
        }
        // 系统外观切换 → 徽标墨色随外观(渲染缓存键含外观,命中无损)。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateBadgeImage() }
        }
    }

    // MARK: - 弹窗开合

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - 徽标

    private func updateBadgeImage() {
        let contents = MenuBarBadgeComposer.compose(
            MenuBarBadgeConfiguration(rawValue: badgeConfigRaw) ?? .default,
            data: badgeDisplay.data
        )
        statusItem.button?.image = MenuBarBadgeRenderer.image(
            for: contents,
            colorScheme: isDarkAppearance ? .dark : .light
        )
        statusItem.button?.toolTip = contents.map { "\($0.caption) \($0.text)" }
            .joined(separator: "  ")
    }

    private var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 徽标观察自续环:显示快照真变才换图(旧标签的 SwiftUI 属性图依赖换成
    /// 显式 onChange 重挂,与 MenuBarBadgeDisplayModel.arm 同构;值不变时渲染
    /// 器缓存返回同一 NSImage 实例,系统零重绘)。
    private func armBadgeObservation() {
        withObservationTracking {
            _ = badgeDisplay.data
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateBadgeImage()
                self.armBadgeObservation()
            }
        }
    }

    /// 项目根增删(设置窗)→ 喂给归组,下一轮采样生效(工单 07,≤1 轮)。
    private func armRootsObservation() {
        withObservationTracking {
            _ = rootsStore.projectRoots
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.monitor.setProjectRoots(self.rootsStore.projectRoots)
                self.armRootsObservation()
            }
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    /// 关闭的可靠信号:AppKit 层先清可见性旗标(门控视图 onDisappear 兜底,
    /// 双保险;popover-leak/01 语义不变)。顺手清按钮高亮残留(transient 关闭
    /// 后 NSStatusItem 不自动复位)。
    func popoverWillClose(_ notification: Notification) {
        monitor.setPopoverTab(nil)
        statusItem.button?.isHighlighted = false
    }
}

/// 主窗口开窗桥:`openWindow` 是 SwiftUI 场景环境值,只有视图拿得到;Window
/// 场景内容启动即建(2026-10-29 探针实证 NSApp.windows 里常驻),根部捕获一次
/// 即可供 AppKit 侧全程调用。捕获点两处(主窗口 / 设置窗根部),谁先出现谁填;
/// 同一 action 重复覆盖无害。
@MainActor
enum MainWindowBridge {
    static var openWindow: OpenWindowAction?

    static func open() {
        if let openWindow {
            openWindow(id: MainWindowSceneID.value)
        } else {
            // 桥未就绪的兜底:至少把 app 拉到前台(窗口从未建过且桥未捕获的
            // 窗口期,理论上只在启动首毫秒)。
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// 桥的捕获视图:零尺寸、零交互,只借 onAppear 存一次环境动作。
struct MainWindowOpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear { MainWindowBridge.openWindow = openWindow }
    }
}
