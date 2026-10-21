import PulseCore
import SwiftUI

// MARK: - dev server 卡(工单 p1-history/08,总览页;2026-10-20 起弹窗同内容,紧凑档)

/// 总览页 dev server 卡:列出在跑的开发服务进程(闲置时长/内存/监听端口),
/// 「全部停止」上抛请求(确认流在 KillRequestFlow,绝不自动杀)。
/// 空态安静文案——没有 dev server 是常态,不制造焦虑。
struct DevServerCardView: View {
    let servers: [DevServerStatus]
    /// 弹窗紧凑档:卡 {rounded.card-compact} 12 + {spacing.card-padding-compact} 12。
    var isCompact = false
    let onStopAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "terminal", title: "Dev server", tint: Metric.cpu.accentColor) {
                if !servers.isEmpty {
                    Text("\(servers.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if servers.isEmpty {
                CardEmptyState(
                    title: "没有在跑的 dev server",
                    detail: "vite、next dev、vitest watch 等开发服务出现时,会在这里列出闲置时长与监听端口"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(servers) { server in
                        row(server)
                    }
                }
                HStack(spacing: 6) {
                    Button(action: onStopAll) {
                        Text(KillCopy.stopAllActionTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Surface.negative)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Surface.negative.opacity(0.1), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("经确认后向全部 dev server 发送结束信号,绝不自动执行")
                    Text("停止需逐个确认,绝不自动杀")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 一行 server:名(pid)/ 闲置 / 内存 / 端口。
    private func row(_ server: DevServerStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("pid \(server.pid)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            idleLabel(server)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(server.isIdle ? Metric.disk.accentColor : .secondary)
            Text(PulseFormat.memory(server.memoryBytes))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            portLabel(server.listeningPorts)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// 闲置列:闲置(琥珀)/未闲置;时长为 0(刚起)如实显示"闲置 0 秒"。
    private func idleLabel(_ server: DevServerStatus) -> Text {
        switch server.idleSeconds {
        case nil: Text("未闲置")
        case let seconds?: Text("闲置 \(PulseFormat.duration(seconds: seconds))")
        }
    }

    /// 端口列:无监听端口如实占位(不伪造),有则 :3000 :5173。
    private func portLabel(_ ports: [UInt16]) -> Text {
        ports.isEmpty
            ? Text("无监听端口")
            : Text(ports.map { ":\($0)" }.joined(separator: " "))
    }
}

#Preview("dev server 卡:空态与在跑") {
    let idle = DevServerStatus(
        pid: 4321, kind: .vite, displayName: "vite",
        memoryBytes: 84_000_000, idleSeconds: 25 * 3600 + 300, listeningPorts: [5173]
    )
    let fresh = DevServerStatus(
        pid: 9001, kind: .nextDev, displayName: "next dev",
        memoryBytes: 220_000_000, idleSeconds: nil, listeningPorts: [3000, 9229]
    )
    let silent = DevServerStatus(
        pid: 777, kind: .tscWatch, displayName: "tsc --watch",
        memoryBytes: 41_000_000, idleSeconds: 0, listeningPorts: []
    )
    return VStack(spacing: 16) {
        DevServerCardView(servers: []) {}
        DevServerCardView(servers: [idle, fresh, silent]) {}
    }
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
