import PulseCore
import SwiftUI

// 卸载确认弹窗 + 子页搜索框——自 CleanerAppViews 拆出(solid-split,纯搬运)。

// MARK: - 卸载确认弹窗(03;一期 CleanConfirmSheet 同配方,卸载域文案)

/// 确认清单(ADR-0008 闸门在卸载域的投影):逐行 = 路径 + 大小 + 去向标;
/// 彻底删除时逐行红标「永久删除」+ 页脚明示不可恢复(Q6);brew 应用注明
/// 本体由 Homebrew 卸载(永久),勾选残留按模式走。
struct AppUninstallConfirmSheet: View {
    let plan: AppUninstallPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var accent: Color {
        Surface.cleanAccent
    }

    struct Row: Identifiable {
        let id = UUID()
        let path: String
        let title: String
        let bytes: Int64?
        let permanent: Bool
        let viaBrew: Bool
    }

    private var rows: [Row] {
        var list = [
            Row(
                path: plan.appPath, title: plan.appName, bytes: plan.appBytes,
                permanent: plan.permanent || plan.isBrew, viaBrew: plan.isBrew
            ),
        ]
        let zapSet = Set(plan.receiptZapPaths)
        for leftover in plan.leftoverItems {
            // brew + 彻底删除:zap 声明域由 brew --zap 带走(与 app 本体同路由)。
            let viaBrew = plan.permanent && plan.isBrew && zapSet.contains(leftover.path)
            list.append(
                Row(
                    path: leftover.path, title: leftover.site.plainTitle, bytes: leftover.sizeBytes,
                    permanent: plan.permanent || viaBrew, viaBrew: viaBrew
                )
            )
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("卸载 \(plan.appName)")
                .font(.system(size: 17, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        confirmRow(row)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
            .background(Surface.card, in: .rect(cornerRadius: 12))
            Text(footerText)
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(plan.permanent ? Surface.negative : .primary)
            HStack(spacing: 8) {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .controlSize(.large)
                Button(confirmButtonTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(plan.permanent ? Surface.negative : accent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var subtitle: String {
        if plan.isBrew {
            return plan.permanent
                ? "应用本体与收据声明的残留由 Homebrew --zap 永久删除;其余勾选项一并永久删除"
                : "应用本体由 Homebrew 卸载(永久);勾选的残留移入废纸篓,可随时恢复"
        }
        return plan.permanent
            ? "全部不经废纸篓直接永久删除,不可恢复"
            : "全部移入废纸篓——清空废纸篓前可随时在 Finder 恢复"
    }

    private var confirmButtonTitle: String {
        plan.permanent ? "永久删除 \(rows.count) 项" : "移入废纸篓(\(rows.count) 项)"
    }

    private var footerText: String {
        let total = rows.compactMap(\.bytes).reduce(Int64(0), +)
        let prefix = "共 \(rows.count) 项 · 约 \(PulseFormat.memory(UInt64(max(0, total))))"
        return plan.permanent ? "\(prefix)——永久删除,不可恢复" : "共释放约 \(prefix)"
    }

    private var footnote: String {
        // 删前复核注记(p5-cleaner/03):残留列出后动过的会被跳过并说明原因;app 本体豁免。
        if plan.isBrew {
            return "Homebrew 卸载失败时本次零删除,不会绕过它直接删文件。残留动过或已不在的会跳过并说明原因。"
        }
        return "大小按实际占用计;失败项与列出后有变动的残留会跳过并说明原因。"
    }

    private func confirmRow(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.viaBrew ? "brew" : "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(row.viaBrew ? Surface.inkTertiary : accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                Text(row.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if row.permanent {
                Text(row.viaBrew ? "已卸载(brew,永久)" : "永久删除")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Surface.negative)
            } else {
                Text("废纸篓")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(row.bytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—")
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: CleanerListMetrics.valueWidth, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

// MARK: - 子页内搜索框

/// 清理页子页搜索框:与同排分段控件(regular,实测 24pt)等高、同圆角;
/// 视觉配方同主窗口工具栏搜索框(放大镜 secondary + plain 输入 12 + 清空钮)。
struct CleanerSearchField: View {
    /// 分段控件 regular 实测高(NSHostingView 离屏量得;两者必须相等才对齐)。
    static let height: CGFloat = 24

    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
    }
}
