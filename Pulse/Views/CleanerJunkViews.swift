import AppKit
import PulseCore
import SwiftUI

// MARK: - 开发者垃圾清单(p4-cleaner/04;形态 = 原型 B 变体,DESIGN.md 卡片家族)

//
// 本文件只做呈现与转发,状态全在 CleanerModel(PulseCore 纯值驱动):
//   清单卡(组分段 → 行 → 动作条)→ 确认 sheet(逐行 + 总量 + 口径注记)→ 结果卡
//   (失败如实报)→ 右键排除(持久化,再扫描 / 再列清单立即生效)。
// 行配方 = 清理页「舒适密度档」CleanerListMetrics(2026-11-05 用户拍板,三档原型
// 裁决 A:全页升密度;按钮与 segmented B 档;行左右内距加大)——不再借排行的
// RankingListMetrics(那是弹窗/排行多轮拍板的紧凑档)。档位 chip 用状态 chip 配方
// (胶囊、tint 14~16% 底 + 同色文字,DESIGN.md §状态 chip——此处映射的是
// GLOSSARY「安全档」两态,不是负载警示)。

/// 清理页「舒适密度档」尺寸表(DESIGN.md §清理页舒适密度档,2026-11-05 拍板):
/// 清理页四子页(垃圾/应用/历史)共用的行控件尺寸——图标 28 / 名称 14.5 /
/// 副文 12 / 数值 14.5 定宽列 / meter 130 / 行内距 12×10。排行的
/// `RankingListMetrics` 是紧凑档,弹窗与排行页保持不动,两套不混用。
enum CleanerListMetrics {
    /// 行内水平内距(组头/项目行/动作条与行对齐;拍板「左右 padding 增加一些」6→12)。
    static let rowInset: CGFloat = 12
    static let spacing: CGFloat = 10
    static let iconSize: CGFloat = 28
    static let titleFontSize: CGFloat = 14.5
    /// 副文/路径行字号。
    static let subFontSize: CGFloat = 12
    static let valueFontSize: CGFloat = 14.5
    static let meterWidth: CGFloat = 130
    static let rowVerticalPadding: CGFloat = 10
    static let chipFontSize: CGFloat = 11.5
    /// 项目产物缩进行 = 行内距 + 图标列(icon 28 + spacing 10)。
    static let indentLeading: CGFloat = 38

    /// 数值**定宽列**(排行同法:按最宽现实读数以实际绘制字体量宽 + 2;
    /// 清理读数上限 "999.9 GB")。同卡各行同一竖线,不许按内容撑宽。
    static let valueWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: valueFontSize, weight: .semibold)
        let widest = ["999.9 GB", "99.9 TB"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(widest) + 2
    }()

    /// 应用行的数值列(valueWidth + 「部分」附标留量;垃圾行不带附标用 valueWidth)。
    static let valueWidthWithMark: CGFloat = valueWidth + 30
}

/// 清单子页(换掉 03 票的占位卡):未扫描给 CTA,扫描中给提示,完成给清单卡。
struct JunkListSection: View {
    let model: CleanerModel
    /// 轻桥落点(p4-uninstaller/05):地图「这块能清」切过来时待定位的组;
    /// 透传给清单卡(JunkListCard):滚动到组头并短暂高亮,消费后自清。
    var pendingGroup: Binding<JunkGroup?> = .constant(nil)

    var body: some View {
        // flex:1 链路(section 层):壳层传下的 .infinity 在这接力,
        // 否则 switch 按内容自适应把信号吞了。
        bodyContent
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var bodyContent: some View {
        switch model.phase {
        case .idle:
            // 扫描前就给出扫描根指引(2026-11-02 用户实测找不到入口:配置只在
            // 设置窗「清理」页,主窗口这边扫之前看不到任何提示)。
            VStack(alignment: .leading, spacing: 4) {
                CardEmptyState(
                    title: model.isRestoringCache ? "正在恢复上次扫描结果…" : "先扫一遍,看看能回收多少",
                    detail: model.isRestoringCache
                        ? "从缓存读回上次结果(约一秒;机器满载时稍等)"
                        : "点右上「扫描整台 Mac」——白名单识别,未识别的目录不会出现",
                    actionTitle: model.isRestoringCache ? nil : "开始扫描",
                    action: model.isRestoringCache ? nil : { model.startScan() }
                )
                if !model.hasScanRoots {
                    Text("想清项目产物(node_modules 等)?先到 设置 → 清理 配置项目目录:工具栏齿轮打开设置,勾选建议目录或自添(如 ~/Documents/Learn/macos)。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .cardShell(compact: false)
        case .scanning:
            CardEmptyState(
                title: "正在扫描",
                detail: "扫描结束后这里出现可回收清单(进度在「空间地图」子页)"
            )
            .cardShell(compact: false)
        case .finished:
            JunkListCard(model: model, pendingGroup: pendingGroup)
        }
    }
}

// MARK: 清单卡

private struct JunkListCard: View {
    let model: CleanerModel
    /// 轻桥落点(p4-uninstaller/05):待定位组;滚动+高亮后自清(同组再跳也能再闪)。
    var pendingGroup: Binding<JunkGroup?> = .constant(nil)
    @State private var flashGroup: JunkGroup?
    /// 收起的项目产物子组(用户实报:产物没法收起;默认全展开,点项目行切换)。
    @State private var collapsedProjects: Set<String> = []

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
                Spacer(minLength: 0)
            } else {
                groups
                actionBar
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .cardShell(compact: false)
        .sheet(isPresented: confirmPresented) {
            CleanConfirmSheet(model: model, plan: model.plan)
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = model.cleanPhase {
                    true
                } else {
                    false
                }
            },
            set: { wanted in
                if !wanted {
                    model.cancelClean()
                }
            }
        )
    }

    private var header: some View {
        // 08 色彩纪律:卡头也中性(此前金色 sparkles 图标是「全页黄」的源头之一)。
        CardHeader(symbolName: "trash", title: "开发者垃圾", tint: .primary) {
            Text(summaryText)
                .font(.system(size: 11))
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
        // 08 增补(用户实报):列表自己滚(限高),合计/主按钮条钉在卡片底常驻——
        // 不再跟着内容滚到底才见;720 最小窗高下列表区约半屏,页面级滚动基本不触发。
        ScrollViewReader { proxy in
            ScrollView {
                groupsBody
            }
            // 弹性:列表吃卡内剩余空间(清理页不进外层滚动后卡片撑满窗口,
            // .infinity 即「到 actionBar 为止」);最小 160 防短窗挤没。
            .frame(minHeight: 160, maxHeight: .infinity)
            .onChange(of: pendingGroup.wrappedValue) { _, group in
                guard let group else { return }
                proxy.scrollTo(group, anchor: .top)
                flashGroup = group
                pendingGroup.wrappedValue = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if flashGroup == group {
                        flashGroup = nil
                    }
                }
            }
        }
    }

    /// 滚动体(拆分自 groups:单表达式过深触发 type-check 超时,2026-11-04 实锤)。
    private var groupsBody: some View {
        let byGroup = Dictionary(grouping: candidates, by: \.group)
        // 活动条目每次渲染现查一次(判定永不缓存),行级原因复用同一份。
        let activity = model.currentActivityEntries()
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(JunkGroup.allCases.filter { byGroup[$0] != nil }, id: \.self) { group in
                let items = (byGroup[group] ?? []).sortedForDisplay(by: sortMode(for: group))
                // 组选只吃组内「可安全清理」且**非在用**的项(拍板 B + 在用保护):
                // 先检查项、在用项都不参与组选,组里没有可勾项就不给按钮。
                let safeItems = items
                    .filter { $0.tier == .safe && model.inUseReasons(for: $0, entries: activity) == nil }
                groupHeader(group, items: items, safeItems: safeItems)
                    .id(group)
                    .background(
                        // 轻桥定位高亮(p4-uninstaller/05):跳转落地闪一下,1.5s 自灭。
                        flashGroup == group ? Metric.disk.accentColor.opacity(0.12) : Color.clear
                    )
                if group == .projectArtifacts {
                    // 08 重设计:按项目分子组(同 projectName 聚合),产物行缩进挂项目下。
                    ForEach(ProjectJunkGrouping.group(items)) { projectGroup in
                        let projectSafe = projectGroup.items
                            .filter { $0.tier == .safe && model.inUseReasons(for: $0, entries: activity) == nil }
                        let isCollapsed = collapsedProjects.contains(projectGroup.projectName)
                        projectHeader(projectGroup, safeItems: projectSafe, isCollapsed: isCollapsed)
                            .contentShape(.rect)
                            .onTapGesture {
                                if collapsedProjects.contains(projectGroup.projectName) {
                                    collapsedProjects.remove(projectGroup.projectName)
                                } else {
                                    collapsedProjects.insert(projectGroup.projectName)
                                }
                            }
                        if !isCollapsed {
                            ForEach(projectGroup.items) { candidate in
                                JunkRow(
                                    candidate: candidate,
                                    leader: candidates.map(\.bytes).max() ?? 0,
                                    accent: accent,
                                    isSelected: model.isSelected(candidate),
                                    inUseReasons: model.inUseReasons(for: candidate, entries: activity),
                                    disabled: isBusy,
                                    onToggle: { model.toggle(candidate) },
                                    onExclude: { model.exclude(candidate.path) },
                                    indented: true
                                )
                            }
                        }
                    }
                } else {
                    ForEach(items) { candidate in
                        JunkRow(
                            candidate: candidate,
                            leader: candidates.map(\.bytes).max() ?? 0,
                            accent: accent,
                            isSelected: model.isSelected(candidate),
                            inUseReasons: model.inUseReasons(for: candidate, entries: activity),
                            disabled: isBusy,
                            onToggle: { model.toggle(candidate) },
                            onExclude: { model.exclude(candidate.path) }
                        )
                    }
                }
            }
            if byGroup[.projectArtifacts] == nil {
                scanRootsHint
            }
        }
    }

    /// 项目产物组的空态(05):没配扫描根时给一条去设置的引导,不硬造空组。
    private var scanRootsHint: some View {
        Text(model.hasScanRoots
            ? "项目产物:配置的扫描根在本次扫描里没有找到产物目录。"
            : "项目产物:还没配置项目目录——设置 → 清理,勾选常见开发目录或自添(与归组的项目根互不影响)。")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 组排序(08:两组各自独立,互不影响)。
    private func sortMode(for group: JunkGroup) -> JunkSortOrder {
        group == .projectArtifacts ? model.artifactSort : model.toolCacheSort
    }

    /// 组头(08 重设计):组名中性加粗 + 总量 + 排序 seg + 「全选安全项」文字按钮
    /// (替代突兀的 NSButton 三态 checkbox;语义钉死 = 只勾安全且非在用项)。
    private func groupHeader(
        _ group: JunkGroup,
        items: [JunkCandidate],
        safeItems: [JunkCandidate]
    ) -> some View {
        let sum = items.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: 8) {
            Text(group.title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(.primary)
            Text(PulseFormat.memory(UInt64(max(0, sum))))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // 大小 ⇄ 新旧(05 拍板;08 扩到两组)。新旧 = 最久未动在前,未知排最后。
            // seg 走默认 regular(2026-11-05 密度拍板 B 档,不再 mini;不定宽——
            // 定宽曾把文字挤竖排,自然宽 + fixedSize 即可)。
            Picker(
                "排序",
                selection: Binding(
                    get: { sortMode(for: group) },
                    set: {
                        if group == .projectArtifacts {
                            model.artifactSort = $0
                        } else {
                            model.toolCacheSort = $0
                        }
                    }
                )
            ) {
                Text("大小").tag(JunkSortOrder.size)
                Text("新旧").tag(JunkSortOrder.age)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            Spacer()
            if !safeItems.isEmpty {
                Button("全选安全项") {
                    model.toggleGroup(safeItems)
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(isBusy)
                .help("只勾「可安全清理」且不在用的项;「先检查」与在用保护项永远要你亲手勾")
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 项目子组行(08):项目名 + 项数/总量/最近活动;子组勾选 = 该项目全部安全产物。
    private func projectHeader(
        _ projectGroup: ProjectJunkGroup,
        safeItems: [JunkCandidate],
        isCollapsed: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            Toggle("", isOn: .constant(!safeItems.isEmpty && safeItems.allSatisfy { model.isSelected($0) }))
                .toggleStyle(.checkbox)
                .controlSize(.large)
                .labelsHidden()
                .disabled(safeItems.isEmpty || isBusy)
                .onTapGesture { model.toggleGroup(safeItems) }
                .help("勾选本项目全部「可安全清理」且不在用的产物")
            // 项目行视觉权重 ≥ 产物行(用户实报两次:高度比产物行小 / 不要背景色)——
            // 权重只靠字号 14.5 bold + 上下距 10,无底色。
            Text(projectGroup.projectName)
                .font(.system(size: 14.5, weight: .bold))
                .lineLimit(1)
            Text(projectMeta(projectGroup))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 「2 项 · 3.2 GB · 3 天前动过」;活动时间未知如实省略,不编。
    private func projectMeta(_ projectGroup: ProjectJunkGroup) -> String {
        var text = "\(projectGroup.items.count) 项 · \(PulseFormat.memory(UInt64(max(0, projectGroup.totalBytes))))"
        if let epoch = projectGroup.newestChangeEpoch {
            let days = Int(Date(timeIntervalSince1970: epoch).timeIntervalSinceNow / 86400)
            text += days <= 0 ? " · 今天动过" : " · \(days) 天前动过"
        }
        return text
    }

    private var isBusy: Bool {
        if case .running = model.cleanPhase {
            return true
        }
        return false
    }

    @ViewBuilder private var actionBar: some View {
        let plan = model.plan
        switch model.cleanPhase {
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在移入废纸篓…(完成后才可退出 app)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        case .idle, .finished, .confirming:
            // CTA 常驻(用户实报:空选时按钮消失 = 不知道下一步干嘛):
            // 空选灰显 + 注脚;有选则清选 + 金色主按钮。按钮 B 档 .large(2026-11-05 密度拍板)。
            HStack(spacing: 12) {
                if plan.isEmpty {
                    Text("默认全不勾 · 勾选后可清理,右键行可排除")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("已选 \(plan.items.count) 项 · \(PulseFormat.memory(UInt64(max(0, plan.totalBytes))))")
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                }
                Spacer()
                if !plan.isEmpty {
                    Button("清除勾选") {
                        model.clearSelection()
                    }
                    .controlSize(.large)
                }
                Button(plan.isEmpty ? "移入废纸篓…" : "清理…") {
                    model.requestClean()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(accent)
                .disabled(plan.isEmpty)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
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
                        :
                        "已移入废纸篓 \(report.recycled.count) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes)))) · \(report.failed.count) 项失败")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Button("知道了") {
                        model.dismissCleanReport()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
                Text(historyRecorded ? "已记入清理历史" : "清理历史不可用,本次未记录(历史库未打开)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(historyRecorded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Surface.warning))
                ForEach(report.failed, id: \.path) { item in
                    if case let .failed(reason) = item.outcome {
                        Text("\(item.path) — \(reason)")
                            .font(.system(size: 11.5))
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
    /// 在用保护原因(nil = 不在用;05)。在用行灰显、锁代替勾选、chip 换「在用保护 · 原因」。
    let inUseReasons: CleanActivityReason?
    let disabled: Bool
    let onToggle: () -> Void
    let onExclude: () -> Void
    /// 项目产物行(08):挂在项目子组下,缩进 + 副标改 rationale 人话。
    var indented: Bool = false

    private var isInUse: Bool {
        inUseReasons != nil
    }

    var body: some View {
        HStack(spacing: CleanerListMetrics.spacing) {
            if isInUse {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .help("在用保护:该项目有进程活动,不参与本次清理")
            } else {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox)
                    .controlSize(.large)
                    .labelsHidden()
                    .disabled(disabled)
            }
            CategoryIconTile(
                symbolName: candidate.symbolName,
                // 08 色彩纪律:行图标中性灰(此前 safe=金 / checkFirst=金撞色难分)。
                color: Surface.inkTertiary,
                size: CleanerListMetrics.iconSize
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title)
                    .font(.system(size: CleanerListMetrics.titleFontSize, weight: .medium))
                    .lineLimit(1)
                Text(indented ? candidate.rationale : subtitle)
                    .font(.system(size: CleanerListMetrics.subFontSize))
                    .foregroundStyle(indented ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let reasons = inUseReasons {
                InUseChip(reasons: reasons)
            } else {
                TierChip(tier: candidate.tier)
            }
            MeterBar(
                fraction: MeterNormalization.fraction(Double(candidate.bytes), leader: Double(leader)),
                // 08 色彩纪律:大小条中性,金只留给页脚主按钮与选中 tab。
                tint: .secondary
            )
            .frame(width: CleanerListMetrics.meterWidth)
            Text(PulseFormat.memory(UInt64(max(0, candidate.bytes))))
                .font(.system(size: CleanerListMetrics.valueFontSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: CleanerListMetrics.valueWidth, alignment: .trailing)
        }
        .padding(
            .leading,
            indented ? CleanerListMetrics.rowInset + CleanerListMetrics.indentLeading : CleanerListMetrics.rowInset
        )
        .padding(.trailing, CleanerListMetrics.rowInset)
        .padding(.vertical, CleanerListMetrics.rowVerticalPadding)
        .opacity(isInUse ? 0.55 : 1)
        .background(
            isSelected ? Surface.cardHigh.opacity(0.7) : Color.clear,
            in: .rect(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !disabled, !isInUse {
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
        .help(isInUse ? "在用保护 · \(inUseReasons?.title ?? "")正在此项目——判定不缓存,删除前会重查" : candidate.rationale)
    }

    private var subtitle: String {
        var parts = [candidate.path]
        if candidate.isPartial {
            parts.append("部分扫描")
        }
        if candidate.projectName != nil {
            parts.append(ageText(now: Date().timeIntervalSince1970))
        }
        return parts.joined(separator: " · ")
    }

    /// 项目年龄的人话(05 口径:项目内非产物文件的最后变动,含 git 活动)。
    private func ageText(now: TimeInterval) -> String {
        guard let epoch = candidate.newestChangeEpoch else { return "年龄未知" }
        let days = Int((now - epoch) / 86400)
        switch days {
        case ..<1: return "今天动过"
        case ..<30: return "\(days) 天未动"
        case ..<365: return "\(days / 30) 个月未动"
        default: return "\(days / 365) 年未动"
        }
    }
}

/// 在用保护 chip(GLOSSARY「在用保护」):与 TierChip 同配方,三级墨色灰——
/// 不是「先检查」的警示琥珀(在用 = 客观状态,不是让用户小心的档位)。
struct InUseChip: View {
    let reasons: CleanActivityReason

    var body: some View {
        Text("在用保护 · \(reasons.title)正在此项目")
            .font(.system(size: CleanerListMetrics.chipFontSize, weight: .semibold))
            .foregroundStyle(Surface.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Surface.inkTertiary.opacity(0.15), in: .capsule)
            .lineLimit(1)
    }
}

/// 安全档 chip(GLOSSARY「安全档」两态):状态 chip 配方——胶囊、tint 14~16% 底 + 同色文字。
/// 可安全清理 → positive;先检查 → warning。这不是负载警示(那三处映射集中在
/// StatusBadgeRules),是删除安全语义,只在这里出。
struct TierChip: View {
    let tier: CleanSafetyTier

    private var tint: Color {
        // 08:「先检查」换 state-caution 琥珀(warning 是磁盘金别名,与页面 accent 撞色)。
        tier == .safe ? Surface.positive : Surface.caution
    }

    var body: some View {
        Text(tier.title)
            .font(.system(size: CleanerListMetrics.chipFontSize, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: .capsule)
    }
}

// MARK: 确认清单 sheet

// (08 票前的组头三态 checkbox 组件已随「全选安全项」文字按钮方案移除,注释一并清理。)

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
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
            HStack(spacing: 8) {
                Text("大小按实际占用计:APFS 克隆与硬链接不重复计。唯一不可逆的操作是「清空废纸篓」,不在这里。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
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
                Text(item.title)
                    .font(.system(size: CleanerListMetrics.titleFontSize, weight: .medium))
                    .lineLimit(1)
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
        // 主窗口行容器收编 LazyVStack(DESIGN.md 规则;历史随时间只增不减,懒加载最划算)。
        LazyVStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "clock.arrow.circlepath", title: "清理历史", tint: Metric.disk.accentColor) {
                Text("\(model.historyRuns?.count ?? 0) 次")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ForEach(model.historyRuns ?? []) { run in
                CleanRunDisclosureRow(model: model, run: run)
            }
            Text("清理历史永久保留在本地;大小按清理当时扫描的实际占用口径。")
                .font(.system(size: 11.5))
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    // 类型标记(Q15):卸载带应用图标、清理带垃圾桶,扫一眼可分;不做筛选分页。
                    Image(systemName: run.isUninstall ? "app.dashed" : "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .help(run.isUninstall ? "应用卸载" : "清理")
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13.5, weight: .medium))
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
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if expanded {
                items
            }
        }
        .padding(.horizontal, CleanerListMetrics.rowInset)
        .padding(.vertical, 8)
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
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(record.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(PulseFormat.memory(UInt64(max(0, record.bytes))))
                .font(.system(size: 13.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(outcomeText)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            // 找回(Q12):只在废纸篓去向存在时亮;永久删除无去向,不画。
            if case let .recycled(destination) = record.outcome {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destination)])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 13))
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
