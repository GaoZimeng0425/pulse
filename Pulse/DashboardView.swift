import SwiftUI

/// 弹窗主页:Top 组卡(静态假数据),组 CPU% 降序平铺。
struct DashboardView: View {
    var body: some View {
        VStack(spacing: 12) {
            header
            ForEach(FakeSnapshot.topGroups) { group in
                GroupCardView(group: group)
            }
            footer
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
                Text("系统 CPU 负载 \(PulseFormat.cpuPercent(FakeSnapshot.systemCPULoad))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private var footer: some View {
        Text("静态假数据 · 采样尚未接入")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// 组卡:组名 + 组 CPU% + 内存 + 进程数。
struct GroupCardView: View {
    let group: GroupSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(group.processCount) 进程")
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
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }

    /// 项目组("名字 @ worktree")用锤子图标,App 组用立方体图标。
    private var icon: String {
        group.name.contains(" @ ") ? "hammer" : "shippingbox"
    }
}
