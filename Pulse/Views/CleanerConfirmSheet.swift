import AppKit
import PulseCore
import SwiftUI

// 清理确认清单 sheet——自 CleanerJunkViews 拆出(solid-split,纯搬运)。

// MARK: 确认清单 sheet

/// 确认清单(ADR-0008 多重闸门之一):逐行 + 总量 + 实际占用口径注记。
/// 逐行的列照清单行来(图标 / 名称 / 路径 / 档位 chip / 数值定宽列),去掉勾选框与大小条。
/// 「移入废纸篓」按钮直接执行——常规二次确认就是这个 sheet 本身。
struct CleanConfirmSheet: View {
    let model: CleanerModel
    let plan: CleanPlan
    private var accent: Color {
        Surface.cleanAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("清理 \(plan.items.count) 项")
                .font(.system(size: 17, weight: .bold))
            Text("确认后全部移入废纸篓——清空废纸篓前可随时在 Finder 恢复")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.items) { item in
                        confirmRow(item)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
            .background(Surface.card, in: .rect(cornerRadius: 12))
            Text("共释放 \(PulseFormat.memory(UInt64(max(0, plan.totalBytes))))(实际占用口径:\(accountingNote))")
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
            // 删前复核注记(p5-cleaner/03):预期管理——动过的项会被跳过,完成后逐项说原因。
            VStack(alignment: .leading, spacing: 4) {
                Text("大小按实际占用计:APFS 克隆与硬链接不重复计。移入前逐项复核「扫描后未变动」:扫描后有变动或已不在原处的项会自动跳过并说明原因。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !plan.itemsWithoutSnapshot.isEmpty {
                    Text("\(plan.itemsWithoutSnapshot.count) 项来自旧版扫描、缺少快照,会被跳过——重新扫描后再清即可。")
                        .font(.system(size: 12))
                        .foregroundStyle(Surface.warning)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    model.cancelClean()
                }
                .controlSize(.large)
                Button("移入废纸篓") {
                    model.confirmClean()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(accent)
                .disabled(plan.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var accountingNote: String {
        if plan.hasPartialItems {
            return "含部分扫描项,数字偏小"
        }
        return plan.allReclaimableAccounting
            ? "APFS 克隆与硬链接不重复计"
            : "部分文件未提供克隆明细,按块大小回退计入"
    }

    private func confirmRow(_ item: JunkCandidate) -> some View {
        HStack(spacing: CleanerListMetrics.spacing) {
            CategoryIconTile(
                symbolName: item.symbolName,
                color: item.tier == .safe ? accent : Surface.warning,
                size: CleanerListMetrics.iconSize
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: CleanerListMetrics.titleFontSize, weight: .medium))
                        .lineLimit(1)
                    JunkMarkerChips(markers: item.markers)
                }
                Text(item.path)
                    .font(.system(size: CleanerListMetrics.subFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            TierChip(tier: item.tier)
            Text(PulseFormat.memory(UInt64(max(0, item.bytes))))
                .font(.system(size: CleanerListMetrics.valueFontSize, weight: .semibold))
                .monospacedDigit()
                .frame(width: CleanerListMetrics.valueWidth, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}
