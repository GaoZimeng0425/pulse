import SwiftUI
import AppKit

/// 弹窗主页:头部系统 CPU 负载为真实采样数字,下方 Top-5 组卡(真归组,
/// 组 CPU% 降序,系统组参榜)。排序随每轮采样实时刷新(@Observable)。
/// 组卡下钻(工单 06):点卡展开组内进程平铺,数据只读最近一轮采样。
struct DashboardView: View {
    let monitor: SystemMonitor
    /// 设置窗入口(工单 07):头部齿轮按钮。
    @Environment(\.openSettings) private var openSettings

    /// 下钻列表滚动上限:系统组可达数百进程,超出即滚动(LazyVStack 保证流畅)。
    private static let drilldownListMaxHeight: CGFloat = 480

    /// 展开中的组(按稳定组 id):跨采样轮次保持,组消失时残留 id 无害。
    @State private var expandedGroupIDs: Set<String> = []
    /// 展开详情的进程(跨组唯一):下钻期间进程退出时详情安静收起。
    @State private var selectedProcessID: pid_t?

    var body: some View {
        VStack(spacing: 12) {
            header
            if monitor.topGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(monitor.topGroups) { group in
                            groupSection(for: group)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.drilldownListMaxHeight)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// 单个组卡 + 展开后的下钻区。展开只读 monitor.drilldown(最近一轮采样),
    /// 不触发额外采集。
    private func groupSection(for group: ProcessGroup) -> some View {
        VStack(spacing: 6) {
            GroupCardView(group: group, isExpanded: expandedGroupIDs.contains(group.id)) {
                toggleExpansion(of: group.id)
            }
            if expandedGroupIDs.contains(group.id), let drilldown = monitor.drilldown {
                ProcessDrilldownView(
                    group: group,
                    drilldown: drilldown,
                    selectedProcessID: $selectedProcessID
                )
            }
        }
    }

    private func toggleExpansion(of groupID: String) {
        if !expandedGroupIDs.insert(groupID).inserted {
            expandedGroupIDs.remove(groupID)
        }
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
struct GroupCardView: View {
    let group: ProcessGroup
    let isExpanded: Bool
    let onToggle: () -> Void

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
            }
            .padding(10)
            .background(cardBackground, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name),\(group.processes.count) 进程")
        .accessibilityHint(isExpanded ? "收起组内进程列表" : "展开组内进程列表")
    }

    /// bundle 组:读 .app 目录的真实应用图标;其余:类别 SF Symbol(孤儿橙色)。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath = group.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: group.category.cardSymbolName)
                .frame(width: 28)
                .foregroundStyle(group.category == .orphan ? Color.orange : Color.secondary)
        }
    }

    /// 孤儿进程组卡整体呈橙色系(GLOSSARY:它往往正是问题所在)。
    private var cardBackground: AnyShapeStyle {
        group.category == .orphan
            ? AnyShapeStyle(Color.orange.opacity(0.15))
            : AnyShapeStyle(.quaternary)
    }
}

extension GroupCategory {
    /// 组卡图标的 SF Symbol:bundle 组由 UI 直接取应用图标,此映射服务项目与
    /// 兜底类别(spec:符号图);各类别符号互不相同——"可辨识的类别标记"。
    var cardSymbolName: String {
        switch self {
        case .app: "shippingbox"
        case .project: "hammer"
        case .system: "cpu"
        case .backgroundService: "gearshape"
        case .orphan: "exclamationmark.triangle"
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
            onToggle: {}
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
            onToggle: {}
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
            onToggle: {}
        )
    }
    .padding(16)
    .frame(width: 340)
}
