import AppKit
import PulseCore
import SwiftUI

// 清单卡(JunkListCard):卡头(「全部清单」+ 合计;下钻态不画)→ 结果卡(清理完成后
// 的报告,平时不占位)→ 组列表(自己滚:组头 + 条目)→ 动作条(钉在卡底常驻)。
// 确认单 CleanConfirmSheet 挂在这张卡上。行、档位 chip、年龄文案在
// CleanerJunkRowViews.swift;尺寸表与勾选框在 CleanerListCommonViews.swift。

// MARK: 清单卡

struct JunkListCard: View {
    let model: CleanerModel
    /// 轻桥落点(p4-uninstaller/05):待定位组;滚动+高亮后自清(同组再跳也能再闪)。
    var pendingGroup: Binding<JunkGroup?> = .constant(nil)
    /// 总览下钻品类(p6-cleaner/03):非 nil = 只显示该品类 + 「‹ 总览」返回行。
    var groupFilter: Binding<JunkGroup?> = .constant(nil)
    /// 返回行回调(下钻态才有)。
    var onBackToOverview: (() -> Void)?
    @State private var flashGroup: JunkGroup?
    /// 收起的项目大卡;不在表里 = 展开,所以默认全展开。
    @State private var collapsedProjects: Set<String> = []

    /// 清理页专属强调色,不借指标色(单出处 `Surface.cleanAccent`)。
    private var accent: Color {
        Surface.cleanAccent
    }

    private var candidates: [JunkCandidate] {
        model.candidates
    }

    /// 展示用的清单:下钻态只留该品类(过滤纯值单出处,顺序不重排);全量态 = 原清单。
    private var displayedCandidates: [JunkCandidate] {
        JunkOverviewAggregator.filtered(candidates, by: groupFilter.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if groupFilter.wrappedValue == nil {
                header
            }
            reportCard
            if displayedCandidates.isEmpty {
                if let filter = groupFilter.wrappedValue {
                    drillBackRow(group: filter, items: [], safeItems: [])
                    // 下钻空态与全量空态同族,同走卡片家族零件。
                    CardEmptyState(
                        title: "该品类当前没有条目",
                        detail: "可能已排除、已移入废纸篓,或重新扫描后不再命中"
                    )
                    Spacer(minLength: 0)
                } else {
                    CardEmptyState(
                        title: CleanerEmptyStateCopy.nothingFoundTitle,
                        detail: CleanerEmptyStateCopy.nothingFoundDetail(
                            hiddenRunningAppEntries: model.hiddenRunningAppEntryCount
                        )
                    )
                    Spacer(minLength: 0)
                }
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
        // 卡头标题即子页名;卡头取清理页强调色,与其它子页卡头一致。
        CardHeader(symbolName: "trash", title: "全部清单", tint: Surface.cleanAccent) {
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
            // 2026-11-08 实报:清单短于视口时 ScrollView 默认把内容悬中——锚顶。
            .defaultScrollAnchor(.top)
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
        let filter = groupFilter.wrappedValue
        let byGroup = Dictionary(grouping: displayedCandidates, by: \.group)
        // 活动条目每次渲染现查一次(判定永不缓存),行级原因复用同一份。
        let activity = model.currentActivityEntries()
        // 条目区两种形态并存:工具缓存这类组 = 每个条目一张独立小卡;按所有者聚合的组
        // (项目产物 / 卸载残留)= 项目大卡装卡内裸行子项(见 groupRows)。
        return LazyVStack(alignment: .leading, spacing: 18) {
            if let filter {
                // 下钻态:「‹ 总览」返回行顶替组头(标题 / 合计 / 全选安全项并入返回行,
                // 不再另画组头)+ 该品类条目;排序沿用该组既有偏好。
                let items = (byGroup[filter] ?? []).sortedForDisplay(by: sortMode(for: filter))
                // 组选资格单出处(CleanInUse.isSafeAutoSelectable):先检查、在用项不参与。
                let safeItems = items.filter { CleanInUse.isSafeAutoSelectable($0, entries: activity) }
                VStack(alignment: .leading, spacing: 4) {
                    drillBackRow(group: filter, items: items, safeItems: safeItems)
                    groupRows(for: filter, items: items, activity: activity)
                }
            } else {
                ForEach(JunkGroup.allCases.filter { byGroup[$0] != nil }, id: \.self) { group in
                    let items = (byGroup[group] ?? []).sortedForDisplay(by: sortMode(for: group))
                    // 组选口径同下钻分支:只吃 safe 非在用,组里没有可勾项就不出按钮。
                    let safeItems = items.filter { CleanInUse.isSafeAutoSelectable($0, entries: activity) }
                    VStack(alignment: .leading, spacing: 4) {
                        groupHeader(group, items: items, safeItems: safeItems)
                            .id(group)
                            .background(
                                // 轻桥定位高亮(p4-uninstaller/05):跳转落地闪一下,1.5s 自灭。
                                flashGroup == group ? accent.opacity(0.12) : Color.clear
                            )
                        groupRows(for: group, items: items, activity: activity)
                    }
                }
                if byGroup[.projectArtifacts] == nil {
                    scanRootsHint
                }
                if let reason = model.orphanDetectionUnavailableReason {
                    orphanUnavailableHint(reason)
                }
            }
        }
    }

    /// 一组的条目区(全量组段与下钻单组共用,行形态零新):按所有者聚合的组走项目大卡,
    /// 其余走独立小卡行。meter 归一口径恒为**全量**榜首(下钻视图里条的长短与全量视图一致)。
    @ViewBuilder private func groupRows(
        for group: JunkGroup,
        items: [JunkCandidate],
        activity: [CleanActivityEntry]
    ) -> some View {
        if group.groupsByOwner {
            // 按所有者分子组(同 projectName 聚合;项目产物 = 项目,卸载残留 =
            // app 全 bundle id):两种组共用同一张大卡形态,见 projectCard。
            ForEach(ProjectJunkGrouping.group(items)) { projectGroup in
                // 勾选的两层口径、置灰与换锁的判据都在 projectCard;这里只算两个子集:
                // nonInUse = 状态反映哪些子项,autoSelectable = 点击能勾哪些子项。
                let nonInUse = projectGroup.items
                    .filter { model.inUseReasons(for: $0, entries: activity) == nil }
                let autoSelectable = projectGroup.items
                    .filter { CleanInUse.isSafeAutoSelectable($0, entries: activity) }
                let allInUse = !projectGroup.items.isEmpty && nonInUse.isEmpty
                // 收起态按「组/键」记:项目名与 bundle id 同名也不串。
                let cardKey = group.rawValue + "/" + projectGroup.projectName
                let isCollapsed = collapsedProjects.contains(cardKey)
                projectCard(
                    projectGroup,
                    group: group,
                    stateItems: nonInUse,
                    autoSelectable: autoSelectable,
                    allInUse: allInUse,
                    isCollapsed: isCollapsed,
                    onToggleCollapse: {
                        if collapsedProjects.contains(cardKey) {
                            collapsedProjects.remove(cardKey)
                        } else {
                            collapsedProjects.insert(cardKey)
                        }
                    }
                ) {
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

    /// 下钻返回行:「‹ 总览」+ 品类标题 + 「X · N 项」合计 + 「全选安全项」(与组头同口径:
    /// 只吃 safe 非在用)。排序 seg 不进返回行——回全量视图再调,排序偏好两边共用。
    private func drillBackRow(
        group: JunkGroup,
        items: [JunkCandidate],
        safeItems: [JunkCandidate]
    ) -> some View {
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: 10) {
            Button {
                onBackToOverview?()
            } label: {
                Text("‹ 总览")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.borderless)
            .help("回到总览(勾选保持,清单过滤解除)")
            Text(group.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
            Text("\(PulseFormat.memory(UInt64(max(0, total)))) · \(items.count) 项")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 12)
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
        .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 项目产物组的空态(05):没配扫描根时给一条去设置的引导,不硬造空组。
    private var scanRootsHint: some View {
        Text(model.hasScanRoots
            ? "项目产物:配置的扫描根在本次扫描里没有找到产物目录。"
            : "项目产物:还没配置项目目录——设置 → 清理,勾选常见开发目录或自添(与归组的项目根互不影响)。")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 卸载残留没检测时的如实说明(p5-cleaner/02:「没查」≠「查了没有」——后者按空态
    /// 规则整组不出,前者必须说,否则用户以为这台机器没有卸载残留)。
    private func orphanUnavailableHint(_ reason: String) -> some View {
        Text("卸载残留未检测:\(reason)")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 组排序(08 起各组独立;读写走模型的穷举 switch,新组必须表态)。
    private func sortMode(for group: JunkGroup) -> JunkSortOrder {
        model.sortOrder(for: group)
    }

    /// 组头:组名 + 总量在左;右侧 = 「全选安全项」+ 大小|新旧 seg(seg 挪到右、tint 取
    /// 清理页强调色,与主按钮统一)。「全选安全项」就是本组的整组勾选,口径只吃 safe
    /// 非在用;组里没有可勾项时不出。
    private func groupHeader(
        _ group: JunkGroup,
        items: [JunkCandidate],
        safeItems: [JunkCandidate]
    ) -> some View {
        let sum = items.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: 8) {
            Text(group.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
            Text(PulseFormat.memory(UInt64(max(0, sum))))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 12)
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
            // 大小 ⇄ 新旧:新旧 = 最久未动在前、年龄未知排最后(口径在 JunkSortOrder)。
            // 自然宽(fixedSize)——定宽会把文字挤成竖排。
            Picker(
                "排序",
                selection: Binding(
                    get: { sortMode(for: group) },
                    set: { model.setSortOrder($0, for: group) }
                )
            ) {
                Text("大小").tag(JunkSortOrder.size)
                Text("新旧").tag(JunkSortOrder.age)
            }
            .pickerStyle(.segmented)
            .tint(accent)
            .fixedSize()
            .labelsHidden()
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.horizontal, CleanerListMetrics.rowInset)
    }

    /// 项目大卡:头排 + 全部子项装在一张抬升底大卡里。子项是卡内裸行(JunkRow indented),
    /// 只缩进不套小卡——与工具缓存组的独立小卡是并存的两种条目形态。项目产物与卸载
    /// 残留共用本卡,名词随组换。点头排 = 展开 / 收起。
    /// 勾选两层口径:**状态**反映全部非在用子项(手勾的「先检查」也算,父级如实半选 /
    /// 全选);**动作**只全选 / 全清安全档子项。于是:子项全在用 = 勾选位换锁;其余情况
    /// 下没有安全档可勾(只剩先检查)= 勾选框置灰,不给假按钮。
    private func projectCard(
        _ projectGroup: ProjectJunkGroup,
        group: JunkGroup,
        stateItems: [JunkCandidate],
        autoSelectable: [JunkCandidate],
        allInUse: Bool,
        isCollapsed: Bool,
        onToggleCollapse: @escaping () -> Void,
        @ViewBuilder children: () -> some View
    ) -> some View {
        let selectedCount = stateItems.filter { model.isSelected($0) }.count
        let checkState: CleanerCheckBox.CheckState = stateItems.isEmpty || selectedCount == 0
            ? .off
            : (selectedCount == stateItems.count ? .on : .mixed)
        // 文案名词随组(项目产物 = 项目 / 产物;卸载残留 = 应用 / 残留)。
        let owner = group == .uninstallLeftovers ? "应用" : "项目"
        let item = group == .uninstallLeftovers ? "残留" : "产物"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if allInUse {
                    Image(systemName: "lock.fill")
                        .font(.system(size: IconSize.inline))
                        .foregroundStyle(.tertiary)
                        .help("在用保护:该\(owner)此刻有进程活动(终端/构建等),不参与本次清理")
                } else {
                    Button {
                        guard !isBusy, !autoSelectable.isEmpty else { return }
                        model.toggleGroup(autoSelectable)
                    } label: {
                        CleanerCheckBox(state: checkState, disabled: isBusy || autoSelectable.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || autoSelectable.isEmpty)
                    .help(autoSelectable.isEmpty
                        ? "本\(owner)没有「可安全清理」\(item)——「先检查」项不进自动勾选,逐个手勾(手动勾选后这里会如实显示)"
                        : "全选/全清本\(owner)「可安全清理」\(item);「先检查」项不进自动勾选,须逐个手勾(手勾后父级如实显示)")
                }
                // 收展点击区 = 标题/元信息/箭头这一块(cleaner-junk-card-fixes/01:
                // 整行手势会劫持框上的点击——点框变成收展,勾选框必须独立响应)。
                HStack(spacing: 8) {
                    // 卸载残留:显示名 = bundle id 尾段(spec §11),全 id 进 meta 区分同尾段的 app。
                    // 项目产物:显示名 = 父目录完整路径的末段,全路径进 meta 区分同名目录
                    // (cleaner-junk-card-fixes/02)。
                    Text(group == .uninstallLeftovers
                        ? OrphanLeftoverDetector.displayName(ofBundleID: projectGroup.projectName)
                        : (projectGroup.projectName as NSString).lastPathComponent)
                        .font(.system(size: 14.5, weight: .bold))
                        .lineLimit(1)
                    Text(projectMeta(projectGroup))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.inline, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: onToggleCollapse)
                .help(isCollapsed ? "点击展开\(item)清单" : "点击收起\(item)清单")
            }
            .padding(.leading, CleanerListMetrics.rowInset)
            .padding(.trailing, CleanerListMetrics.rowInset)
            .padding(.top, CleanerListMetrics.rowVerticalPadding)
            .padding(.bottom, isCollapsed ? CleanerListMetrics.rowVerticalPadding : 4)
            if !isCollapsed {
                children()
                    .padding(.bottom, 6)
            }
        }
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
    }

    /// 「/…/apps/desktop · 2 项 · 3.2 GB · 3 天前动过」。首段 = 大卡分组键全量
    /// (卸载残留 = 完整 bundle id;项目产物 = 父目录完整路径,区分同名目录,
    /// cleaner-junk-card-fixes/02);活动时间未知如实省略,不编。
    private func projectMeta(_ projectGroup: ProjectJunkGroup) -> String {
        var parts: [String] = [projectGroup.projectName]
        parts.append("\(projectGroup.items.count) 项")
        parts.append(PulseFormat.memory(UInt64(max(0, projectGroup.totalBytes))))
        if let epoch = projectGroup.newestChangeEpoch {
            parts.append(JunkAgeText.ago(sinceEpoch: epoch, now: Date().timeIntervalSince1970))
        }
        return parts.joined(separator: " · ")
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        case .idle, .finished, .confirming, .notStarted:
            // 动作条常驻:空选时主按钮灰显 + 注脚,不整条消失——按钮消失时看不出
            // 下一步该干嘛;有选则出「清除勾选」+ 强调色主按钮。
            HStack(spacing: 12) {
                if plan.isEmpty {
                    Text("默认全不勾 · 勾选后可清理,右键行可排除")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("已选 \(plan.items.count) 项 · \(PulseFormat.memory(UInt64(max(0, plan.totalBytes))))")
                        .font(.system(size: 14.5, weight: .bold))
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
                        .font(.system(size: IconSize.inline, weight: .medium))
                        .foregroundStyle(Surface.positive)
                    Text(report.failed.isEmpty
                        ? "已移入废纸篓 \(report.recycled.count) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes))))"
                        :
                        "已移入废纸篓 \(report.recycled.count) 项 · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes)))) · \(report.failed.count) 项失败")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Button("知道了") {
                        model.dismissCleanReport()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
                Text(historyRecorded ? "已记入清理历史" : "清理历史不可用,本次未记录(历史库未打开)")
                    .font(.system(size: 11))
                    .foregroundStyle(historyRecorded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Surface.warning))
                ForEach(report.failed, id: \.path) { item in
                    if case let .failed(reason) = item.outcome {
                        Text("\(item.path) — \(reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(Surface.negative)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        } else if case let .notStarted(abort) = model.cleanPhase {
            // 没开始就停了(管理员授权被取消 / 通道不可用):客观陈述,不催促;勾选还在,
            // 动作条照常可以重新发起。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: IconSize.inline, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(abort.title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("知道了") {
                        model.dismissCleanReport()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
                Text(abort.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        }
    }
}
