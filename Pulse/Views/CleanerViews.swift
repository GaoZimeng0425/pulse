import PulseCore
import SwiftUI

// MARK: - 清理页(p4-cleaner/03 扫描闭环 + 04 删除管线 + p4-uninstaller/01 四子药丸壳)

//
// 子页内容:开发者垃圾 = JunkListSection(04,CleanerJunkViews.swift)、空间地图 =
// 03 的扫描状态卡 + 结果摘要卡(旭日图 07 票接入 `mapSection`)、清理历史 =
// CleanHistorySection(04 列表 + 明细;「清空废纸篓」按钮 08 票)、应用 =
// AppListSection(p4-uninstaller/01,清单只读;残留 / 卸载动作 02/03 票)。空态
// 一律走 CardEmptyState(DESIGN.md 卡片家族,不手写空态)。

enum CleanerSubTab: String, CaseIterable, Hashable {
    // 顺序 = 2026-11-04 拍板 Q13:三个动手门在前、档案门殿后。
    case junk
    case map
    case apps
    case history

    var title: String {
        switch self {
        case .junk: "开发者垃圾"
        case .map: "空间地图"
        case .apps: "应用"
        case .history: "清理历史"
        }
    }
}

/// 清理页页头(popover-header/01):统一组件 `PageHeader` 全尺寸档——标题「清理」+ 扫描状态
/// 副标题 + 右侧扫描 / 取消按钮。由主窗口在页头槽位画(`MainWindowView.pageHeader`),
/// `CleanerTabView` 本体不再自画标题——此前主窗口页头与本页各画一次「清理」26pt,同页两个
/// 大标题(用户 2026-11-02 实见)。
struct CleanerPageHeader: View {
    let model: CleanerModel

    var body: some View {
        PageHeader(title: MetricTab.cleaner.title, subtitle: subtitle, style: .full) {
            HStack(spacing: 8) {
                Button {
                    model.beginEmptyTrash()
                } label: {
                    if model.trashPhase == .running || model.trashPhase == .inventorying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("清空废纸篓")
                    }
                }
                .disabled(model.trashPhase != .idle)
                .help("清空所有卷的废纸篓(永久删除,不可恢复)——腾出它占着的空间")
                if model.isScanning {
                    Button("取消扫描") { model.cancelScan() }
                        .buttonStyle(.borderedProminent)
                        .tint(Metric.disk.accentColor)
                } else {
                    Button(model.result == nil ? "扫描整台 Mac" : "重新扫描") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                        .tint(Metric.disk.accentColor)
                }
            }
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle:
            return "按需扫描,不常驻 · 结果缓存到下次扫描"
        case let .scanning(stats):
            return "正在扫描 · \(stats.entriesSeen) 项 · \(PulseFormat.memory(UInt64(max(0, stats.accountedBytes))))"
        case let .finished(result):
            // 清理后树不重扫(树只是快照),摘要数字会偏大——如实提示,不悄悄改数。
            let cleaned = model.sessionCleanedCount == 0
                ? ""
                : " · 本次已清理 \(model.sessionCleanedCount) 项,重新扫描刷新数字"
            // 缓存装载(票 11):标相对时间,让「这是旧结果」一眼可见。
            let age = model.loadedFromCache
                ? " · \(Self.relativeAgeText(from: model.scanFinishedAt))前(缓存)"
                : ""
            return "上次扫描 \(result.cancelled ? "已取消(部分)" : "完成") · \(model.scanDurationText) · 实际占用口径" + age + cleaned
        }
    }

    /// 相对时间人话(缓存装载的页头标注用)。
    private static func relativeAgeText(from date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<90: return "刚刚"
        case ..<3600: return "\(Int(seconds / 60)) 分钟"
        case ..<86400: return "\(Int(seconds / 3600)) 小时"
        default: return "\(Int(seconds / 86400)) 天"
        }
    }
}

extension CleanerModel {
    /// 上次扫描耗时人话(页头副标题与「扫描完成」卡共用)。
    var scanDurationText: String {
        guard let started = scanStartedAt, let finished = scanFinishedAt else { return "—" }
        let seconds = finished.timeIntervalSince(started)
        return seconds < 60 ? String(format: "%.0f 秒", seconds) : String(format: "%.1f 分钟", seconds / 60)
    }
}

struct CleanerTabView: View {
    let model: CleanerModel
    /// 应用卸载器模型(p4-uninstaller/01):无常驻采集,由 AppListSection 的
    /// task/onDisappear 驱动装载与取消;壳层只负责传递。
    let uninstallModel: UninstallModel
    @State private var subTab: CleanerSubTab = .junk
    /// 空间地图的导航态放在壳层(07):切子药丸再回来不丢下钻位置。
    @State private var mapDrillPath: String?
    @State private var mapTreeIndex = 0
    /// 轻桥(p4-uninstaller/05):地图「这块能清」→ 切垃圾子页并定位的组;
    /// JunkListSection 消费后自清。切走再回来地图下钻位置不丢(壳层既有态)。
    @State private var pendingJunkGroup: JunkGroup?

    private var accent: Color {
        Metric.disk.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            trashFeedbackBanner
            if let hint = model.permissionHint {
                fdaBanner(hint)
            }
            if let stale = model.cacheStalenessHint {
                stalenessBanner(stale)
            }
            subPillBar
            switch subTab {
            case .junk: JunkListSection(model: model, pendingGroup: $pendingJunkGroup)
            case .map: mapSection
            case .history: CleanHistorySection(model: model)
            case .apps: AppListSection(model: uninstallModel)
            }
        }
        // 进清理页即试装载落盘缓存(p4-cleaner/11):空态且无在跑扫描才读盘
        // (后台解码),已有结果 / 扫描中 / 无缓存都零动作;常驻稳态零成本。
        .task { model.loadCachedScan() }
        .sheet(isPresented: trashSheetPresented) {
            if case let .confirming(inventory) = model.trashPhase {
                TrashEmptyConfirmSheet(inventory: inventory) {
                    model.confirmEmptyTrash()
                } onCancel: {
                    model.cancelEmptyTrash()
                }
            }
        }
    }

    private var trashSheetPresented: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = model.trashPhase {
                    true
                } else {
                    false
                }
            },
            set: { presented in
                if !presented {
                    model.cancelEmptyTrash()
                }
            }
        )
    }

    /// 清空结果 / 空废纸篓短提示(Q10 同款:页内横幅,不发系统通知)。
    @ViewBuilder
    private var trashFeedbackBanner: some View {
        switch model.trashPhase {
        case let .finished(summary):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Surface.positive)
                Text(trashFinishedText(summary))
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                dismissTrashButton
            }
            .padding(10)
            .background(Surface.positive.opacity(0.1), in: .rect(cornerRadius: 10))
        default:
            if let notice = model.trashNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(notice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    dismissTrashButton
                }
                .padding(10)
                .background(Surface.cardHigh.opacity(0.6), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var dismissTrashButton: some View {
        Button {
            model.dismissTrashFeedback()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("关闭")
    }

    private func trashFinishedText(_ summary: TrashEmptySummary) -> String {
        var text = "已清空 \(summary.totalItems) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, summary.totalFreedBytes))))"
        if summary.totalSkipped > 0 {
            text += " · \(summary.totalSkipped) 项无权限跳过"
        }
        return text
    }

    /// 普通二次确认(票面:所有卷汇总 + 永久不可恢复 + 含其他 App 扔进的内容)。
    private struct TrashEmptyConfirmSheet: View {
        let inventory: TrashInventory
        let onConfirm: () -> Void
        let onCancel: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("清空废纸篓")
                    .font(.system(size: 17, weight: .bold))
                Text(TrashEmptying.confirmationText(for: inventory))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if inventory.volumes.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(inventory.volumes.filter { $0.items > 0 }) { volume in
                            HStack {
                                Text(volume.name)
                                    .font(.system(size: 12))
                                Spacer()
                                Text("\(volume.items) 项 · 约 \(PulseFormat.diskCapacity(UInt64(max(0, volume.bytes))))")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Surface.card, in: .rect(cornerRadius: 10))
                }
                HStack {
                    Spacer()
                    Button("取消", action: onCancel)
                    Button("永久清空", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(Surface.negative)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    /// 缓存过期提示(扫描后排除配置变了,数字只可能偏大):信息语气,不是警告琥珀。
    private func stalenessBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Surface.cardHigh.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    // MARK: FDA 引导(spec:未授时受限如实标注 + 直达系统设置)

    private func fdaBanner(_ hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Surface.warning)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("去授权") {
                // 全盘访问面板深链(系统设置);被拒不自动重试(TCC 纪律:静默只读,提示交给人)。
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Surface.warning.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private var subPillBar: some View {
        PillTabBar(CleanerSubTab.allCases, selection: $subTab, isGlassContainer: true) { tab in
            PillTabItem(title: tab.title, symbol: nil, tint: accent)
        }
    }

    // MARK: 子页

    /// 空间地图子页(07 = 旭日图 + 03 的结果摘要;两卡读同一次扫描)。
    @ViewBuilder private var mapSection: some View {
        switch model.phase {
        case .idle:
            CardEmptyState(
                title: "还没扫描过",
                detail: "点右上「扫描整台 Mac」——约 1 分钟,随时可取消",
                actionTitle: "开始扫描",
                action: { model.startScan() }
            )
            .cardShell(compact: false)
        case let .scanning(stats):
            scanningCard(stats)
        case let .finished(result):
            VStack(spacing: 12) {
                SpaceMapSection(
                    model: model,
                    drillPath: $mapDrillPath,
                    treeIndex: $mapTreeIndex,
                    home: model.junkHome,
                    onGoToJunk: { group in
                        subTab = .junk
                        pendingJunkGroup = group
                    }
                )
                summaryCard(result)
            }
        }
    }

    private func scanningCard(_ stats: ScanStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "sparkles", title: "正在扫描", tint: accent) {
                Text(elapsedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ProgressView(value: scanProgressFraction(stats))
                .tint(accent)
            HStack(spacing: 24) {
                StatValue(label: "已看条目", value: "\(stats.entriesSeen)")
                StatValue(label: "文件", value: "\(stats.files)")
                StatValue(label: "目录", value: "\(stats.directories)")
                StatValue(label: "已见占用", value: PulseFormat.memory(UInt64(max(0, stats.accountedBytes))))
            }
        }
        .cardShell(compact: false)
    }

    /// 进度没有已知总量(全卷文件数因机器而异),条只做"有进展"的视觉信号:
    /// 用一个缓慢逼近 1 的伪进度(不伪造百分比数字——假数不上屏,防御性数据纪律)。
    private func scanProgressFraction(_ stats: ScanStats) -> Double {
        // 真机 Data 卷(方案 A 扫描根)≈500 万项(2026-11-02 真引擎实测
        // 433 万文件 + 60 万目录;旧 340 万全卷口径是探针 15 的 Data 外推错误)。
        let guess = 5_000_000.0
        return min(0.95, Double(stats.entriesSeen) / guess)
    }

    private var elapsedText: String {
        guard let started = model.scanStartedAt else { return "0s" }
        return String(format: "%.0fs", Date().timeIntervalSince(started))
    }

    private func summaryCard(_ result: SpaceScanResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "sparkles", title: result.cancelled ? "扫描已取消(部分结果)" : "扫描完成", tint: accent) {
                Text(model.scanDurationText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            HStack(spacing: 24) {
                StatValue(label: "实际占用", value: totalAccountedText(result))
                StatValue(label: "文件", value: "\(result.stats.files)")
                StatValue(label: "目录", value: "\(result.stats.directories)")
                StatValue(label: "硬链接去重", value: "\(result.stats.hardlinkSkips)")
            }
            HStack(spacing: 24) {
                StatValue(label: "block 口径对照", value: fallbackText(result))
                StatValue(label: "部分扫描目录", value: "\(result.ledger.count)")
                StatValue(label: "iCloud 壳文件", value: "\(result.stats.datalessFiles)")
            }
            if let note = accountingNote(result) {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .cardShell(compact: false)
    }

    private func totalAccountedText(_ result: SpaceScanResult) -> String {
        PulseFormat.memory(UInt64(max(0, result.stats.accountedBytes)))
    }

    /// block 口径对照(逐文件块大小求和,克隆会重复计)——与实际占用的差
    /// = 克隆/硬链接省下的账。口径透明(GLOSSARY「实际占用」)。
    private func fallbackText(_ result: SpaceScanResult) -> String {
        let fallback = result.trees.reduce(Int64(0)) { $0 + $1.fallbackBytes }
        return PulseFormat.memory(UInt64(max(0, fallback)))
    }

    /// 口径注记(GLOSSARY「实际占用」:界面须标明用的是哪个口径)。
    private func accountingNote(_ result: SpaceScanResult) -> String? {
        let mixed = result.trees.contains { !$0.allReclaimableAccounting }
        let base = "大小按实际占用口径:APFS 克隆与快照共享部分不重复计,硬链接只计一次。"
        return mixed ? base + " 本卷部分文件未提供克隆明细,按块大小回退计入。" : base
    }
}
