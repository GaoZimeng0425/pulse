import SwiftUI
import AppKit

/// 弹窗主页:头部系统 CPU 负载为真实采样数字,下方 Top-5 组卡(真归组,
/// 组 CPU% 降序,系统组参榜)。排序随每轮采样实时刷新(@Observable)。
/// 组卡下钻(工单 06):点卡展开组内进程平铺,数据只读最近一轮采样。
struct DashboardView: View {
    let monitor: SystemMonitor
    /// 设置窗入口(工单 07):头部齿轮按钮。
    @Environment(\.openSettings) private var openSettings

    /// 下钻列表滚动上限:系统组可达数百进程,超出即滚动(组内行由
    /// ProcessDrilldownView 的 LazyVStack 惰性渲染,保证滚动流畅)。
    private static let drilldownListMaxHeight: CGFloat = 480

    /// 展开中的组(按稳定组 id):跨采样轮次保持,组消失时残留 id 无害。
    @State private var expandedGroupIDs: Set<String> = []
    /// 展开详情的进程(跨组唯一):下钻期间进程退出时详情安静收起。
    @State private var selectedProcessID: pid_t?
    /// 处置结果汇总(工单 08):**有失败才弹**;全成功保持安静——
    /// 行 / 组消失交给下轮采样自然反映,不假装成功也不报喜打扰。
    @State private var killFailureReport: KillReport?

    var body: some View {
        VStack(spacing: 12) {
            header
            if monitor.topGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // 注意必须是普通 VStack(非 Lazy):组卡需要即时构卡参与
                    // 布局;组内数十行的惰性渲染由 ProcessDrilldownView 承担。
                    VStack(spacing: 12) {
                        ForEach(monitor.topGroups) { group in
                            groupSection(for: group)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // 固定高度(而非 maxHeight):MenuBarExtra 按内容理想尺寸定窗,
                // ScrollView 的理想高度恒为 0,弹窗会被压扁成只剩头部
                // (工单 09 实机走查发现)。固定值与菜单栏工具惯例一致(Vitals 同款)。
                .frame(height: Self.drilldownListMaxHeight)
            }
        }
        .padding(16)
        .frame(width: 340)
        .alert(
            killFailureReport?.failureAlertTitle ?? "",
            isPresented: Binding(
                get: { killFailureReport?.hasFailures == true },
                set: { if !$0 { killFailureReport = nil } }
            )
        ) {
            Button("知道了") { killFailureReport = nil }
        } message: {
            Text(killFailureReport?.failureAlertMessage ?? "")
        }
    }

    /// 单个组卡 + 展开后的下钻区。展开只读 monitor.drilldown(最近一轮采样),
    /// 不触发额外采集。
    private func groupSection(for group: ProcessGroup) -> some View {
        VStack(spacing: 6) {
            GroupCardView(
                group: group,
                isExpanded: expandedGroupIDs.contains(group.id),
                onToggle: { toggleExpansion(of: group.id) },
                onEndGroup: { requestEndGroup(group) }
            )
            if expandedGroupIDs.contains(group.id), let drilldown = monitor.drilldown {
                ProcessDrilldownView(
                    group: group,
                    drilldown: drilldown,
                    selectedProcessID: $selectedProcessID,
                    onEndProcess: requestEndProcess
                )
            }
        }
    }

    private func toggleExpansion(of groupID: String) {
        if !expandedGroupIDs.insert(groupID).inserted {
            expandedGroupIDs.remove(groupID)
        }
    }

    // MARK: 处置(工单 08)——不主动杀、确认后才杀

    /// 进程详情"结束进程":确认(点名 name+pid)→ SIGTERM;有失败才弹汇总。
    private func requestEndProcess(_ target: KillTarget) {
        let targets = [target]
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.confirmationTitle(for: targets),
            informativeText: KillCopy.confirmationMessage(for: targets),
            actionTitle: KillCopy.singleActionTitle
        )
        guard confirmed else { return }
        killFailureReport = monitor.terminate(targets)
    }

    /// 组卡"结束整组":确认(列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    private func requestEndGroup(_ group: ProcessGroup) {
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.groupConfirmationTitle(groupName: group.name),
            informativeText: KillCopy.groupConfirmationMessage(processCount: group.processes.count),
            actionTitle: KillCopy.groupActionTitle
        )
        guard confirmed else { return }
        killFailureReport = monitor.terminateGroup(id: group.id)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse")
                    .font(.headline)
                Text("系统 CPU 负载 \(PulseFormat.cpuPercent(monitor.systemCPULoad))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("设置项目根目录")
        }
    }

    /// 极端空载 / 首轮采样前:无组可显示,给一行安静文案而不是坏 UI。
    private var emptyState: some View {
        Text("暂无活动组")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// 组卡四要素(工单 05):组名+图标 / 组 CPU%(单核累加,>100% 合法)/ 内存 / "N 进程"。
/// bundle 组用真实应用图标(NSWorkspace);项目与兜底类别用 SF Symbol;孤儿进程橙色调。
/// 工单 06:整卡可点,展开 / 收起组内进程列表(尾部 chevron 指示)。
/// 工单 08:卡上提供"结束整组"入口(确认对话框把关,见 KillConfirmationDialog)。
struct GroupCardView: View {
    let group: ProcessGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onEndGroup: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.processes.count) 进程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(PulseFormat.cpuPercent(group.cpuPercent))
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text(PulseFormat.memory(group.memoryBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                endGroupButton
            }
            .padding(10)
            .background(group.category.cardStyle.cardBackground, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name),\(group.processes.count) 进程")
        .accessibilityHint(isExpanded ? "收起组内进程列表" : "展开组内进程列表")
    }

    /// "结束整组"入口:xmark.octagon 图标按钮(borderless:嵌在卡内可独立点按)。
    /// 点击只是请求确认——真正发信号前必有确认对话框(不主动杀)。
    private var endGroupButton: some View {
        Button(action: onEndGroup) {
            Image(systemName: "xmark.octagon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("结束整组(需确认)")
        .accessibilityLabel("结束整组 \(group.name)")
    }

    /// bundle 组:读 .app 目录的真实应用图标;其余:类别样式表的 SF Symbol
    /// (符号与图标色都取自 cardStyle,孤儿的高亮只是表里的一行)。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath = group.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: group.category.cardStyle.symbolName)
                .frame(width: 28)
                .foregroundStyle(group.category.cardStyle.iconColor)
        }
    }
}

/// 组卡样式表(工单 05/09,评审 T6):每个类别一份完整样式
/// (SF Symbol + 图标色 + 卡片底色)。孤儿进程的橙色高亮(GLOSSARY:
/// 它往往正是问题所在)是表中的一行,而非散落在视图里的 `.orphan` 特判。
struct GroupCardStyle {
    let symbolName: String
    let iconColor: Color
    let cardBackground: AnyShapeStyle
}

extension GroupCategory {
    /// 组卡的类别样式:bundle 组由 UI 直接取应用图标,此表服务项目与兜底类别
    /// (spec:符号图 + 孤儿橙色);各类别符号互不相同——"可辨识的类别标记"。
    var cardStyle: GroupCardStyle {
        switch self {
        case .app:
            GroupCardStyle(symbolName: "shippingbox", iconColor: .secondary, cardBackground: AnyShapeStyle(.quaternary))
        case .project:
            GroupCardStyle(symbolName: "hammer", iconColor: .secondary, cardBackground: AnyShapeStyle(.quaternary))
        case .system:
            GroupCardStyle(symbolName: "cpu", iconColor: .secondary, cardBackground: AnyShapeStyle(.quaternary))
        case .backgroundService:
            GroupCardStyle(symbolName: "gearshape", iconColor: .secondary, cardBackground: AnyShapeStyle(.quaternary))
        case .orphan:
            GroupCardStyle(
                symbolName: "exclamationmark.triangle",
                iconColor: .orange,
                cardBackground: AnyShapeStyle(Color.orange.opacity(0.15))
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

#Preview("组卡") {
    VStack(spacing: 12) {
        GroupCardView(
            group: ProcessGroup(
                id: "project:octok",
                name: "octok-client @ skill-manage-read-and-index",
                category: .project,
                bundlePath: nil,
                processes: [
                    RawProcess(pid: 100, parentPID: 1, physicalFootprintBytes: 200_000_000)
                ],
                cpuPercent: 445,
                memoryBytes: 2_400_000_000
            ),
            isExpanded: false,
            onToggle: {},
            onEndGroup: {}
        )
        GroupCardView(
            group: ProcessGroup(
                id: "bundle:calculator",
                name: "计算器",
                category: .app,
                bundlePath: "/System/Applications/Calculator.app",
                processes: [
                    RawProcess(pid: 200, parentPID: 1, physicalFootprintBytes: 80_000_000)
                ],
                cpuPercent: 12,
                memoryBytes: 120_000_000
            ),
            isExpanded: true,
            onToggle: {},
            onEndGroup: {}
        )
        GroupCardView(
            group: ProcessGroup(
                id: "orphan",
                name: "孤儿进程",
                category: .orphan,
                bundlePath: nil,
                processes: [
                    RawProcess(pid: 300, parentPID: 1, physicalFootprintBytes: 30_000_000)
                ],
                cpuPercent: 7,
                memoryBytes: 30_000_000
            ),
            isExpanded: false,
            onToggle: {},
            onEndGroup: {}
        )
    }
    .padding(16)
    .frame(width: 340)
}
