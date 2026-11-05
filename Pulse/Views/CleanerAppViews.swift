import PulseCore
import SwiftUI

// MARK: - 应用子页(p4-uninstaller/01 清单 + 02 残留信任 / 排序搜索 / 选中交互)

//
// 交互口径(2026-11-04 原型裁决,存档 prototype/uninstaller-ui):
// 点行任意处 = 选中 app 本体(checkbox 语义、行高亮、再点取消;灰行点不选中);
// 点行尾箭头 = 展开残留清单(人话副标 + 「删了会怎样」,默认不勾,「全选残留」
// 不收「先检查」项);选中态与展开态相互独立。
// 「彻底删除」勾选与「卸载」按钮随票 03 一起上——不上没有执行后果的半截交互。
// 无 bundle id 的 app:不探测残留,展开只给「未识别,不敢猜」标注(Q4)。

struct AppListSection: View {
    let model: UninstallModel
    @State private var expanded: Set<String> = []

    private var accent: Color {
        Metric.disk.accentColor
    }

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            header
            switch model.phase {
            case .idle, .collecting:
                loadingView(text: "正在收集应用清单…")
            case let .sizing(entries):
                loadingView(text: "正在统计占用 · 已扫描 \(entries) 项")
            case .finished:
                content
            }
        }
        // 进子页空态才自动扫(已有清单不重复烧);切走取消(无常驻采集,spec)。
        .task { model.loadIfNeeded() }
        .onDisappear { model.cancel() }
    }

    // MARK: 头部

    private var header: some View {
        CardHeader(symbolName: "square.grid.2x2", title: "应用", tint: accent) {
            HStack(spacing: 8) {
                if let output = model.output {
                    Text(summaryText(output))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("重新收集(签名、brew 徽标、运行态都可能已变化)")
            }
        }
    }

    private func summaryText(_ output: AppCatalogOutput) -> String {
        var text = "共 \(output.entries.count) 个应用"
        if output.ledger.excludedAppleSigned > 0 {
            text += " · 已隐藏 \(output.ledger.excludedAppleSigned) 个 Apple 系统应用"
        }
        if output.ledger.excludedUnverifiableSignature > 0 {
            text += " · \(output.ledger.excludedUnverifiableSignature) 个签名无法验证未列出"
        }
        return text
    }

    // MARK: 清单

    private var content: some View {
        let entries = model.displayedEntries
        return Group {
            if entries.isEmpty {
                emptyView
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    uninstallBanner
                    if model.uninstallPhase == .running {
                        runningBanner
                    }
                    controlsBar
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                AppRow(
                                    entry: entry,
                                    leader: entries.compactMap(\.sizeBytes).max() ?? 0,
                                    isSelected: model.isSelected(entry),
                                    isExpanded: expanded.contains(entry.path),
                                    onToggleSelect: { model.toggleSelect(entry) },
                                    onToggleExpand: { toggleExpand(entry) }
                                )
                                if expanded.contains(entry.path) {
                                    LeftoverDisclosure(model: model, entry: entry)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(minHeight: 120, maxHeight: .infinity)
                }
                .padding(12)
                .background(Surface.card, in: .rect(cornerRadius: 18))
            }
        }
        .sheet(isPresented: uninstallSheetPresented) {
            if case let .confirming(plan) = model.uninstallPhase {
                AppUninstallConfirmSheet(plan: plan) {
                    model.confirmUninstall()
                } onCancel: {
                    model.cancelUninstall()
                }
            }
        }
        .alert("这个应用由 Homebrew 安装", isPresented: rerouteAlertPresented) {
            Button("取消", role: .cancel) { model.cancelUninstall() }
            Button("仍要直接删文件(绕过 Homebrew)", role: .destructive) { model.proceedAfterReroute() }
        } message: {
            if case let .reroute(_, cask) = model.uninstallPhase {
                Text("建议让 Homebrew 卸载(\(cask))以保持安装记录一致——取消后此应用会带 brew 徽标,用 brew 卸载即可。")
            }
        }
    }

    private var uninstallSheetPresented: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = model.uninstallPhase {
                    true
                } else {
                    false
                }
            },
            set: { presented in
                if !presented {
                    model.cancelUninstall()
                }
            }
        )
    }

    private var rerouteAlertPresented: Binding<Bool> {
        Binding(
            get: {
                if case .reroute = model.uninstallPhase {
                    true
                } else {
                    false
                }
            },
            set: { presented in
                if !presented {
                    model.cancelUninstall()
                }
            }
        )
    }

    /// 完成横幅(Q10:页内,不发系统通知)/ 中止红字;关闭回空态。
    @ViewBuilder
    private var uninstallBanner: some View {
        switch model.uninstallPhase {
        case let .finished(report):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Surface.positive)
                Text(finishedText(report))
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button {
                    model.dismissUninstallBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(10)
            .background(Surface.positive.opacity(0.1), in: .rect(cornerRadius: 10))
        case let .aborted(reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Surface.negative)
                Text(reason)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(3)
                Spacer()
                Button {
                    model.dismissUninstallBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(10)
            .background(Surface.negative.opacity(0.1), in: .rect(cornerRadius: 10))
        default:
            EmptyView()
        }
    }

    private func finishedText(_ report: CleanRunReport) -> String {
        var text = "已处理 \(report.items.filter(\.isReleased).count) 项"
        if report.recycled.count > 0 {
            text += "(移入废纸篓 \(report.recycled.count)"
        }
        if report.permanentItems.count > 0 {
            text += report.recycled.count > 0 ? " · 永久删除 \(report.permanentItems.count)" : "(永久删除 \(report.permanentItems.count)"
        }
        if report.recycled.count > 0 || report.permanentItems.count > 0 {
            text += " · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes))))"
        }
        if report.failed.count > 0 {
            text += ",失败 \(report.failed.count) 项"
        }
        return text + ")"
    }

    private var runningBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在卸载…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 10))
    }

    /// 搜索 + 排序 + 操作提示(Q5:默认占用降序,可切按名;子页内过滤)。
    /// 舒适密度档(2026-11-05):搜索框/提示与行同档放大;seg 保持默认 regular(=B 档)。
    private var controlsBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("搜索应用", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 220, height: 30, alignment: .leading)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 8))

            Picker("排序", selection: $model.sortOrder) {
                Text("占用 ↓").tag(AppSortOrder.sizeDescending)
                Text("按名").tag(AppSortOrder.name)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("默认按 .app 实际占用降序(与空间地图同口径)")

            Spacer(minLength: 8)
            Text("点行选中 · 箭头看残留")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func toggleExpand(_ entry: UninstallAppEntry) {
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            model.onExpand(entry) // 彻底删除勾选重置 + 残留按需探测
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(model.searchQuery.isEmpty ? "未发现可卸载的应用" : "没有匹配的应用")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func loadingView(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(Surface.card, in: .rect(cornerRadius: 18))
    }
}

// MARK: - 行(点行选中 / 箭头展开)

private struct AppRow: View {
    let entry: UninstallAppEntry
    /// 大小条的最大值(条形对照,与开发者垃圾行同款语言)。
    let leader: Int64
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void

    private var isDimmed: Bool {
        entry.rowState != .normal
    }

    var body: some View {
        HStack(spacing: CleanerListMetrics.spacing) {
            // 灰行不给出可勾的假象:勾选框画在那但压暗(陈述「先退出/无权限」)。
            // 2026-11-05 换统一自绘 CleanerCheckBox(此前 SF 方块与垃圾页系统框两套)。
            CleanerCheckBox(state: isSelected ? .on : .off, disabled: isDimmed)
            Image(nsImage: AppIconCache.icon(forBundle: entry.path, pointSize: CleanerListMetrics.iconSize))
                .resizable()
                .frame(width: CleanerListMetrics.iconSize, height: CleanerListMetrics.iconSize)
                .opacity(isDimmed ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: CleanerListMetrics.titleFontSize, weight: .medium))
                    .lineLimit(1)
                Text(entry.path)
                    .font(.system(size: CleanerListMetrics.subFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .opacity(isDimmed ? 0.55 : 1)
            Spacer(minLength: 8)
            if let cask = entry.brewCaskName {
                BrewChip(caskName: cask)
            }
            stateChip
            MeterBar(
                fraction: meterFraction,
                tint: .secondary
            )
            .frame(width: CleanerListMetrics.meterWidth)
            HStack(spacing: 4) {
                Text(sizeText)
                    .font(.system(size: CleanerListMetrics.valueFontSize, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if entry.isPartial {
                    Text("部分")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: CleanerListMetrics.valueWidthWithMark, alignment: .trailing)
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(entry.bundleID == nil ? "该应用读不到 bundle id,残留无法精确匹配" : "展开残留清单")
        }
        .padding(.horizontal, CleanerListMetrics.rowInset)
        .padding(.vertical, CleanerListMetrics.rowVerticalPadding)
        .background(
            // 选中高亮(原型裁决):点行选中后行底染磁盘色族浅底。
            isSelected ? Metric.disk.accentColor.opacity(0.1) : Color.clear
        )
        .opacity(isDimmed ? 0.75 : 1)
        .contentShape(.rect)
        .onTapGesture {
            // 点行 = 选中(原型裁决);箭头是 Button 自己消费点击,不会落到这。
            onToggleSelect()
        }
    }

    @ViewBuilder
    private var stateChip: some View {
        switch entry.rowState {
        case .normal:
            EmptyView()
        case .running:
            StateChip(text: "先退出")
        case .noPermission:
            StateChip(text: "无权限")
        }
    }

    private var sizeText: String {
        entry.sizeBytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—"
    }

    private var meterFraction: Double {
        guard let bytes = entry.sizeBytes, leader > 0 else { return 0 }
        return MeterNormalization.fraction(Double(bytes), leader: Double(leader))
    }
}

// MARK: - 残留展开区(Q4 信任三件套)

private struct LeftoverDisclosure: View {
    let model: UninstallModel
    let entry: UninstallAppEntry

    private var rows: [AppLeftoverRow]? {
        model.leftoverCache[entry.path]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            leftoverContent
            actionRow
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        .background(Surface.cardHigh.opacity(0.6), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var leftoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.bundleID == nil {
                // Q4:只剩应用名一把键,~/Library 里按名字撞目录误中风险高于收益。
                Text("未识别,不敢猜——这个应用读不到 bundle id,残留无法精确匹配,不列。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
                    .padding(.bottom, 6)
            } else if model.leftoverLoading.contains(entry.path) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在查找残留…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
                .padding(.bottom, 6)
            } else if let rows, !rows.isEmpty {
                header(rows)
                ForEach(rows) { row in
                    LeftoverRowView(
                        row: row,
                        isSelected: model.isLeftoverSelected(row),
                        onToggle: { model.toggleLeftover(row) }
                    )
                }
                footnote(rows)
            } else if rows != nil {
                Text("没有找到残留")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
                    .padding(.bottom, 6)
            }
        }
    }

    /// 动作排(03):彻底删除勾选(Q6,红字行内、每次展开重置)+ 卸载主按钮。
    /// 勾选框 = 统一自绘件、destructive 红 tint(2026-11-05)。
    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                model.togglePermanentDelete(entry)
            } label: {
                HStack(spacing: 8) {
                    CleanerCheckBox(
                        state: model.isPermanentDeleteSelected(entry) ? .on : .off,
                        tint: Surface.negative
                    )
                    Text("彻底删除:不进废纸篓,不可恢复")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Surface.negative)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.uninstallPhase == .running)
            .help("默认移入废纸篓,可从 Finder 恢复;勾选后直接永久删除(brew 应用走 --zap)")
            Spacer()
            Button(action: { model.requestUninstall(entry) }) {
                Text(model.isPermanentDeleteSelected(entry) ? "永久卸载 \(entry.name)…" : "卸载 \(entry.name)…")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isPermanentDeleteSelected(entry) ? Surface.negative : Metric.disk.accentColor)
            .disabled(model.uninstallPhase == .running)
        }
        .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
        .padding(.vertical, 4)
    }

    private func header(_ rows: [AppLeftoverRow]) -> some View {
        let total = rows.compactMap(\.sizeBytes).reduce(Int64(0), +)
        return HStack {
            Text("残留 · \(rows.count) 项 · 共 \(PulseFormat.memory(UInt64(max(0, total)))) · 默认不勾")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Metric.disk.accentColor)
            Spacer()
            Button("全选残留") {
                model.selectAllLeftovers(for: entry)
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .help("只勾通用位置残留;「先检查」项恒不进全选,可单独勾")
        }
        .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
    }

    private func footnote(_ rows: [AppLeftoverRow]) -> some View {
        Text(footnoteText(rows))
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
            .padding(.bottom, 2)
    }

    /// 收据来源的行注明「收据声明」;全为通用位置时不占位。
    private func footnoteText(_ rows: [AppLeftoverRow]) -> String {
        let zapCount = rows.filter { $0.source == .caskZap }.count
        var text = "残留按 bundle id 与应用名精确匹配,只列真实存在的条目"
        if zapCount > 0 {
            text += ";\(zapCount) 项来自 Homebrew 安装收据的声明"
        }
        return text
    }
}

/// 残留行:人话副标(Q4)先于路径,「删了会怎样」跟在副标后;点行即勾选。
private struct LeftoverRowView: View {
    let row: AppLeftoverRow
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            CleanerCheckBox(state: isSelected ? .on : .off)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.site.plainTitle)
                        .font(.system(size: 13.5, weight: .medium))
                    Text("· \(row.site.consequenceNote)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                    if row.isCheckFirst {
                        StateChip(text: "先检查")
                    }
                }
                .lineLimit(1)
                Text(row.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(row.sizeBytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—")
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { onToggle() }
    }
}

/// 灰行态 chip:客观状态非警示(InUseChip 同款配方——灰、不喊)。
private struct StateChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: CleanerListMetrics.chipFontSize, weight: .semibold))
            .foregroundStyle(Surface.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Surface.inkTertiary.opacity(0.15), in: .capsule)
            .lineLimit(1)
    }
}

/// brew 徽标:来源事实(收据匹配),中性灰胶囊;解释性文案(Q11)。
private struct BrewChip: View {
    let caskName: String

    var body: some View {
        Text("brew")
            .font(.system(size: CleanerListMetrics.chipFontSize, weight: .semibold))
            .foregroundStyle(Surface.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Surface.inkTertiary.opacity(0.15), in: .capsule)
            .help("由 Homebrew 安装(卸载时将由它执行,票 03)")
    }
}

// MARK: - 卸载确认弹窗(03;一期 CleanConfirmSheet 同配方,卸载域文案)

/// 确认清单(ADR-0008 闸门在卸载域的投影):逐行 = 路径 + 大小 + 去向标;
/// 彻底删除时逐行红标「永久删除」+ 页脚明示不可恢复(Q6);brew 应用注明
/// 本体由 Homebrew 卸载(永久),勾选残留按模式走。
private struct AppUninstallConfirmSheet: View {
    let plan: AppUninstallPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var accent: Color {
        Metric.disk.accentColor
    }

    private struct Row: Identifiable {
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
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(plan.permanent ? Surface.negative : .primary)
            HStack(spacing: 8) {
                Text(footnote)
                    .font(.system(size: 11.5))
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
        if plan.isBrew {
            return "Homebrew 卸载失败时本次零删除,不会绕过它直接删文件。"
        }
        return "大小按实际占用计;失败项会如实报告并跳过。"
    }

    private func confirmRow(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.viaBrew ? "brew" : "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(row.viaBrew ? Surface.inkTertiary : accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13.5, weight: .medium))
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Surface.negative)
            } else {
                Text("废纸篓")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Text(row.bytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—")
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}
