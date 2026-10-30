import AppKit
import PulseCore
import SwiftUI

/// 弹窗主页(工单 P0.6-05 对齐 OG 左图):图标 tab → "页名 + 本机一行 / 已运行时长" 头 →
/// 各 tab 内容(与主窗口同一份 MetricTabStack,紧凑档)→ 底部操作排(打开主窗口 +
/// 设置 + 退出)。tab 内容模型与会话状态在
/// DashboardModel(与主窗口共用,评审 F4);组下钻(工单 06)与处置编排
/// (工单 08)不变。
struct DashboardView: View {
    let monitor: SystemMonitor

    /// 弹窗宽度(OG 紧凑弹窗形态)。
    private static let width: CGFloat = 360
    /// 内容滚动区固定高度:MenuBarExtra 按内容理想尺寸定窗,ScrollView 的
    /// 理想高度恒为 0,弹窗会被压扁成只剩头部(工单 09 实机走查发现)——
    /// 必须给定值而非 maxHeight。
    private static let contentHeight: CGFloat = 520

    /// 两窗共用呈现模型(评审 F4):卡模型 / 会话状态 / 处置请求同出处。
    @State private var model: DashboardModel
    /// 当前 tab(工单 03):图标 tab 点击或 ←/→ 切换,内容模型由此折叠;
    /// 初始 tab 可注入(走查 / 深链预留),默认总览。
    @State private var tabSelection: MetricTabSelection
    /// tab 变更回报(popover-leak/01):弹窗门控层持有 tab 记忆,重开还原。
    private let onTabChange: ((MetricTab) -> Void)?

    init(
        monitor: SystemMonitor,
        initialTab: MetricTab = .overview,
        model: DashboardModel? = nil,
        onTabChange: ((MetricTab) -> Void)? = nil
    ) {
        self.monitor = monitor
        self.onTabChange = onTabChange
        // model 可注入(弹窗门控层常驻持有,关闭销毁视图不丢会话状态);默认自建
        // (走查 / 预览等独立实例场景)。
        _model = State(initialValue: model ?? DashboardModel(monitor: monitor))
        // 展示轴随电池可用性(工单 p1-history/02),与主窗口同轴(含历史页)。
        _tabSelection = State(initialValue: MetricTabSelection(
            current: initialTab,
            axis: MetricTab.popoverAxis(hasBattery: monitor.battery.hasBattery)
        ))
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            MetricIconTabBar(selection: $tabSelection)
            pageHeader
            ScrollView {
                // 惰性栈(popover-appkit/10):卡片序列惰性,排行卡内部的行才能随视口按需建。
                LazyVStack(spacing: 8) {
                    MetricTabStack(
                        tab: tabSelection.current,
                        isCompact: true,
                        monitor: monitor,
                        model: model,
                        content: content,
                        onSelectTab: { tabSelection.current = $0 }
                    ) {
                        rankingCard
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: Self.contentHeight)
            // 触发中的告警(工单 P1-07):授权被拒的降级出口 + 常态状态展示;
            // 无告警时不渲染。点开系统通知走主窗口深链,弹窗只做提示面。
            if !monitor.alerts.activeAlerts.isEmpty {
                AlertBannerView(center: monitor.alerts, isCompact: true)
            }
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .background(Surface.window)
        // 首次电池读数落地 → 电池页入轴(工单 02);被隐藏的当前 tab 回落总览。
        .onChange(of: monitor.battery.hasBattery) { _, hasBattery in
            tabSelection.setAxis(MetricTab.popoverAxis(hasBattery: hasBattery))
        }
        // tab 变更单点回报(图标条 / ←/→ / 内容切换都汇到这里)。
        .onChange(of: tabSelection.current) { _, tab in
            onTabChange?(tab)
        }
        .modifier(KillFailureAlert(report: $model.killFailureReport))
    }

    /// 当前 tab 的展示内容(纯逻辑折叠):榜单序、组行口径、内存分段。
    private var content: MetricTabContent {
        model.content(tab: tabSelection.current)
    }

    /// 页头(OG:"Overview" + 右侧 "⏱ Up 6d 4h";页名下的本机一行补齐参考文档
    /// 点名的缺口「Vitals 报 Apple M1 Max · 10 cores · 64 GB」——用户 2026-10-24
    /// 反馈弹窗总览缺本机信息):「芯片 · 核数 · 内存」与主窗口内容头同一出处
    /// (hostSummary);全部 tab 一致,切 tab 页头不跳高。运行时长每分钟刷新。
    private var pageHeader: some View {
        let host = HostInfo.current
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tabSelection.current.title)
                Text(PulseFormat.hostSummary(
                    chipName: host.chipName,
                    coreCount: host.coreCount,
                    physicalMemoryBytes: host.physicalMemoryBytes
                ))
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Label(
                    PulseFormat.systemUptime(seconds: ProcessInfo.processInfo.systemUptime),
                    systemImage: "clock"
                )
                .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    /// "当前最忙"排行卡:全部组,榜单序随 tab;点行展开组内进程(只读最近一轮采样);
    private var rankingCard: some View {
        RankingCardView(
            groups: content.ranking,
            metric: content.metric,
            cpuLeader: content.cpuLeader,
            memoryLeaderBytes: content.memoryLeaderBytes,
            expandedGroupIDs: model.expandedGroupIDs,
            density: .compact,
            onToggle: model.toggleExpansion(of:),
            onEndGroup: model.requestEndGroup
        ) { group in
            if let drilldown = monitor.drilldown {
                ProcessDrilldownView(
                    group: group,
                    drilldown: drilldown,
                    selectedProcessID: $model.selectedProcessID,
                    onEndProcess: model.requestEndProcess
                )
            }
        }
    }

    /// 底部操作排(用户拍板):开窗靠左;齿轮 + 电源(退出)靠右。全纯图标,
    /// 悬停提示与无障碍标签承载语义(开窗纯图标决定记录于工单 05 Comments)。
    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                // LSUIElement 应用激活策略为 .accessory:开窗只建窗不抢前台,
                // 窗口会开在其他应用后面(实机反馈"点了没反应")——先激活再开窗。
                // 开窗走广播由菜单栏控制器统一路由(收面板 + 经桥开主窗):
                // NSPanel 宿主里环境 openWindow 是哑动作。
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: AlertNotificationRouter.openMainWindowNotification,
                    object: nil
                )
            } label: {
                Image(systemName: "macwindow")
            }
            .help("打开主窗口")
            .accessibilityLabel("打开主窗口")
            Spacer()
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                // 场景环境的 openSettings 在 NSPanel 宿主里不可用(见头部注释):
                // 走系统标准动作,任一命中即可(macOS 14+ showSettingsWindow:)。
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置项目根目录")
            .accessibilityLabel("设置")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("退出 Pulse")
            .accessibilityLabel("退出 Pulse")
        }
        .buttonStyle(FooterButtonStyle())
    }
}

/// 弹窗底部按钮(OG 底排):卡底色圆角块,按下加深。
struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                configuration.isPressed ? Surface.cardHigh : Surface.card,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
    }
}

/// 组卡样式表(工单 05/09,评审 T6):每个类别一份完整样式
/// (SF Symbol + 瓦片色 + 指标强调色)。孤儿进程的橙色高亮(GLOSSARY:
/// 它往往正是问题所在)是表中的一行,而非散落在视图里的 `.orphan` 特判。
struct GroupCardStyle {
    let symbolName: String
    /// 外壳底色(2026-10-16 用户反馈):非 bundle 组没有真实应用图标,裸 SF Symbol
    /// 夹在真 App 图标之间显得突兀——改为实心圆角方块 + 白符号,形态对齐 app logo。
    let tileColor: Color
    /// 指标强调色:CPU 口径下驱动卡内 meter(孤儿橙)。工单 03 tab 化后
    /// 内存口径由 RankingRowView 按当前 tab 的指标另行覆盖(孤儿仍橙,语义不变)。
    let accentColor: Color
}

/// 类别图标的"外壳":实心圆角方块 + 白色符号,形态对齐真实 app 图标。
struct CategoryIconTile: View {
    let symbolName: String
    let color: Color
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension GroupCategory {
    /// 组卡的类别样式:bundle 组由 UI 直接取应用图标,此表服务项目与兜底类别
    /// (spec:符号图 + 孤儿橙色);各类别符号互不相同——"可辨识的类别标记"。
    /// 颜色一律取类别身份色(`identityColor`,MetricAccent.swift 唯一出处)。
    var cardStyle: GroupCardStyle {
        switch self {
        case .app:
            GroupCardStyle(symbolName: "shippingbox", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .project:
            // 项目组统一图标:folder(目录 = 项目的自然隐喻,与 Vitals 的 Projects 概念
            // 一致;旧 hammer 读作"构建工具",用户反馈怪)。
            GroupCardStyle(symbolName: "folder", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .system:
            GroupCardStyle(symbolName: "cpu", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .backgroundService:
            GroupCardStyle(symbolName: "gearshape", tileColor: identityColor, accentColor: Metric.cpu.accentColor)
        case .orphan:
            GroupCardStyle(symbolName: "exclamationmark.triangle", tileColor: identityColor, accentColor: identityColor)
        }
    }

    /// 组卡图标的 SF Symbol(样式表的符号字段,单测经此断言映射完备且互异)。
    var cardSymbolName: String {
        cardStyle.symbolName
    }
}

// MARK: - 处置失败弹窗(p0/08;确认与编排在 KillRequestFlow.swift)

/// 处置失败汇总弹窗:**有失败才弹**(标题 / 正文 / "知道了"按钮与工单 08 一致)。
struct KillFailureAlert: ViewModifier {
    @Binding var report: KillReport?

    func body(content: Content) -> some View {
        content.alert(
            report?.failureAlertTitle ?? "",
            isPresented: Binding(
                get: { report?.hasFailures == true },
                set: {
                    if !$0 {
                        report = nil
                    }
                }
            )
        ) {
            Button("知道了") { report = nil }
        } message: {
            Text(report?.failureAlertMessage ?? "")
        }
    }
}

// MARK: - 预览(Synthetic 源,spec 测试决策:UI 以预览 + 手动下钻验收)

#Preview("弹窗") {
    let now = Date()
    let worktree = "/Users/x/work/octok-client/.worktrees/skill-manage-read-and-index"
    // 两张快照推进 cpuTime:第二轮差分出真 CPU(预览即验收锚点形态)。
    func tree(zcode: UInt64, node: UInt64, rustc: UInt64, waifud: UInt64) -> [RawProcess] {
        [
            RawProcess(
                pid: 10,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode",
                cpuTimeNanoseconds: zcode,
                physicalFootprintBytes: 300_000_000,
                startTime: now.addingTimeInterval(-3 * 3600)
            ),
            RawProcess(
                pid: 11,
                parentPID: 10,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "server.js"],
                cwd: worktree,
                cpuTimeNanoseconds: node,
                physicalFootprintBytes: 80_000_000,
                startTime: now.addingTimeInterval(-25 * 60)
            ),
            RawProcess(
                pid: 100,
                parentPID: 11,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree,
                cpuTimeNanoseconds: rustc,
                physicalFootprintBytes: 200_000_000,
                startTime: now.addingTimeInterval(-40)
            ),
            RawProcess(
                pid: 777,
                parentPID: 1,
                executablePath: "/opt/homebrew/bin/waifud",
                argv: ["waifud"],
                cpuTimeNanoseconds: waifud,
                physicalFootprintBytes: 30_000_000,
                startTime: now.addingTimeInterval(-3 * 86400)
            ),
        ]
    }
    let monitor = SystemMonitor.preview(
        source: SyntheticProcessSource(snapshots: [
            ProcessSnapshot(
                takenAt: now,
                processes: tree(zcode: 0, node: 0, rustc: 0, waifud: 0)
            ),
            ProcessSnapshot(
                takenAt: now.addingTimeInterval(5),
                processes: tree(
                    zcode: 150_000_000, node: 250_000_000, rustc: 4_500_000_000, waifud: 350_000_000
                )
            ),
        ]),
        projectRoots: ["/Users/x/work/octok-client"]
    )
    return DashboardView(monitor: monitor)
        .task { monitor.start() }
}
