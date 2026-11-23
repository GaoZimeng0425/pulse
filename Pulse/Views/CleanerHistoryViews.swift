import AppKit
import PulseCore
import SwiftUI

// 清理历史子页(列表 + 明细 + 清空废纸篓)——自 CleanerJunkViews 拆出(solid-split,纯搬运)。

// MARK: 清理历史子页(04 交付列表 + 明细;「清空废纸篓」按钮 08 票)

struct CleanHistorySection: View {
    let model: CleanerModel

    var body: some View {
        Group {
            if !model.historyAvailable {
                CardEmptyState(
                    title: "清理历史不可用",
                    detail: "历史库未能打开;清理本身不受影响,只是无法记录"
                )
                .cardShell(compact: false)
            } else {
                historyCard
            }
        }
        .task {
            await model.loadHistory()
        }
    }

    @ViewBuilder private var historyCard: some View {
        if model.historyRuns == nil {
            if model.historyLoadFailed {
                CardEmptyState(title: "清理历史读取失败", detail: "稍后重进本页重试")
                    .cardShell(compact: false)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        } else if model.historyRuns?.isEmpty == true {
            CardEmptyState(
                title: "还没有清理记录",
                detail: "每次清理的时间、释放量与逐项去向会记在这里,永久保留"
            )
            .cardShell(compact: false)
        } else {
            runsList
        }
    }

    private var runsList: some View {
        // 四子页统一形态(2026-11-09 用户实报收编):一张大卡 + CardHeader
        // (垃圾/地图同构);卡内每条 run 一张小卡(2026-11-08 引入,保留),
        // 展开明细 = 卡内缩进裸行,脚注钉在卡底。
        // 主窗口行容器收编 LazyVStack(DESIGN.md 规则;历史随时间只增不减,懒加载最划算)。
        LazyVStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "clock.arrow.circlepath", title: "清理历史", tint: Surface.cleanAccent) {
                Text("\(model.historyRuns?.count ?? 0) 次")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.historyRuns ?? []) { run in
                    CleanRunDisclosureRow(model: model, run: run)
                }
            }
            Text("清理历史永久保留在本地;大小按清理当时扫描的实际占用口径。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .cardShell(compact: false)
    }
}

private struct CleanRunDisclosureRow: View {
    let model: CleanerModel
    let run: CleanRunRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                expanded.toggle()
                if expanded {
                    Task { await model.loadHistoryItems(runID: run.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    // 类型标记(Q15):卸载带应用图标、清理带垃圾桶,扫一眼可分;不做筛选分页。
                    Image(systemName: run.isUninstall ? "app.dashed" : "trash")
                        .font(.system(size: IconSize.inline))
                        .foregroundStyle(.tertiary)
                        .help(run.isUninstall ? "应用卸载" : "清理")
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 14.5, weight: .medium))
                        .monospacedDigit()
                    Text("\(run.itemCount) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, run.freedBytes))))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if run.failedCount > 0 {
                        Text("\(run.failedCount) 项失败")
                            .font(.system(size: 12))
                            .foregroundStyle(Surface.negative)
                    }
                    Spacer(minLength: 8)
                    // 展开/收起统一样式(与项目大卡点头排同款):箭头在行右缘,
                    // 右指、展开时旋转向下、整行可点——不再独一份行首三角。
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.inline, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 24, height: 24)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                items
            }
        }
        .padding(.horizontal, CleanerListMetrics.rowInset)
        .padding(.vertical, CleanerListMetrics.rowVerticalPadding)
        // 每条 run 一张小卡(与垃圾条目同配方):card-hi 抬升底、12 圆角。
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var items: some View {
        // 卡内缩进裸行(与项目大卡产物子项同款):只缩进不套小卡。
        if let records = model.historyItems[run.id] {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(records) { record in
                    CleanHistoryItemRow(record: record)
                }
            }
            .padding(.leading, CleanerListMetrics.indentLeading)
            .padding(.trailing, CleanerListMetrics.rowInset)
            .padding(.bottom, 4)
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.leading, CleanerListMetrics.indentLeading)
        }
    }
}

private struct CleanHistoryItemRow: View {
    let record: CleanItemRecord

    var body: some View {
        HStack(spacing: 8) {
            TierChip(tier: record.tier)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                Text(record.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(PulseFormat.memory(UInt64(max(0, record.bytes))))
                .font(.system(size: 14.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(outcomeText)
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            // 找回(Q12):只在废纸篓去向存在时亮;永久删除无去向,不画。
            if case let .recycled(destination) = record.outcome {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destination)])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: IconSize.inline))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("在 Finder 废纸篓中显示(选中它,可拖回原位恢复)")
            }
        }
    }

    private var outcomeText: AttributedString {
        switch record.outcome {
        case let .recycled(destination):
            var text = AttributedString("→ " + (destination as NSString).lastPathComponent)
            text.foregroundColor = Color.secondary
            return text
        case .permanentlyDeleted(route: .direct):
            // p4-uninstaller/03:彻底删除直删——无去向路径,标明不可恢复。
            var text = AttributedString("永久删除")
            text.foregroundColor = Surface.negative
            return text
        case .permanentlyDeleted(route: .brew):
            var text = AttributedString("已卸载(brew,永久)")
            text.foregroundColor = Surface.negative
            return text
        case let .failed(reason):
            var text = AttributedString("失败:" + reason)
            text.foregroundColor = Surface.negative
            return text
        }
    }
}
