import PulseCore
import SwiftUI

// MARK: - 清理页

//
// 页面骨架:页头(CleanerPageHeader)+ 子页药丸条 + 四个子页:总览
// (CleanerOverviewViews.swift)、全部清单(JunkListSection,CleanerListCommonViews.swift)、
// 应用(AppListSection,CleanerAppViews.swift)、清理历史(CleanHistorySection,
// CleanerHistoryViews.swift)。这里只写壳层的路由,各块的做法在各自文件里。
// 只出现在主窗口,弹窗没有这一页;主窗口也不给本页套外层滚动——各子页自己管滚动。
// 文件后半的 DiskSpaceMapSection 属磁盘页。

enum CleanerSubTab: String, CaseIterable, Hashable {
    // 顺序即药丸顺序:总览居首,因为它是默认落地子页(进页先看"能省多少"再动手);
    // 之后是两个动手页(全部清单、应用),只读的清理历史殿后。
    case overview
    case junk
    case apps
    case history

    var title: String {
        switch self {
        case .overview: "总览"
        // 标题只是文案,`junk` 这个标识不随它改名——下钻和跨页轻桥都按它落页。
        case .junk: "全部清单"
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
    /// 触发中告警(2026-11-16):与其它 tab 同一页头小条配件,出现/消失不推内容下移。
    let alerts: AlertCenter

    var body: some View {
        PageHeader(title: MetricTab.cleaner.title, subtitle: subtitle, style: .full) {
            // 「清空废纸篓」不在这里:入口随读数走,在总览的废纸篓卡上。
            HStack(spacing: 8) {
                AlertHeaderIndicator(center: alerts)
                if model.isScanning {
                    Button("取消扫描") { model.cancelScan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Surface.cleanAccent)
                } else {
                    Button(model.result == nil ? "扫描整台 Mac" : "重新扫描") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(Surface.cleanAccent)
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
            // 卸载残留注记(p5-cleaner/02):检测了说「含」,没检测(全集不完整)如实说「未检测」。
            let orphanNote = model.orphanDetectionActive
                ? " · 含卸载残留检测"
                : (model.orphanDetectionUnavailableReason == nil ? "" : " · 卸载残留未检测")
            return "上次扫描 \(result.cancelled ? "已取消(部分)" : "完成") · \(model.scanDurationText) · 实际占用口径"
                + orphanNote + age + cleaned
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
    /// 跨页轻桥(tab-regroup/03):磁盘页空间地图「这块能清」落下的组;进页消费
    /// 后自清。地图迁磁盘页后唯一跨页入口,同页内轻桥仍是壳层 pendingJunkGroup。
    @Binding var pendingCrossPageJunkGroup: JunkGroup?
    /// 默认落地子页 = 总览。
    @State private var subTab: CleanerSubTab = .overview
    /// 轻桥(p4-uninstaller/05):地图「这块能清」→ 切垃圾子页并定位的组;
    /// JunkListSection 消费后自清。(地图已迁磁盘页 tab-regroup/03,本桥保留
    /// 供跨页落点投递。)
    @State private var pendingJunkGroup: JunkGroup?
    /// 总览下钻(p6-cleaner/03):点模块大卡 → 全部清单按品类过滤(nil = 全量)。
    /// 勾选存模型层,过滤切换天然不丢;返回 / 药丸直切清空(见 pillSelection)。
    @State private var junkFilter: JunkGroup?

    private var accent: Color {
        Surface.cleanAccent
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
            case .overview:
                CleanerOverviewSection(model: model) { group in
                    // 下钻:切清单 + 过滤;轻桥定位不需要(过滤视图只此一组)。
                    pendingJunkGroup = nil
                    junkFilter = group
                    subTab = .junk
                } onOneClickClean: {
                    // 一键清理:选完跳「全部清单」——确认单挂在那张卡上,
                    // 同一事务切页后 sheet 随 cleanPhase=.confirming 弹出。
                    pendingJunkGroup = nil
                    junkFilter = nil
                    subTab = .junk
                    model.selectAllSafeAndRequestClean()
                }
                // 空态卡贴顶,不悬中。
                .frame(maxHeight: .infinity, alignment: .top)
            case .junk:
                JunkListSection(
                    model: model,
                    pendingGroup: $pendingJunkGroup,
                    groupFilter: $junkFilter,
                    onBackToOverview: {
                        junkFilter = nil
                        subTab = .overview
                    }
                )
                .frame(maxHeight: .infinity)
            case .apps:
                AppListSection(model: uninstallModel)
                    // 装载中/空态卡贴顶,不悬中。
                    .frame(maxHeight: .infinity, alignment: .top)
            case .history:
                CleanHistorySection(model: model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 进清理页即试装载落盘缓存(p4-cleaner/11):空态且无在跑扫描才读盘
        // (后台解码),已有结果 / 扫描中 / 无缓存都零动作;常驻稳态零成本。
        // 同拍消费跨页轻桥(tab-regroup/03):磁盘页地图点「这块能清」切过来时,
        // 落全部清单 + 定位组 + 清过滤(轻桥定位 = 全量清单里的组,非总览下钻态)。
        .task {
            model.loadCachedScan()
            if let group = pendingCrossPageJunkGroup {
                junkFilter = nil
                subTab = .junk
                pendingJunkGroup = group
                pendingCrossPageJunkGroup = nil
            }
        }
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
                    .font(.system(size: IconSize.inline, weight: .medium))
                    .foregroundStyle(Surface.positive)
                Text(trashFinishedText(summary))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                dismissTrashButton
            }
            .padding(10)
            .background(Surface.positive.opacity(0.1), in: .rect(cornerRadius: 10))
        default:
            if let notice = model.trashNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: IconSize.inline))
                        .foregroundStyle(.secondary)
                    Text(notice)
                        .font(.system(size: 11))
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
                .font(.system(size: IconSize.inline))
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
                        .controlSize(.large)
                    Button("永久清空", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
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
                .font(.system(size: IconSize.inline))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Surface.cardHigh.opacity(0.6), in: .rect(cornerRadius: 10))
    }

    // MARK: FDA 引导(spec:未授时受限如实标注 + 直达系统设置)

    private func fdaBanner(_ hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: IconSize.inline))
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
            // 横幅降级出口统一配方(与告警横幅「打开系统通知设置」同款):.link 文字按钮。
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(12)
        .background(Surface.warning.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private var subPillBar: some View {
        // 子页条走 comfortable 档(清理页全页舒适密度);主窗口工具栏 / 历史页
        // 仍是 regular,不跟着改。
        PillTabBar(
            CleanerSubTab.allCases,
            selection: pillSelection,
            isGlassContainer: true,
            size: .comfortable
        ) { tab in
            PillTabItem(title: tab.title, symbol: nil, tint: accent)
        }
    }

    /// 药丸交互专用 selection(p6-cleaner/03):用户点药丸 = 无下钻态——清品类过滤
    /// (下钻态里点「全部清单」看到的必须是全量;程序化切页不经过这里,过滤得以保留)。
    private var pillSelection: Binding<CleanerSubTab> {
        Binding(
            get: { subTab },
            set: { newValue in
                subTab = newValue
                junkFilter = nil
            }
        )
    }

    // MARK: 子页
}

// MARK: - 磁盘页空间地图块(tab-regroup/03)

/// 磁盘页的空间地图块:读清理扫描的同一条管线(CleanerModel),按扫描态切三形状——
/// 空态引导(就地「扫描整台 Mac」,本页无页头按钮)/ 扫描中(进度卡)/ 完成
/// (地图卡 + 结果摘要卡,上下堆叠)。
/// 两处要注意:①不套子页 ScrollView——磁盘页卡片流本就在主窗口外层滚动里,
/// 图表区高度靠 `containerRelativeFrame` 按滚动视口钳制,本块不要再套滚动;
/// ②「这块能清」是跨页轻桥——经 `DashboardModel.pendingCleanerJunkGroup` 落到
/// 清理页全部清单定位,下钻位置同样挂 DashboardModel(切 tab 不丢)。
struct DiskSpaceMapSection: View {
    let model: CleanerModel
    @Binding var drillPath: String?
    @Binding var treeIndex: Int
    /// 「这块能清」跨页轻桥:宿主(MetricTabStack)记路由态并切清理 tab。
    let onGoToJunk: (JunkGroup) -> Void

    private var accent: Color {
        Surface.cleanAccent
    }

    var body: some View {
        switch model.phase {
        case .idle:
            CardEmptyState(
                title: "还没扫描过",
                detail: "扫描整台 Mac——约 1 分钟,随时可取消;清单与清理历史在「清理」页",
                actionTitle: "扫描整台 Mac",
                action: { model.startScan() }
            )
            .cardShell(compact: false)
        case let .scanning(stats):
            scanningCard(stats)
        case let .finished(result):
            VStack(spacing: 12) {
                SpaceMapSection(
                    model: model,
                    drillPath: $drillPath,
                    treeIndex: $treeIndex,
                    onGoToJunk: onGoToJunk
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
        // 全盘扫描(Data 卷)约 500 万项的量级估计,机器而异。
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
            // 卡不够宽时整行放不下:ViewThatFits 折行(4 项 → 2+2、3 项 → 2+1),
            // 放得下首选整行原样。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    StatValue(label: "实际占用", value: totalAccountedText(result))
                    StatValue(label: "文件", value: "\(result.stats.files)")
                    StatValue(label: "目录", value: "\(result.stats.directories)")
                    StatValue(label: "硬链接去重", value: "\(result.stats.hardlinkSkips)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 24) {
                        StatValue(label: "实际占用", value: totalAccountedText(result))
                        StatValue(label: "文件", value: "\(result.stats.files)")
                    }
                    HStack(spacing: 24) {
                        StatValue(label: "目录", value: "\(result.stats.directories)")
                        StatValue(label: "硬链接去重", value: "\(result.stats.hardlinkSkips)")
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    StatValue(label: "block 口径对照", value: fallbackText(result))
                    StatValue(label: "部分扫描目录", value: "\(result.ledger.count)")
                    StatValue(label: "iCloud 壳文件", value: "\(result.stats.datalessFiles)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 24) {
                        StatValue(label: "block 口径对照", value: fallbackText(result))
                        StatValue(label: "部分扫描目录", value: "\(result.ledger.count)")
                    }
                    HStack(spacing: 24) {
                        StatValue(label: "iCloud 壳文件", value: "\(result.stats.datalessFiles)")
                    }
                }
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
