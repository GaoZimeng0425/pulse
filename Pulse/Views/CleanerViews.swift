import PulseCore
import SwiftUI

// MARK: - 清理页(p4-cleaner/03):手动全卷扫描闭环 + 三子药丸壳

//
// 子页内容:开发者垃圾 = p4-cleaner/04、空间地图 = p4-cleaner/07、清理历史 =
// p4-cleaner/04/08——本票交付扫描状态卡 + 结果摘要卡(真数据),占位卡走
// CardEmptyState(DESIGN.md 卡片家族,不手写空态)。整页只读,零删除控件
// (删除管线 04 票接入)。

enum CleanerSubTab: String, CaseIterable, Hashable {
    case junk
    case map
    case history

    var title: String {
        switch self {
        case .junk: "开发者垃圾"
        case .map: "空间地图"
        case .history: "清理历史"
        }
    }
}

struct CleanerTabView: View {
    let model: CleanerModel
    @State private var subTab: CleanerSubTab = .junk

    private var accent: Color {
        Metric.disk.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let hint = model.permissionHint {
                fdaBanner(hint)
            }
            subPillBar
            switch subTab {
            case .junk: junkPlaceholder
            case .map: mapSection
            case .history: historyPlaceholder
            }
        }
    }

    // MARK: 页头

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("清理")
                    .font(.system(size: 26, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                Button("取消扫描") { model.cancelScan() }
            } else {
                Button(model.result == nil ? "扫描整台 Mac" : "重新扫描") { model.startScan() }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
    }

    private var headerSubtitle: String {
        switch model.phase {
        case .idle:
            return "按需扫描,不常驻 · 结果缓存到下次扫描"
        case let .scanning(stats):
            return "正在扫描 · \(stats.entriesSeen) 项 · \(PulseFormat.memory(UInt64(max(0, stats.accountedBytes))))"
        case let .finished(result):
            return "上次扫描 \(result.cancelled ? "已取消(部分)" : "完成") · \(scanDurationText) · 实际占用口径"
        }
    }

    private var scanDurationText: String {
        guard let started = model.scanStartedAt, let finished = model.scanFinishedAt else { return "—" }
        let seconds = finished.timeIntervalSince(started)
        return seconds < 60 ? String(format: "%.0f 秒", seconds) : String(format: "%.1f 分钟", seconds / 60)
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

    /// 空间地图子页(03 票 = 结果摘要;旭日图 07 票接入)。
    @ViewBuilder private var mapSection: some View {
        switch model.phase {
        case .idle:
            CardEmptyState(
                title: "还没扫描过",
                detail: "点右上「扫描整台 Mac」——约半分钟,随时可取消",
                actionTitle: "开始扫描",
                action: { model.startScan() }
            )
            .cardShell(compact: false)
        case let .scanning(stats):
            scanningCard(stats)
        case let .finished(result):
            summaryCard(result)
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
        let guess = 650_000.0 // 探针 15 的本机量级,仅定进度条斜率
        return min(0.95, Double(stats.entriesSeen) / guess)
    }

    private var elapsedText: String {
        guard let started = model.scanStartedAt else { return "0s" }
        return String(format: "%.0fs", Date().timeIntervalSince(started))
    }

    private func summaryCard(_ result: SpaceScanResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "sparkles", title: result.cancelled ? "扫描已取消(部分结果)" : "扫描完成", tint: accent) {
                Text(scanDurationText)
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

    private var junkPlaceholder: some View {
        CardEmptyState(
            title: "开发者垃圾清单在下一票接入",
            detail: "白名单识别 · 两档安全标签 · 确认后进废纸篓(p4-cleaner/04)"
        )
        .cardShell(compact: false)
    }

    private var historyPlaceholder: some View {
        CardEmptyState(
            title: "清理历史在删除管线落地后开放",
            detail: "每次清理的时间、释放量与逐项去向(p4-cleaner/04/08)"
        )
        .cardShell(compact: false)
    }
}
