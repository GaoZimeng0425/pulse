import SwiftUI
import AppKit

/// 弹窗主页:头部系统 CPU 负载为真实采样数字,下方 Top-5 组卡(真归组,
/// 组 CPU% 降序,系统组参榜)。排序随每轮采样实时刷新(@Observable)。
struct DashboardView: View {
    let monitor: SystemMonitor
    /// 设置窗入口(工单 07):头部齿轮按钮。
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            header
            if monitor.topGroups.isEmpty {
                emptyState
            } else {
                ForEach(monitor.topGroups) { group in
                    GroupCardView(group: group)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
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
struct GroupCardView: View {
    let group: ProcessGroup

    var body: some View {
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
        }
        .padding(10)
        .background(cardBackground, in: .rect(cornerRadius: 10))
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
    let processes = [
        RawProcess(
            pid: 10,
            parentPID: 1,
            executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode",
            physicalFootprintBytes: 300_000_000
        ),
        RawProcess(
            pid: 11,
            parentPID: 10,
            executablePath: "/usr/local/bin/node",
            argv: ["node"],
            cwd: "/Users/x/work/octok-client/.worktrees/skill-manage-read-and-index",
            physicalFootprintBytes: 80_000_000
        ),
        RawProcess(
            pid: 777,
            parentPID: 1,
            executablePath: "/opt/homebrew/bin/waifud",
            argv: ["waifud"],
            physicalFootprintBytes: 30_000_000
        ),
    ]
    let monitor = SystemMonitor(
        source: SyntheticProcessSource(processes: processes),
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
            )
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
            )
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
            )
        )
    }
    .padding(16)
    .frame(width: 340)
}
