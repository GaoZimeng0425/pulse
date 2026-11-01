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
    /// 弹窗排行只列前 20 名(2026-11-01 用户拍板 B;DESIGN.md `layout.popover-ranking-limit`):
    /// 弹窗是"扫一眼谁最忙",上百行的快速滚动是剩下的大头开销;其余由「查看全部」进主窗口。
    private static let rankingLimit = 20

    /// 两窗共用呈现模型(评审 F4):卡模型 / 会话状态 / 处置请求同出处。
    @State private var model: DashboardModel
    /// 当前 tab(工单 03):图标 tab 点击或 ←/→ 切换,内容模型由此折叠;
    /// 初始 tab 可注入(走查 / 深链预留),默认总览。
    @State private var tabSelection: MetricTabSelection
    /// tab 变更回报(popover-leak/01):弹窗门控层持有 tab 记忆,重开还原。
    private let onTabChange: ((MetricTab) -> Void)?
    /// 原生列表开关(native-list):开 = 通用 AppKit 列表承载卡片与排行行;关 = SwiftUI
    /// List(popover-list)。迁移期留作一键回退:`defaults write com.gaozimeng.pulse
    /// popover.nativeList -bool NO`,重开弹窗生效。
    @AppStorage("popover.nativeList") private var usesNativeList = true

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
            scrollContent
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

    /// 内容滚动区:原生列表(默认)或 SwiftUI List(回退)。
    @ViewBuilder
    private var scrollContent: some View {
        if usesNativeList {
            NativeList(rows: nativeRows, resetToken: tabSelection.current)
        } else {
            // 系统表格托底(popover-list,2026-10-31 用户拍板 List):LazyVStack 滚动时每帧
            // 重布局 + 重出整块绘制指令,真机触控板滚动 36–43%(sample:render ~一半、
            // layout ~四分之一)。List 只建可见行、滚动平移已画好的行。每张卡一个 List 行
            // (上下行内距各 4 = 原卡间距 8),排行卡再拆成卡头 / 每行 / 卡尾各一行。
            List {
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
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .environment(\.rankingRowsInList, true)
            .scrollIndicators(.never)
            // plain List 的行左 8 / 右 9 内缩不受 listRowInsets 管(离屏探针实测),
            // 负边距抵掉,卡片与页头 / 底排同宽。
            .padding(.leading, -8)
            .padding(.trailing, -9)
        }
    }

    /// 原生列表的行(native-list):卡片一卡一行,排行拆成卡头 / 每行 / 卡尾。卡片序列
    /// 与 SwiftUI 宿主同出 MetricTabStack.blocks。
    private var nativeRows: [NativeListRow] {
        let stack = MetricTabStack(
            tab: tabSelection.current,
            isCompact: true,
            monitor: monitor,
            model: model,
            content: content,
            onSelectTab: { tabSelection.current = $0 }
        ) { EmptyView() }
        return stack.blocks.flatMap { block -> [NativeListRow] in
            switch block.kind {
            case let .card(view):
                // 卡外 8pt 间距 = 上下各 4 透明边(原生列表无行内距)。
                [NativeListRow(kind: block.id, height: .measured(key: block.id)) {
                    AnyView(view.padding(.vertical, 4))
                }]
            case .groupRanking:
                groupRankingRows(id: block.id)
            case let .moduleRanking(spec):
                moduleRankingRows(id: block.id, spec: spec)
            }
        }
    }

    /// 组排行逐行:组行同高(按 kind 量一次),展开的组连同下钻自量。
    private func groupRankingRows(id: String) -> [NativeListRow] {
        let content = content
        let header = RankingListHeader(
            title: GroupRankingStyle.title,
            accent: GroupRankingStyle.accent(content.metric),
            valueLabel: GroupRankingStyle.valueLabel(content.metric),
            isCompact: true,
            isEmpty: content.ranking.isEmpty,
            emptyMessage: RankingEmptyMessage(title: "暂无活动组", detail: "首轮采样尚未完成,或系统极端空闲")
        )
        var rows = [NativeListRow(kind: "\(id)-header", height: .measured(key: "\(id)-header-\(header.isEmpty)")) {
            AnyView(RankingListSlices.Header(content: header, isCompact: true))
        }]
        for group in content.ranking.prefix(Self.rankingLimit) {
            let isExpanded = model.expandedGroupIDs.contains(group.id)
            let cell = RankingGroupCell(
                group: group,
                metric: content.metric,
                meterFraction: GroupRankingStyle.meterFraction(
                    group, metric: content.metric,
                    cpuLeader: content.cpuLeader, memoryLeaderBytes: content.memoryLeaderBytes
                ),
                isExpanded: isExpanded,
                isCompact: true,
                onToggle: { model.toggleExpansion(of: group.id) },
                onEndGroup: { model.requestEndGroup(group) },
                expandedContent: { drilldown(for: group) }
            )
            rows.append(isExpanded
                ? NativeListRow(kind: "\(id)-row-expanded", height: .measured(key: "\(id)-x-\(group.id)")) {
                    AnyView(cell.rankingRowSlice(compact: true))
                }
                : NativeListRow(kind: "\(id)-row", height: .uniform) {
                    AnyView(cell.rankingRowSlice(compact: true))
                })
        }
        rows += showAllRows(id: id, total: content.ranking.count)
        rows.append(NativeListRow(kind: "\(id)-footer", height: .measured(key: "\(id)-footer")) {
            AnyView(RankingListSlices.Footer(footnote: nil, isCompact: true))
        })
        return rows
    }

    /// 模块排行逐行(只读,行同高)。
    private func moduleRankingRows(id: String, spec: ModuleRankingSpec) -> [NativeListRow] {
        let header = RankingListHeader(
            title: spec.title, accent: spec.accent, valueLabel: spec.valueLabel,
            isCompact: true, isEmpty: spec.rows.isEmpty, emptyMessage: spec.resolvedEmptyMessage
        )
        var rows = [NativeListRow(kind: "\(id)-header", height: .measured(key: "\(id)-header-\(header.isEmpty)")) {
            AnyView(RankingListSlices.Header(content: header, isCompact: true))
        }]
        rows += spec.rows.prefix(Self.rankingLimit).map { row in
            NativeListRow(kind: "\(id)-row", height: .uniform) {
                AnyView(ModuleRankingRowView(row: row, accent: spec.accent, isCompact: true)
                    .rankingRowSlice(compact: true))
            }
        }
        rows += showAllRows(id: id, total: spec.rows.count)
        rows.append(NativeListRow(kind: "\(id)-footer", height: .measured(key: "\(id)-footer")) {
            AnyView(RankingListSlices.Footer(footnote: spec.cadenceNote, isCompact: true))
        })
        return rows
    }

    /// 超出前 20 名时补一行「查看全部」:点了开主窗口并落到当前 tab。
    private func showAllRows(id: String, total: Int) -> [NativeListRow] {
        let hidden = total - Self.rankingLimit
        guard hidden > 0 else { return [] }
        let tab = tabSelection.current
        return [NativeListRow(kind: "\(id)-show-all", height: .uniform) {
            AnyView(RankingShowAllRow(hiddenCount: hidden, isCompact: true) {
                Self.openMainWindow(tab: tab)
            }
            .rankingRowSlice(compact: true))
        }]
    }

    /// 开主窗口:LSUIElement 应用激活策略为 .accessory,开窗只建窗不抢前台,窗口会开在
    /// 其他应用后面(实机反馈"点了没反应")——先激活再开窗。开窗走广播由菜单栏控制器统一
    /// 路由(收面板 + 经桥开主窗):NSPanel 宿主里环境 openWindow 是哑动作。带 tab 时
    /// 主窗口已开则切到该 tab(冷开窗落默认页)。
    private static func openMainWindow(tab: MetricTab? = nil) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: AlertNotificationRouter.openMainWindowNotification,
            object: nil,
            userInfo: tab.map { [AlertNotificationRouter.tabUserInfoKey: $0.rawValue] }
        )
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
            groups: Array(content.ranking.prefix(Self.rankingLimit)),
            metric: content.metric,
            cpuLeader: content.cpuLeader,
            memoryLeaderBytes: content.memoryLeaderBytes,
            expandedGroupIDs: model.expandedGroupIDs,
            density: .compact,
            onToggle: model.toggleExpansion(of:),
            onEndGroup: model.requestEndGroup
        ) { group in
            drilldown(for: group)
        }
    }

    /// 组下钻(工单 06):只读最近一轮采样。
    @ViewBuilder
    private func drilldown(for group: ProcessGroup) -> some View {
        if let drilldown = monitor.drilldown {
            ProcessDrilldownView(
                group: group,
                drilldown: drilldown,
                selectedProcessID: $model.selectedProcessID,
                onEndProcess: model.requestEndProcess
            )
        }
    }

    /// 底部操作排(用户拍板):开窗靠左;齿轮 + 电源(退出)靠右。全纯图标,
    /// 悬停提示与无障碍标签承载语义(开窗纯图标决定记录于工单 05 Comments)。
    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                Self.openMainWindow()
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
