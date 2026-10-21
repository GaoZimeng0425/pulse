import AppKit
import PulseCore
import SwiftUI

// MARK: - 组内下钻(工单 06)

/// 组卡展开后的下钻区:组内进程平铺列表(既定顺序 = 进程 CPU% 降序)。
/// 点进程行展开 / 收起详情。数据只读最近一轮采样(DrilldownState),
/// 展开与选中都不触发额外采集;LazyVStack 保证数十行滚动流畅。
/// 工单 08:进程详情的"结束进程"动作经 onEndProcess 上抛(确认对话框在 DashboardView)。
struct ProcessDrilldownView: View {
    let group: ProcessGroup
    let drilldown: DrilldownState
    /// 当前展开详情的进程(跨组唯一):nil = 全部收起。
    @Binding var selectedProcessID: pid_t?
    /// 处置请求上抛(工单 08):请求 ≠ 执行,确认对话框把关后才发信号。
    let onEndProcess: (KillTarget) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(drilldown.rows(for: group)) { row in
                ProcessRowView(row: row, isSelected: selectedProcessID == row.pid) {
                    selectedProcessID = selectedProcessID == row.pid ? nil : row.pid
                }
                if selectedProcessID == row.pid, let detail = drilldown.detail(for: row.pid) {
                    ProcessDetailView(detail: detail, onEnd: onEndProcess)
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
    }
}

// MARK: - 进程行

/// 进程行四要素(工单 06):进程名 / pid / CPU% / 内存;选中态高亮。
/// P0.6-02:主窗口进程表传入 meterFraction 时在行内附 6pt 占比 meter 条
/// (CPU 指标强调色,榜首归一);弹窗下钻行保持紧凑(缺省 nil 不画条)。
struct ProcessRowView: View {
    let row: ProcessRowModel
    let isSelected: Bool
    /// 占比条取值(榜首归一):nil = 不画。进程行无类别语境,条恒用 CPU 指标强调色。
    var meterFraction: Double?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(row.pid)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(PulseFormat.cpuPercent(row.cpuPercent))
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                    Text(PulseFormat.memory(row.memoryBytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                if let meterFraction {
                    MeterBar(fraction: meterFraction, tint: Metric.cpu.accentColor)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 进程详情

/// 进程详情(点进程行展开):cwd、完整 argv(可滚动 / 可复制,长 argv 不破坏布局)、
/// 启动时长("已 25 分钟")、父链面包屑一行("rustc ← cargo ← node ← Zcode")。
/// 工单 08:详情尾部"结束进程"入口(请求上抛,确认对话框把关后才发信号)。
struct ProcessDetailView: View {
    let detail: ProcessDetailModel
    /// 处置请求上抛(工单 08):请求 ≠ 执行。
    let onEnd: (KillTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("父链") {
                Text(detail.parentChainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            field("目录") {
                Text(detail.process.cwd ?? "不可读")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(detail.process.cwd == nil ? .tertiary : .primary)
            }
            field("argv") {
                argvField
            }
            field("时长") {
                Text(PulseFormat.uptime(startedAt: detail.process.startTime, now: Date()))
                    .monospacedDigit()
            }
            endProcessRow
        }
        .font(.caption)
        .padding(12)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    /// "结束进程"入口:点击只发起请求,确认对话框(取消为默认焦点)把关。
    private var endProcessRow: some View {
        HStack {
            Spacer()
            Button {
                onEnd(detail.process.killTarget)
            } label: {
                Label("结束进程", systemImage: "xmark.octagon")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Surface.negative)
            .controlSize(.small)
            .help("结束该进程(需确认)")
        }
    }

    /// 完整 argv:一个参数一行(参数边界一目了然,长参数换行不破坏布局),
    /// 区域超高时纵向滚动;`.textSelection` + 复制按钮双通道可复制。
    private var argvField: some View {
        HStack(alignment: .top, spacing: 6) {
            if detail.process.argv.isEmpty {
                Text("不可读")
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(detail.process.argv.enumerated()), id: \.offset) { _, argument in
                            Text(argument)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 88)
                .scrollBounceBehavior(.basedOnSize)
            }
            if !detail.process.argv.isEmpty {
                Button {
                    copyArgv()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("复制完整命令行")
                .accessibilityLabel("复制完整命令行")
            }
        }
    }

    /// 复制按钮:整条 argv 以空格连接成命令行,写入系统剪贴板。
    private func copyArgv() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.process.argv.joined(separator: " "), forType: .string)
    }

    private func field(
        _ label: String,
        @ViewBuilder _ value: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 预览(Synthetic 源,spec 测试决策:UI 以预览 + 手动下钻验收)

#Preview("下钻:门禁树 + 长 argv") {
    let now = Date()
    let worktree = "/Users/x/work/octok-client/.worktrees/skill-manage-read-and-index"
    let longArgument = "--extern=" + String(repeating: "octok_client=", count: 40)
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
            argv: ["node", "server.js", "--watch"],
            cwd: worktree,
            cpuTimeNanoseconds: 500_000_000,
            physicalFootprintBytes: 80_000_000,
            startTime: now.addingTimeInterval(-25 * 60)
        ),
        RawProcess(
            pid: 100,
            parentPID: 11,
            executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
            argv: ["rustc", "--crate-name", "octok", longArgument],
            cwd: worktree,
            cpuTimeNanoseconds: 4_500_000_000,
            physicalFootprintBytes: 200_000_000,
            startTime: now.addingTimeInterval(-40)
        ),
    ]
    let snapshot = ProcessSnapshot(takenAt: now, processes: processes)
    let state = DrilldownState(
        snapshot: snapshot,
        lineage: LineageRegistry().registeringBirths(in: snapshot),
        processCPU: [
            ProcessCPU(pid: 10, cpuPercent: 3),
            ProcessCPU(pid: 11, cpuPercent: 5),
            ProcessCPU(pid: 100, cpuPercent: 90),
        ]
    )
    let group = ProcessGroup(
        id: .project(root: "/Users/x/work/octok-client", worktreeName: "skill-manage-read-and-index"),
        name: "octok-client @ skill-manage-read-and-index",
        processes: [processes[2], processes[1]],
        cpuPercent: 95,
        memoryBytes: 280_000_000
    )
    return ProcessDrilldownView(
        group: group,
        drilldown: state,
        selectedProcessID: .constant(100),
        onEndProcess: { _ in }
    )
    .padding(16)
    .frame(width: 340)
}

#Preview("进程行") {
    // 上两行 = 主窗口形态(带榜首归一 meter,90 为榜首);末行 = 弹窗下钻形态(无条)。
    VStack(spacing: 4) {
        ProcessRowView(
            row: ProcessRowModel(pid: 100, name: "rustc", cpuPercent: 90, memoryBytes: 200_000_000),
            isSelected: true,
            meterFraction: MeterNormalization.fraction(90, leader: 90),
            onToggle: {}
        )
        ProcessRowView(
            row: ProcessRowModel(pid: 11, name: "node", cpuPercent: 5, memoryBytes: 80_000_000),
            isSelected: false,
            meterFraction: MeterNormalization.fraction(5, leader: 90),
            onToggle: {}
        )
        ProcessRowView(
            row: ProcessRowModel(pid: 12, name: "esbuild", cpuPercent: 2, memoryBytes: 40_000_000),
            isSelected: false,
            onToggle: {}
        )
    }
    .padding(12)
    .frame(width: 340)
}
