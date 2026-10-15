import SwiftUI
import AppKit

/// 弹窗主页(工单 P0.6-05 对齐 OG 左图):图标 tab → "页名 / 已运行时长" 头 →
/// 各 tab 内容(总览 = 双列小指标卡;CPU / 内存 = 指标主卡)+ "当前最忙"排行卡 →
/// 底部操作排(打开主窗口 + 设置 + 退出)。tab 内容模型在 MetricTabContent
/// (纯逻辑,单测覆盖);组下钻(工单 06)与处置编排(工单 08)不变。
struct DashboardView: View {
    let monitor: SystemMonitor
    /// 设置窗入口(工单 07):底部齿轮按钮。
    @Environment(\.openSettings) private var openSettings
    /// 主窗口入口:底部"打开主窗口"按钮。
    @Environment(\.openWindow) private var openWindow

    /// 弹窗宽度(OG 紧凑弹窗形态)。
    private static let width: CGFloat = 360
    /// 内容滚动区固定高度:MenuBarExtra 按内容理想尺寸定窗,ScrollView 的
    /// 理想高度恒为 0,弹窗会被压扁成只剩头部(工单 09 实机走查发现)——
    /// 必须给定值而非 maxHeight。
    private static let contentHeight: CGFloat = 520

    /// 当前 tab(工单 03):图标 tab 点击或 ←/→ 切换,内容模型由此折叠。
    @State private var tabSelection = MetricTabSelection()
    /// 展开中的组(按稳定组 id):跨采样轮次保持,组消失时残留 id 无害。
    @State private var expandedGroupIDs: Set<String> = []
    /// 展开详情的进程(跨组唯一):下钻期间进程退出时详情安静收起。
    @State private var selectedProcessID: pid_t?
    /// 处置结果汇总(工单 08):**有失败才弹**;全成功保持安静。
    @State private var killFailureReport: KillReport?

    var body: some View {
        VStack(spacing: 10) {
            MetricIconTabBar(selection: $tabSelection)
            pageHeader
            ScrollView {
                VStack(spacing: 8) {
                    tabCards
                    if monitor.allGroups.isEmpty {
                        emptyState
                    } else {
                        rankingCard
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: Self.contentHeight)
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .background(Surface.window)
        .modifier(KillFailureAlert(report: $killFailureReport))
    }

    /// 当前 tab 的展示内容(纯逻辑折叠):榜单序、组行口径、内存分段。
    private var content: MetricTabContent {
        MetricTabContent.build(groups: monitor.allGroups, tab: tabSelection.current)
    }

    private var cpuModel: MetricCardModel {
        .cpu(
            breakdown: monitor.cpuBreakdown,
            statistics: monitor.history.systemCPULoad.statistics,
            trend: monitor.history.systemCPULoad.values
        )
    }

    private var memoryModel: MetricCardModel {
        .memory(monitor.memory, trend: monitor.history.memoryUsed.values, host: .current)
    }

    /// 页头(OG:"Overview" + 右侧 "⏱ Up 6d 4h"):运行时长每分钟刷新。
    private var pageHeader: some View {
        HStack {
            Text(tabSelection.current.title)
            Spacer()
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Label(
                    PulseFormat.systemUptime(seconds: ProcessInfo.processInfo.systemUptime),
                    systemImage: "clock"
                )
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    /// 各 tab 的指标卡:总览 = 双列小卡(点卡跳 tab);CPU / 内存 = 主卡(内存再加按应用环形)。
    @ViewBuilder
    private var tabCards: some View {
        switch tabSelection.current {
        case .overview:
            HStack(spacing: 8) {
                MetricCardView(model: cpuModel, style: .compact) { tabSelection.current = .cpu }
                MetricCardView(model: memoryModel, style: .compact) { tabSelection.current = .memory }
            }
        case .cpu:
            MetricMainCardView(model: cpuModel, isCompact: true)
        case .memory:
            MetricMainCardView(model: memoryModel, isCompact: true)
            RingCardView.memoryByApp(
                segments: content.memorySegments,
                totalBytes: content.memoryTotalBytes,
                isCompact: true
            )
        }
    }

    /// "当前最忙"排行卡:全部组,榜单序随 tab;点行展开组内进程(只读最近一轮采样)。
    private var rankingCard: some View {
        RankingCardView(
            title: "当前最忙",
            groups: content.ranking,
            metric: content.metric,
            cpuLeader: content.cpuLeader,
            memoryLeaderBytes: content.memoryLeaderBytes,
            expandedGroupIDs: expandedGroupIDs,
            density: .compact,
            onToggle: toggleExpansion(of:),
            onEndGroup: requestEndGroup
        ) { group in
            if let drilldown = monitor.drilldown {
                ProcessDrilldownView(
                    group: group,
                    drilldown: drilldown,
                    selectedProcessID: $selectedProcessID,
                    onEndProcess: requestEndProcess
                )
            }
        }
    }

    /// 底部操作排(OG:`Open Vitals` 宽按钮 + 齿轮 + `Quit`):
    /// openWindow 对已开窗口 = 聚焦;NSApplication.terminate 是 LSUIElement 应用体面的退出路径。
    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                // LSUIElement 应用激活策略为 .accessory:openWindow 只建窗不抢前台,
                // 窗口会开在其他应用后面(实机反馈"点了没反应")——先激活再开窗。
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: MainWindowSceneID.value)
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置项目根目录")
            .accessibilityLabel("设置")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .help("退出 Pulse")
        }
        .buttonStyle(FooterButtonStyle())
    }

    private func toggleExpansion(of groupID: String) {
        if !expandedGroupIDs.insert(groupID).inserted {
            expandedGroupIDs.remove(groupID)
        }
    }

    // MARK: 处置(工单 08)——不主动杀、确认后才杀
    // 确认 + 执行 + 失败汇总的编排在 KillRequestFlow(主窗口同流程共用)。

    /// 进程详情"结束进程":确认(点名 name+pid)→ SIGTERM;有失败才弹汇总。
    private func requestEndProcess(_ target: KillTarget) {
        killFailureReport = KillRequestFlow.endProcess(target, monitor: monitor)
    }

    /// 排行行"结束整组":确认(列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    private func requestEndGroup(_ group: ProcessGroup) {
        killFailureReport = KillRequestFlow.endGroup(group, monitor: monitor)
    }

    /// 极端空载 / 首轮采样前:无组可显示,给一行安静文案而不是坏 UI(所有 tab 同)。
    private var emptyState: some View {
        Text("暂无活动组")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
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
                in: .rect(cornerRadius: 9)
            )
            .contentShape(.rect)
    }
}

/// 组卡样式表(工单 05/09,评审 T6):每个类别一份完整样式
/// (SF Symbol + 图标色 + 卡片底色 + 指标强调色)。孤儿进程的橙色高亮(GLOSSARY:
/// 它往往正是问题所在)是表中的一行,而非散落在视图里的 `.orphan` 特判。
struct GroupCardStyle {
    let symbolName: String
    let iconColor: Color
    let cardBackground: AnyShapeStyle
    /// 指标强调色:CPU 口径下驱动卡内 meter/微图(孤儿橙)。工单 03 tab 化后
    /// 内存口径由 RankingRowView 按当前 tab 的指标另行覆盖(孤儿仍橙,语义不变)。
    let accentColor: Color
}

extension GroupCategory {
    /// 组卡的类别样式:bundle 组由 UI 直接取应用图标,此表服务项目与兜底类别
    /// (spec:符号图 + 孤儿橙色);各类别符号互不相同——"可辨识的类别标记"。
    var cardStyle: GroupCardStyle {
        switch self {
        case .app:
            GroupCardStyle(
                symbolName: "shippingbox", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .project:
            GroupCardStyle(
                symbolName: "hammer", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .system:
            GroupCardStyle(
                symbolName: "cpu", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .backgroundService:
            GroupCardStyle(
                symbolName: "gearshape", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .orphan:
            GroupCardStyle(
                symbolName: "exclamationmark.triangle",
                iconColor: .orange,
                cardBackground: AnyShapeStyle(Color.orange.opacity(0.15)),
                accentColor: .orange
            )
        }
    }

    /// 组卡图标的 SF Symbol(样式表的符号字段,单测经此断言映射完备且互异)。
    var cardSymbolName: String {
        cardStyle.symbolName
    }
}

// MARK: - 处置确认对话框(工单 08)

/// 确认对话框(NSAlert):"确认后才杀"的唯一关口。
/// **取消按钮先添加 = NSAlert 默认按钮**——默认焦点与回车键都落在"取消"(防误触);
/// "结束"按钮无键盘等价键,只有明确点击才执行。
/// 文案构造在 KillCopy(纯函数,单测见 KillCopyTests);焦点次序属 UI,按 spec 以手动验收。
enum KillConfirmationDialog {
    @MainActor
    static func confirm(title: String, informativeText: String, actionTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: KillCopy.cancelButtonTitle) // 先加 = 默认焦点(回车 = 取消)
        let actionButton = alert.addButton(withTitle: actionTitle)
        actionButton.keyEquivalent = "" // 不给"结束"任何键盘触发
        return alert.runModal() == NSApplication.ModalResponse.alertSecondButtonReturn
    }
}

// MARK: - 处置编排与失败弹窗(工单 08;P0.5-01 起弹窗与主窗口共用)

/// 处置请求编排:确认对话框把关 → 确认后才发信号;返回失败汇总——
/// 全成功返回 nil 保持安静(行 / 组消失交给下轮采样自然反映)。
/// 原为 DashboardView 私有逻辑,工单 P0.5-01 主窗口需要同一流程,抽出共用;
/// 对话框构造(KillCopy)、焦点次序与"有失败才弹"口径与 P0 完全一致。
@MainActor
enum KillRequestFlow {
    /// 进程详情"结束进程"(单目标,确认时点名 name+pid)。
    static func endProcess(_ target: KillTarget, monitor: SystemMonitor) -> KillReport? {
        let targets = [target]
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.confirmationTitle(for: targets),
            informativeText: KillCopy.confirmationMessage(for: targets),
            actionTitle: KillCopy.singleActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminate(targets)
        return report.hasFailures ? report : nil
    }

    /// 组卡"结束整组"(确认时列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    static func endGroup(_ group: ProcessGroup, monitor: SystemMonitor) -> KillReport? {
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.groupConfirmationTitle(groupName: group.name),
            informativeText: KillCopy.groupConfirmationMessage(processCount: group.processes.count),
            actionTitle: KillCopy.groupActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminateGroup(id: group.id)
        return report.hasFailures ? report : nil
    }
}

/// 处置失败汇总弹窗:**有失败才弹**(标题 / 正文 / "知道了"按钮与工单 08 一致)。
struct KillFailureAlert: ViewModifier {
    @Binding var report: KillReport?

    func body(content: Content) -> some View {
        content.alert(
            report?.failureAlertTitle ?? "",
            isPresented: Binding(
                get: { report?.hasFailures == true },
                set: { if !$0 { report = nil } }
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
                startTime: now.addingTimeInterval(-3 * 86_400)
            ),
        ]
    }
    let monitor = SystemMonitor(
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
