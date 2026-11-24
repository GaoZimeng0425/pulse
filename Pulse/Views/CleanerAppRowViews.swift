import PulseCore
import SwiftUI

// 应用行 + 残留展开区(信任三件套/两 chip)——自 CleanerAppViews 拆出(solid-split,纯搬运)。

// MARK: - 行(点行选中 / 箭头展开)

struct AppRow: View {
    let entry: UninstallAppEntry
    /// 大小条的最大值(条形对照,与可清理行同款语言)。
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
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: CleanerListMetrics.valueWidthWithMark, alignment: .trailing)
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.inline, weight: .semibold))
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
        // 选中染底由外层小卡统一给(appCard,垃圾条目同配方),行本体无底。
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

struct LeftoverDisclosure: View {
    let model: UninstallModel
    let entry: UninstallAppEntry

    private var rows: [AppLeftoverRow]? {
        model.leftoverCache[entry.path]
    }

    var body: some View {
        // 卡内缩进裸行(与项目大卡子项同款):不再自套嵌套小卡,只随卡内距排布。
        VStack(alignment: .leading, spacing: 8) {
            leftoverContent
            actionRow
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var leftoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.bundleID == nil {
                // Q4:只剩应用名一把键,~/Library 里按名字撞目录误中风险高于收益。
                Text("未识别,不敢猜——这个应用读不到 bundle id,残留无法精确匹配,不列。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CleanerListMetrics.indentLeading)
                    .padding(.trailing, CleanerListMetrics.rowInset)
                    .padding(.bottom, 6)
            } else if model.leftoverLoading.contains(entry.path) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在查找残留…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CleanerListMetrics.indentLeading)
                .padding(.trailing, CleanerListMetrics.rowInset)
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
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CleanerListMetrics.indentLeading)
                    .padding(.trailing, CleanerListMetrics.rowInset)
                    .padding(.bottom, 6)
            }
        }
    }

    /// 动作排:彻底删除勾选(红字行内、每次展开重置)+ 卸载主按钮。
    /// 勾选框用统一自绘件,tint 取红——destructive 动作与普通勾选一眼分得开。
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Surface.negative)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.uninstallPhase == .running)
            .help("默认移入废纸篓,可从 Finder 恢复;勾选后直接永久删除(brew 应用走 --zap)")
            Spacer()
            Button(action: { model.requestUninstall(entry) }) {
                Text(model.isPermanentDeleteSelected(entry) ? "永久卸载 \(entry.name)…" : "卸载 \(entry.name)…")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isPermanentDeleteSelected(entry) ? Surface.negative : Surface.cleanAccent)
            .disabled(model.uninstallPhase == .running)
        }
        .padding(.leading, CleanerListMetrics.indentLeading)
        .padding(.trailing, CleanerListMetrics.rowInset)
        .padding(.vertical, 4)
    }

    private func header(_ rows: [AppLeftoverRow]) -> some View {
        let total = rows.compactMap(\.sizeBytes).reduce(Int64(0), +)
        return HStack {
            Text("残留 · \(rows.count) 项 · 共 \(PulseFormat.memory(UInt64(max(0, total)))) · 默认不勾")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Surface.cleanAccent)
            Spacer()
            Button("全选残留") {
                model.selectAllLeftovers(for: entry)
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .help("只勾通用位置残留;「先检查」项恒不进全选,可单独勾")
        }
        .padding(.leading, CleanerListMetrics.indentLeading)
        .padding(.trailing, CleanerListMetrics.rowInset)
    }

    private func footnote(_ rows: [AppLeftoverRow]) -> some View {
        Text(footnoteText(rows))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.leading, CleanerListMetrics.indentLeading)
            .padding(.trailing, CleanerListMetrics.rowInset)
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
struct LeftoverRowView: View {
    let row: AppLeftoverRow
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            CleanerCheckBox(state: isSelected ? .on : .off)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.site.plainTitle)
                        .font(.system(size: 14.5, weight: .medium))
                    Text("· \(row.site.consequenceNote)")
                        .font(.system(size: 12))
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
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: CleanerListMetrics.valueWidth, alignment: .trailing)
        }
        .padding(.leading, CleanerListMetrics.indentLeading)
        .padding(.trailing, CleanerListMetrics.rowInset)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { onToggle() }
    }
}

/// 灰行态 chip:客观状态非警示(InUseChip 同款配方——灰、不喊)。
struct StateChip: View {
    let text: String

    var body: some View {
        ChipView(text: text, tint: Surface.inkTertiary, profile: .regular)
    }
}

/// brew 徽标:来源事实(收据匹配),中性灰胶囊;解释性文案(Q11)。
struct BrewChip: View {
    let caskName: String

    var body: some View {
        ChipView(text: "brew", tint: Surface.inkTertiary, profile: .regular, help: "由 Homebrew 安装(卸载时将由它执行,票 03)")
    }
}
