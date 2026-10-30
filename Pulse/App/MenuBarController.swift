import AppKit
import PulseCore
import SwiftUI

/// 菜单栏宿主(popover-layout-loop/01 换轨,stats 路线):macOS 26 上
/// MenuBarExtra(.window) 的弹窗打开期间,系统对其窗口树逐帧重排——弹窗内容
/// 与徽标经 A/B/C 三轮对照全部证伪(静态内容照样 40-60%),AppKit 承载探针
/// 实测 0-1%(证据与哨兵日志见票)。唯一解是弃用 MenuBarExtra。
///
/// 面板按 stats 的 `PopupWindow` 架构(Kit/module/popup.swift)自制 NSPanel,
/// 而非 NSPopover——首轮 NSPopover 版的三个实机 bug 全部由此免疫:
/// - **不激活 app**:styleMask 含 `.nonactivatingPanel`,`makeKeyAndOrderFront`
///   只取键盘焦点不拉 app 前台 → 点菜单永不把主窗口带出来(activate 系列
///   首击被吞/连带开窗问题连根消失);
/// - **收起靠失焦**:windowDidResignKey → orderOut(点外部/切 app 即收,
///   与 transient 语义等价),hidesOnDeactivate = false 防 app 切换误收;
/// - **点按直达**:按钮 mouseDown 触发(附件型 app 首击不再被激活吞)。
///
/// 弹窗内容为 AppKit 原生实现(popover-appkit:SwiftUI 版开期 10–30%,AppKit 探针 2–4%),
/// 可见性信号由本控制器在开/收两处直给(AppKit 时机,不赌 SwiftUI onAppear);
/// 徽标位图(渲染器 + LRU 缓存)直挂 button.image;原常驻标签视图的四件事
/// (采样启动 / 项目根变更 / 告警开窗 / 回前台授权同步)全部迁居于此。
@MainActor
final class MenuBarController: NSObject {
    private let monitor: SystemMonitor
    private let badgeDisplay: MenuBarBadgeDisplayModel
    private let rootsStore: ProjectRootsStore
    private let statusItem: NSStatusItem
    /// 面板懒创建:首开才建。常驻菜单栏 app 启动即零可见窗,提前把
    /// NSVisualEffectView + NSHostingView 塞进一个隐藏面板,等于让窗口服务
    /// 从拉起就养着一棵可能自扰的视图树(40% 空转的头号嫌疑,懒创建一举排除)。
    private lazy var panel: PopupPanel = {
        let p = PopupPanel()
        p.onResignKey = { [weak self] in self?.closePanel() }
        return p
    }()

    /// 两窗共用呈现模型的弹窗这一份(展开组、选中进程、处置汇总):控制器常驻持有,
    /// 面板内容每次开合重建也不丢会话状态(原 MenuBarPopoverGate 的职责)。
    private lazy var dashboardModel = DashboardModel(monitor: monitor)

    /// 弹窗上次所在 tab(收起前留底,重开还原;与门控视图内的 lastTab 同义,
    /// 可见性信号移到 AppKit 层后由控制器持有)。
    private var lastTab: MetricTab = .overview
    private var badgeConfigRaw: String
    /// 收起时刻:点状态按钮收面板时,面板失焦信号与按钮动作的先后不确定——
    /// 短窗内二次到达的点击视为「收下」而非「重开」,防收面板变成关了又开。
    private var closedAt: Date?

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

        // TEMP-EXPERIMENT(popover-layout-loop/01 诊断):静态文本按钮旁路——
        // 探针(纯文本按钮)0-1% vs 本 app(位图按钮)40% 的关键差异二分。
        // defaults debug.staticBadge=YES 时不用位图、不挂徽标观察。
        if UserDefaults.standard.bool(forKey: "debug.staticBadge") {
            statusItem.button?.title = "◍"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // 首击直达:附件型 app(LSUIElement)点状态项的第一次点击默认被系统
        // 拿去激活 app、动作不送达(stats 同款已知问题),改 mouseDown 触发后
        // 激活与动作同击完成——「点两次才展开」即此坑。
        statusItem.button?.sendAction(on: .leftMouseDown)

        // TEMP-EXPERIMENT(终止法医):willTerminate 时留调用栈——进程内
        // terminate 与外部 Apple Event 送达的栈形完全不同,一测定谳。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            LogService.info(
                "terminate 栈:\n" + Thread.callStackSymbols.joined(separator: "\n"),
                category: "PanelProbe"
            )
        }
        // 常驻菜单栏 app 必须 GDPR 自动终止:面板收起后全 app 无可见窗,
        // 系统把「空闲无窗」判为可回收直接优雅杀掉(实机:收面板毫秒级退出)。
        ProcessInfo.processInfo.disableAutomaticTermination("menu-bar-resident")
        monitor.start() // 幂等;app 拉起即采样(原标签视图 .task 迁居)
        let staticBadge = UserDefaults.standard.bool(forKey: "debug.staticBadge")
        badgeDisplay.start() // 徽标观察自续环(幂等;原 MenuBarLoadLabel.task 迁居)
        if !staticBadge {
            updateBadgeImage()
            armBadgeObservation()
        }
        armRootsObservation()
        armNotificationObservers()
        scheduleAutoProbe()
    }

    // MARK: - 面板开合

    @objc private func togglePopover() {
        if panel.isVisible {
            closePanel()
        } else if let closedAt, Date().timeIntervalSince(closedAt) < 0.3 {
            // 失焦刚收过:这一下点击是「收下」的另一半,不再重开。
            return
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        // 可见性信号 AppKit 层直给;内容树每次开面板现建、收起即卸
        // (popover-appkit:关着不留任何观察回路,popover-leak/01 同防)。
        monitor.setPopoverTab(lastTab)
        statusItem.button?.isHighlighted = true
        let root = PopoverRootView(monitor: monitor, model: dashboardModel, initialTab: lastTab) { [weak self] tab in
            self?.lastTab = tab
            self?.monitor.setPopoverTab(tab)
        }
        panel.setContent(root)

        let size = panel.fittingSize
        // 锚 = 实际点击位置,不锚 button.window 的 frame:多屏各自带菜单栏时,
        // 状态项在两块屏都有镜像,而 button.window 恒报其中一块屏的坐标
        // (实测报外接屏 -583,1168)——用户点主屏镜像时,按 window frame 定位
        // 面板会开到另一块屏上,看起来「点了没反应」(2026-10-29 实机回归)。
        // mouseDown 触发时 NSEvent.mouseLocation 即点击点,必在用户看到徽标的
        // 那块屏;auto-probe 无真点则鼠标在哪面板开在哪(离屏档随后自行挪走)。
        let anchor = NSEvent.mouseLocation
        var origin = NSPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y - size.height - 12
        )
        // 竖直口径:锚 y 是徽标中心(菜单栏内),面板**顶边**须贴锚点下方
        // (anchor.y - height),不是垂直居中——居中会把上半截推出屏顶,
        // 只剩下半截贴屏,看起来仍像没开(2026-10-29 用户实点回归)。
        // 屏幕边缘钳制(stats 同款):右缘出屏贴右,左缘出屏贴左。
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let maxX = screen.frame.maxX - size.width
            origin.x = min(max(origin.x, screen.frame.minX), max(maxX, screen.frame.minX))
            origin.y = max(origin.y, screen.frame.minY)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        // 面板材质窗(visualEffectView)自带圆角与阴影,与系统弹窗观感一致。
        panel.makeKeyAndOrderFront(nil)
        // ←/→ 切 tab:根视图接键盘。
        panel.makeFirstResponder(root)
    }

    private func closePanel() {
        if let tab = monitor.currentPopoverTab {
            lastTab = tab
        }
        monitor.setPopoverTab(nil)
        closedAt = Date()
        statusItem.button?.isHighlighted = false
        panel.orderOut(nil)
        panel.setContent(nil)
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

    private func armNotificationObservers() {
        let center = NotificationCenter.default
        // 告警通知点开 → 开主窗口(激活已由路由完成,这里只开窗)。
        center.addObserver(
            forName: AlertNotificationRouter.openMainWindowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
                MainWindowBridge.open()
            }
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

    // MARK: - 程序化性能探针(popover-layout-loop/01 验收用)

    /// `defaults write com.gaozimeng.pulse debug.autoOpenPanel -bool YES` 后,
    /// 启动 8 秒自动开面板、再 45 秒自动收——面板开合全程序化,弹窗态 CPU
    /// 验收不依赖人工点按(哨兵 + 采样自查)。生产环境不设此键即零副作用。
    private func scheduleAutoProbe() {
        guard UserDefaults.standard.bool(forKey: "debug.autoOpenPanel") else { return }
        let offscreen = UserDefaults.standard.bool(forKey: "debug.autoOpenPanelOffscreen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            LogService.info("AUTO-PROBE 开面板\(offscreen ? "(离屏)" : "")", category: "PanelProbe")
            openPanel()
            if offscreen {
                // 离屏档:渲染/布局照常,只是不挡用户鼠标(面板在屏外的
                // visible 窗口,display cycle 照跑;完全遮挡可能省合成,
                // 数值若临界再以在屏档复核)。
                panel.setFrameOrigin(NSPoint(x: -4000, y: 800))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, panel.isVisible else { return }
                LogService.info("AUTO-PROBE 收面板", category: "PanelProbe")
                closePanel()
            }
        }
    }
}

/// 弹窗面板(stats `PopupWindow` 同构,Kit/module/popup.swift):
/// NSPanel + `.nonactivatingPanel` = 取焦点不激活 app(主窗口永不被连带),
/// `hidesOnDeactivate = false` 防 app 切换误收;内容 = 毛玻璃底
/// (NSVisualEffectView,.menu 材质,与系统弹窗观感一致)+ AppKit 内容根视图。
final class PopupPanel: NSPanel {
    /// 失焦即收(transient 语义):点外部 / 切 app 时面板失去键盘焦点。
    var onResignKey: (() -> Void)?

    private let effect: NSVisualEffectView
    private var content: NSView?

    /// 面板理想尺寸:内容(Auto Layout fittingSize)优先,无内容时的兜底与原值一致。
    var fittingSize: CGSize {
        guard let content else { return CGSize(width: 360, height: 664) }
        let fitting = content.fittingSize
        return CGSize(
            width: max(320, fitting.width),
            height: max(480, min(fitting.height, 720))
        )
    }

    init() {
        let initial = CGSize(width: 360, height: 664)
        effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: initial))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]

        super.init(
            contentRect: NSRect(origin: .zero, size: initial),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        animationBehavior = .none
        hidesOnDeactivate = false
        backgroundColor = .clear
        // 弹窗层级(stats 同款):不设即 .normal,与前台应用窗口同层——面板
        // 被 Code/浏览器等任何有窗口的应用盖住,「开了但看不见」
        // (2026-10-29 用户实点回归,CUA 单窗截图能拍到、用户全屏看不见)。
        level = .statusBar
        hasShadow = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = effect
    }

    /// 换内容(nil = 卸下):内容贴满毛玻璃底,四边约束随面板 frame 走。
    func setContent(_ view: NSView?) {
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        effect.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            view.topAnchor.constraint(equalTo: effect.topAnchor),
        ])
    }

    override var canBecomeKey: Bool {
        true
    }

    override func resignKey() {
        super.resignKey()
        Task { @MainActor in self.onResignKey?() }
    }
}

/// 常驻代理:面板收起后全 app 无可见窗,AppKit 的「最后窗口关闭即终止」
/// 定时器(_scheduleCheckForTerminateAfterLastWindowClosed,2026-10-29 法医栈
/// 实证)会把常驻菜单栏 app 杀掉——明确拒绝。SwiftUI 经 Adaptor 合并转发。
final class KeepAliveAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

/// 主窗口「启动即藏」:常驻菜单栏 app 启动不呈现主窗,但窗口须真建一次——开窗桥
/// 靠内容 onAppear 捕获 openWindow。进窗即(首帧前)透明,下一轮 close:走 close 而非
/// orderOut,门控 onDisappear 才会触发(可见性归 nil,不留后台观看态)。每进程一次,
/// 之后用户开窗不受影响。
struct LaunchHiddenWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        LaunchHiderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class LaunchHiderView: NSView {
    @MainActor private static var didHide = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !Self.didHide else { return }
        Self.didHide = true
        window.alphaValue = 0
        DispatchQueue.main.async {
            window.close()
            window.alphaValue = 1
        }
    }
}

/// 桥的捕获视图:零尺寸、零交互,只借 onAppear 存一次环境动作。
struct MainWindowOpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            MainWindowBridge.openWindow = openWindow
            LogService.info("开窗桥已捕获", category: "PanelProbe")
        }
    }
}
