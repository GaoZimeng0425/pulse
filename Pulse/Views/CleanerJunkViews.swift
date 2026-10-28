import AppKit
import PulseCore
import SwiftUI

// MARK: - 开发者垃圾清单(p4-cleaner/04;形态 = 原型 B 变体,DESIGN.md 卡片家族 + 排行行配方)

//
// 本文件只做呈现与转发,状态全在 CleanerModel(PulseCore 纯值驱动):
//   清单卡(组分段 → 行 → 动作条)→ 确认 sheet(逐行 + 总量 + 口径注记)→ 结果卡
//   (失败如实报)→ 右键排除(持久化,再扫描 / 再列清单立即生效)。
// 行配方借自排行列表(RankingListMetrics:图标 22 / 间距 10 / meter 110 / 数值 13
// semibold 等宽定宽列 / 行内距 6×7);档位 chip 用状态 chip 配方(胶囊、tint 14~16% 底
// + 同色文字,DESIGN.md §状态 chip——此处映射的是 GLOSSARY「安全档」两态,不是负载警示)。

/// 清单子页(换掉 03 票的占位卡):未扫描给 CTA,扫描中给提示,完成给清单卡。
struct JunkListSection: View {
    let model: CleanerModel

    var body: some View {
        switch model.phase {
        case .idle:
            CardEmptyState(
                title: "先扫描才能识别垃圾",
                detail: "点右上「扫描整台 Mac」——白名单识别,未识别的目录不会出现",
                actionTitle: "开始扫描",
                action: { model.startScan() }
            )
            .cardShell(compact: false)
        case .scanning:
            CardEmptyState(
                title: "正在扫描",
                detail: "扫描结束后这里出现可回收清单(进度在「空间地图」子页)"
            )
            .cardShell(compact: false)
        case .finished:
            JunkListCard(model: model)
        }
    }
}

// MARK: 清单卡

private struct JunkListCard: View {
    let model: CleanerModel
    private var accent: Color {
        Metric.disk.accentColor
    }

    private var candidates: [JunkCandidate] {
        model.candidates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            reportCard
            if candidates.isEmpty {
                CardEmptyState(
                    title: "白名单没有识别出可回收项",
                    detail: "只显示担保过的目录(ADR-0008);这台机器的全局工具缓存已经干净"
                )
            } else {
                groups
                actionBar
            }
        }
        .cardShell(compact: false)
        .sheet(isPresented: confirmPresented) {
            CleanConfirmSheet(model: model, plan: model.plan)
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = model.cleanPhase { true } else { false }
            },
            set: { wanted in
                if !wanted {
                    model.cancelClean()
                }
            }
        )
    }

    private var header: some View {
        CardHeader(symbolName: "trash", title: "开发者垃圾", tint: accent) {
            Text(summaryText)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private var summaryText: String {
        let total = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        let safe = candidates.filter { $0.tier == .safe }.reduce(Int64(0)) { $0 + $1.bytes }
        let check = total - safe
        return "共 \(PulseFormat.memory(UInt64(max(0, total)))) · 可安全清理 \(PulseFormat.memory(UInt64(max(0, safe)))) / 先检查 \(PulseFormat.memory(UInt64(max(0, check))))"
    }

    private var groups: some View {
        let byGroup = Dictionary(grouping: candidates, by: \.group)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(JunkGroup.allCases.filter { byGroup[$0] != nil }, id: \.self) { group in
                groupHeader(group, items: byGroup[group] ?? [])
                ForEach(byGroup[group] ?? []) { candidate in
                    JunkRow(
                        candidate: candidate,
                        leader: candidates.map(\.bytes).max() ?? 0,
                        accent: accent,
                        isSelected: model.isSelected(candidate),
                        disabled: isBusy,
                        onToggle: { model.toggle(candidate) },
                        onExclude: { model.exclude(candidate.path) }
                    )
                }
            }
        }
    }

    private func groupHeader(_ group: JunkGroup, items: [JunkCandidate]) -> some View {
        let sum = items.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack {
            Text(group.title)
            Spacer()
            Text(PulseFormat.memory(UInt64(max(0, sum))))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .padding(.horizontal, RankingListMetrics.rowInset)
    }

    private var isBusy: Bool {
        if case .running = model.cleanPhase { return true }
        return false
    }

    // MARK: 动作条(勾选后的唯一删除入口)

    @ViewBuilder private var actionBar: some View {
        let plan = model.plan
        switch model.cleanPhase {
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在移入废纸篓…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        case .idle, .finished, .confirming:
            if plan.isEmpty {
                Text("默认全不勾 · 右键任意行可排除该目录")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    Text("已选 \(plan.items.count) 项 · \(PulseFormat.memory(UInt64(max(0, plan.totalBytes))))")
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Button("清除勾选") {
                        model.clearSelection()
                    }
                    Button("清理…") {
                        model.requestClean()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                }
                .controlSize(.regular)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: 结果卡

    @ViewBuilder private var reportCard: some View {
        if case let .finished(report, historyRecorded) = model.cleanPhase {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Surface.positive)
                    Text(report.failed.isEmpty
                         ? "已移入废纸篓 \(report.recycled.count) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes))))"
                         : "已移入废纸篓 \(report.recycled.count) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes)))) · \(report.failed.count) 项失败")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Button("知道了") {
                        model.dismissCleanReport()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                Text(historyRecorded ? "已记入清理历史" : "清理历史不可用,本次未记录(历史库未打开)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(historyRecorded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Surface.warning))
                ForEach(report.failed, id: \.path) { item in
                    if case let .failed(reason) = item.outcome {
                        Text("\(item.path) — \(reason)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Surface.negative)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        }
    }
}

// MARK: 行

private struct JunkRow: View {
    let candidate: JunkCandidate
    let leader: Int64
    let accent: Color
    let isSelected: Bool
    let disabled: Bool
    let onToggle: () -> Void
    let onExclude: () -> Void

    var body: some View {
        HStack(spacing: RankingListMetrics.spacing(compact: false)) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
            CategoryIconTile(
                symbolName: candidate.symbolName,
                color: candidate.tier == .safe ? accent : Surface.warning,
                size: RankingListMetrics.iconSize(compact: false)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title)
                    .font(.system(size: RankingListMetrics.valueFontSize(compact: false), weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            TierChip(tier: candidate.tier)
            MeterBar(
                fraction: MeterNormalization.fraction(Double(candidate.bytes), leader: Double(leader)),
                tint: accent
            )
            .frame(width: RankingListMetrics.meterWidth(compact: false))
            Text(PulseFormat.memory(UInt64(max(0, candidate.bytes))))
                .font(.system(size: RankingListMetrics.valueFontSize(compact: false), weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: RankingListMetrics.valueWidth(compact: false), alignment: .trailing)
        }
        .padding(.horizontal, RankingListMetrics.rowInset)
        .padding(.vertical, 7)
        .background(
            isSelected ? Surface.cardHigh.opacity(0.7) : Color.clear,
            in: .rect(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !disabled {
                onToggle()
            }
        }
        .contextMenu {
            Button("排除此目录(不再扫描、不再出现)") {
                onExclude()
            }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
            }
        }
        .help(candidate.rationale)
    }

    private var subtitle: String {
        candidate.path + (candidate.isPartial ? " · 部分扫描" : "")
    }
}

/// 安全档 chip(GLOSSARY「安全档」两态):状态 chip 配方——胶囊、tint 14~16% 底 + 同色文字。
/// 可安全清理 → positive;先检查 → warning。这不是负载警示(那三处映射集中在
/// StatusBadgeRules),是删除安全语义,只在这里出。
struct TierChip: View {
    let tier: CleanSafetyTier

    private var tint: Color {
        tier == .safe ? Surface.positive : Surface.warning
    }

    var body: some View {
        Text(tier.title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: .capsule)
    }
}

// MARK: 确认清单 sheet

/// 确认清单(ADR-0008 多重闸门之一):逐行 + 总量 + 实际占用口径注记。
/// 「移入废纸篓」按钮直接执行——常规二次确认就是这个 sheet 本身。
private struct CleanConfirmSheet: View {
    let model: CleanerModel
    let plan: CleanPlan
    private var accent: Color {
        Metric.disk.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("清理 \(plan.items.count) 项")
                .font(.system(size: 17, weight: .bold))
            Text("确认后全部移入废纸篓——清空废纸篓前可随时在 Finder 恢复")
                .font(.system(size: 11))
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
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
            HStack(spacing: 8) {
                Text("大小按实际占用计:APFS 克隆与硬链接不重复计。唯一不可逆的操作是「清空废纸篓」,不在这里。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    model.cancelClean()
                }
                Button("移入废纸篓") {
                    model.confirmClean()
                }
                .buttonStyle(.borderedProminent)
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
        HStack(spacing: RankingListMetrics.spacing(compact: false)) {
            CategoryIconTile(
                symbolName: item.symbolName,
                color: item.tier == .safe ? accent : Surface.warning,
                size: RankingListMetrics.iconSize(compact: false)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            TierChip(tier: item.tier)
            Text(PulseFormat.memory(UInt64(max(0, item.bytes))))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: RankingListMetrics.valueWidth(compact: false), alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}

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
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "clock.arrow.circlepath", title: "清理历史", tint: Metric.disk.accentColor) {
                Text("\(model.historyRuns?.count ?? 0) 次")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ForEach(model.historyRuns ?? []) { run in
                CleanRunDisclosureRow(model: model, run: run)
            }
            Text("清理历史永久保留在本地;大小按清理当时扫描的实际占用口径。")
                .font(.system(size: 10.5))
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
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Text("\(run.itemCount) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, run.freedBytes))))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if run.failedCount > 0 {
                        Text("\(run.failedCount) 项失败")
                            .font(.system(size: 11))
                            .foregroundStyle(Surface.negative)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if expanded {
                items
            }
        }
        .padding(.horizontal, RankingListMetrics.rowInset)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var items: some View {
        if let records = model.historyItems[run.id] {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(records) { record in
                    CleanHistoryItemRow(record: record)
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 4)
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.leading, 18)
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(record.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(PulseFormat.memory(UInt64(max(0, record.bytes))))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(outcomeText)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var outcomeText: AttributedString {
        switch record.outcome {
        case let .recycled(destination):
            var text = AttributedString("→ " + (destination as NSString).lastPathComponent)
            text.foregroundColor = Color.secondary
            return text
        case let .failed(reason):
            var text = AttributedString("失败:" + reason)
            text.foregroundColor = Surface.negative
            return text
        }
    }
}
