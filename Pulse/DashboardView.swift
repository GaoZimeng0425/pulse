import SwiftUI
import AppKit

/// 弹窗主页(工单 P0.6-03 tab 化):标题排 + 图标 tab(总览 / CPU / 内存)+
/// 各 tab 内容 + 底部操作排。tab 内容模型在 MetricTabContent(纯逻辑,单测覆盖),
/// 这里只做粘合:总览 = 系统负载卡(带 strip,已有)+ 瘦身组卡列表;CPU = 面积图
/// 主卡(全尺寸走势图的归位处)+ 组排行;内存 = Memory by App 环形卡 + 内存组排行。
/// 组卡下钻(工单 06)与处置编排(工单 08)不变;排序随每轮采样实时刷新。
struct DashboardView: View {
    let monitor: SystemMonitor
    /// 设置窗入口(工单 07):头部齿轮按钮。
    @Environment(\.openSettings) private var openSettings
    /// 主窗口入口:底部"打开主窗口"按钮。
    @Environment(\.openWindow) private var openWindow

    /// 下钻列表滚动上限:系统组可达数百进程,超出即滚动(组内行由
    /// ProcessDrilldownView 的 LazyVStack 惰性渲染,保证滚动流畅)。
    /// tab 化后三个 tab 共用同一高度约束。
    private static let drilldownListMaxHeight: CGFloat = 480

    /// 当前 tab(工单 03):图标 tab 点击或 ←/→ 切换,内容模型由此折叠。
    @State private var tabSelection = MetricTabSelection()
    /// 展开中的组(按稳定组 id):跨采样轮次保持,组消失时残留 id 无害。
    @State private var expandedGroupIDs: Set<String> = []
    /// 展开详情的进程(跨组唯一):下钻期间进程退出时详情安静收起。
    @State private var selectedProcessID: pid_t?
    /// 处置结果汇总(工单 08):**有失败才弹**;全成功保持安静——
    /// 行 / 组消失交给下轮采样自然反映,不假装成功也不报喜打扰。
    @State private var killFailureReport: KillReport?

    var body: some View {
        VStack(spacing: 12) {
            titleRow
            MetricIconTabBar(selection: $tabSelection)
            if monitor.allGroups.isEmpty {
                emptyState
            } else {
                pinnedTabCard
                groupList
            }
            Divider()
                .padding(.horizontal, -4)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .modifier(KillFailureAlert(report: $killFailureReport))
    }

    /// 当前 tab 的展示内容(纯逻辑折叠):榜单序、微图资格、组卡口径、内存分段。
    private var content: MetricTabContent {
        MetricTabContent.build(groups: monitor.allGroups, tab: tabSelection.current)
    }

    /// 各 tab 固定在滚动区之上的主卡(工单 03):总览 = 系统负载卡(带 strip,
    /// 唯一保留 strip 的头部);CPU = 面积图主卡(均值/峰值对归位于此);
    /// 内存 = Memory by App 环形卡。
    @ViewBuilder
    private var pinnedTabCard: some View {
        switch tabSelection.current {
        case .overview:
            loadBlock
        case .cpu:
            CPULoadMainCardView(
                currentLoad: monitor.systemCPULoad,
                statistics: monitor.history.systemCPULoad.statistics,
                trendValues: monitor.history.systemCPULoad.values
            )
        case .memory:
            MemoryRingCardView(
                segments: content.memorySegments,
                totalBytes: content.memoryTotalBytes
            )
        }
    }

    /// 组卡滚动列表:榜单序随 tab(总览/CPU = CPU% 降序,内存 = 内存降序)。
    /// 注意必须是普通 VStack(非 Lazy):组卡需要即时构卡参与
    /// 布局;组内数十行的惰性渲染由 ProcessDrilldownView 承担。
    private var groupList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(content.ranking) { group in
                    groupSection(for: group)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // 固定高度(而非 maxHeight):MenuBarExtra 按内容理想尺寸定窗,
        // ScrollView 的理想高度恒为 0,弹窗会被压扁成只剩头部
        // (工单 09 实机走查发现)。固定值与菜单栏工具惯例一致(Vitals 同款)。
        .frame(height: Self.drilldownListMaxHeight)
    }

    /// 底部操作排(用户拍板:合并为单一菜单栏项后的窗口/退出口):
    /// "打开主窗口"为主按钮(openWindow 对已开窗口 = 聚焦);退出为次按钮,
    /// NSApplication.terminate 是 LSUIElement 应用体面的退出路径。
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                // LSUIElement 应用激活策略为 .accessory:openWindow 只建窗不抢前台,
                // 窗口会开在其他应用后面(实机反馈"点了没反应")——先激活再开窗。
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: MainWindowSceneID.value)
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("退出 Pulse")
            .accessibilityLabel("退出 Pulse")
        }
    }

    /// 单个组卡 + 展开后的下钻区。展开只读 monitor.drilldown(最近一轮采样),
    /// 不触发额外采集。meter 榜首与微图资格都由内容模型给出(当前 tab 口径)。
    private func groupSection(for group: ProcessGroup) -> some View {
        VStack(spacing: 6) {
            GroupCardView(
                group: group,
                metric: content.metric,
                isExpanded: expandedGroupIDs.contains(group.id),
                meterFraction: meterFraction(for: group),
                microGraphValues: microGraphValues(for: group),
                onToggle: { toggleExpansion(of: group.id) },
                onEndGroup: { requestEndGroup(group) }
            )
            if expandedGroupIDs.contains(group.id), let drilldown = monitor.drilldown {
                ProcessDrilldownView(
                    group: group,
                    drilldown: drilldown,
                    selectedProcessID: $selectedProcessID,
                    onEndProcess: requestEndProcess
                )
            }
        }
    }

    /// 组卡 meter 归一(工单 02 口径,随 tab 换指标):CPU tab 按 CPU% 榜首、
    /// 内存 tab 按内存榜首归一,由内容模型给榜首。
    private func meterFraction(for group: ProcessGroup) -> Double {
        switch content.metric {
        case .cpu:
            return MeterNormalization.fraction(group.cpuPercent, leader: content.cpuLeader)
        case .memory:
            return MeterNormalization.fraction(
                Double(group.memoryBytes),
                leader: Double(content.memoryLeaderBytes)
            )
        }
    }

    /// 26×14 微图数据(工单 03 纠偏):榜单前 3 名才有;序列随口径取 CPU% 或内存,
    /// 无历史(首轮采样前)则不画。
    private func microGraphValues(for group: ProcessGroup) -> [Double]? {
        guard content.microGraphGroupIDs.contains(group.id),
              let series = monitor.history.series(forGroup: group.id)
        else { return nil }
        switch content.metric {
        case .cpu:
            return series.cpuPercent.values
        case .memory:
            return series.memoryBytes.values.map(Double.init)
        }
    }

    private func toggleExpansion(of groupID: String) {
        if !expandedGroupIDs.insert(groupID).inserted {
            expandedGroupIDs.remove(groupID)
        }
    }

    // MARK: 处置(工单 08)——不主动杀、确认后才杀
    // P0.5-01:确认 + 执行 + 失败汇总的编排抽到 KillRequestFlow(主窗口同流程共用),
    // 弹窗行为不变(同一对话框、同一"有失败才弹"口径)。

    /// 进程详情"结束进程":确认(点名 name+pid)→ SIGTERM;有失败才弹汇总。
    private func requestEndProcess(_ target: KillTarget) {
        killFailureReport = KillRequestFlow.endProcess(target, monitor: monitor)
    }

    /// 组卡"结束整组":确认(列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    private func requestEndGroup(_ group: ProcessGroup) {
        killFailureReport = KillRequestFlow.endGroup(group, monitor: monitor)
    }

    /// 标题排:app 身份 + 状态徽章(工单 04:空载 ✓正常 / 高负载)+ 弹窗 uptime
    /// (参考文档 §2.1 顶栏 "⏱ Up 6d 4h" 形态)+ 设置入口,常驻所有 tab 之上。
    /// uptime 随每轮采样重算(弹窗打开 = 1s 一轮),无需独立计时器。
    private var titleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
            Text("Pulse")
                .font(.headline)
            if let badge = StatusBadgeRules.systemBadge(load: monitor.systemCPULoad) {
                StatusBadgeChip(badge: badge)
            }
            Spacer()
            Text(EnvironmentInfoFormat.systemUptime(ProcessInfo.processInfo.systemUptime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("系统已运行时长")
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("设置项目根目录")
        }
    }

    /// 系统负载卡(总览 tab,工单 P0.6-01/02):当轮值 + 窗口均值/峰值 +
    /// 小趋势条(0–100 固定语义域);<2 轮时趋势只剩轨道与垫底柱、统计对不显示。
    /// 工单 03 纠偏后这是组卡之外唯一保留 strip 的头部。
    private var loadBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            loadLine
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            StripChartView(
                values: monitor.history.systemCPULoad.values,
                tint: Metric.cpu.accentColor,
                domainMax: 100
            )
            .frame(height: 14)
        }
    }

    /// 头部负载读数(工单 01+02 合流):当轮值常驻,数值用 CPU 指标强调色;
    /// 窗口统计 ≥2 轮后附"均值/峰值"对(副文随外层 secondary,不抢数值强调色)。
    private var loadLine: Text {
        var line = Text("系统 CPU 负载 ")
            + Text(PulseFormat.cpuPercent(monitor.systemCPULoad))
                .foregroundStyle(Metric.cpu.accentColor)
        if let stats = monitor.history.systemCPULoad.statistics, stats.count >= 2 {
            line = line
                + Text(" · 均值 \(PulseFormat.cpuPercent(stats.average))")
                + Text(" · 峰值 \(PulseFormat.cpuPercent(stats.peak))")
        }
        return line
    }

    /// 极端空载 / 首轮采样前:无组可显示,给一行安静文案而不是坏 UI(所有 tab 同)。
    private var emptyState: some View {
        Text("暂无活动组")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// 组卡(紧凑行形态,工单 03 用户现场纠偏):Vitals 的应用行是紧凑行——
/// 大数字 + meter(+ 榜单前几名的 26×14 迷你微图),**不再有全尺寸 strip 与
/// 均值/峰值统计对**(全尺寸走势图归位指标 tab 主卡)。
/// 读数口径随 tab:CPU tab = CPU% 大数字 + 内存副文;内存 tab 互换。
/// bundle 组用真实应用图标(NSWorkspace);项目与兜底类别用 SF Symbol;孤儿橙。
/// 工单 06:整卡可点,展开 / 收起组内进程列表(尾部 chevron 指示)。
/// 工单 08:卡上提供"结束整组"入口(确认对话框把关,见 KillConfirmationDialog)。
struct GroupCardView: View {
    let group: ProcessGroup
    /// 读数口径(工单 03):大数字、副文、meter 榜首与微图序列随它切换。
    var metric: GroupCardMetric = .cpu
    let isExpanded: Bool
    /// 占比 meter 条:榜首归一,由调用方按当前 tab 口径算好传入。
    let meterFraction: Double
    /// 26×14 迷你微图序列(nil = 无资格或无历史,行内不画)。
    var microGraphValues: [Double]? = nil
    let onToggle: () -> Void
    let onEndGroup: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // 高负载警示 chip(工单 04):组 CPU% > 100% 才挂
                            // (恰好 100% 不算);名称截断让位、chip 不缩不折。
                            if let badge = StatusBadgeRules.groupBadge(cpuPercent: group.cpuPercent) {
                                StatusBadgeChip(badge: badge)
                            }
                        }
                        Text("\(group.processes.count) 进程")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if let microGraphValues {
                        // 紧凑行微图(参考文档 §3-1 变体:26×14、无轨道、gap-px)。
                        StripChartView(values: microGraphValues, tint: accent, style: .compact)
                            .frame(width: 26, height: 14)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        valueFigure
                        secondaryValue
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    endGroupButton
                }
                // 占比 meter 条(工单 P0.6-02):榜单榜首归一,直接承接大数字——
                // 数字与条同色系;色随 tab 口径换指标强调色,孤儿一行仍橙。
                MeterBar(fraction: meterFraction, tint: accent)
            }
            .padding(10)
            .background(group.category.cardStyle.cardBackground, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name),\(group.processes.count) 进程")
        .accessibilityHint(isExpanded ? "收起组内进程列表" : "展开组内进程列表")
    }

    /// 卡内强调色:CPU 口径走类别样式表(孤儿橙,语义不变);内存口径换内存
    /// 指标强调色——孤儿一行仍橙(GLOSSARY:它往往正是问题所在)。
    private var accent: Color {
        if metric == .memory, group.category != .orphan {
            return Metric.memory.accentColor
        }
        return group.category.cardStyle.accentColor
    }

    /// 大数字(工单 03,参考文档 §1.2 figure 规格):圆体加粗 + tabular 数字 +
    /// 负字距,单位小一号、基线对齐;紧凑行数值档 22px(CPU)/ 20px(内存带小数)。
    /// 数字本体保持墨色(Vitals 同款:大数字用 --ink,色彩交给 meter 条)。
    @ViewBuilder
    private var valueFigure: some View {
        switch metric {
        case .cpu:
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(PulseFormat.cpuPercentNumber(group.cpuPercent))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .kerning(-0.4)
                Text("%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        case .memory:
            let figure = PulseFormat.memoryFigure(group.memoryBytes)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(figure.value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .kerning(-0.3)
                Text(figure.unit)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 副文:与主读数互补的另一指标(CPU 口径 → 内存;内存口径 → CPU%)。
    private var secondaryValue: some View {
        Group {
            switch metric {
            case .cpu:
                Text(PulseFormat.memory(group.memoryBytes))
            case .memory:
                Text("CPU \(PulseFormat.cpuPercent(group.cpuPercent))")
            }
        }
        .font(.system(.caption, design: .rounded).monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
    }

    /// "结束整组"入口:xmark.octagon 图标按钮(borderless:嵌在卡内可独立点按)。
    /// 点击只是请求确认——真正发信号前必有确认对话框(不主动杀)。
    private var endGroupButton: some View {
        Button(action: onEndGroup) {
            Image(systemName: "xmark.octagon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("结束整组(需确认)")
        .accessibilityLabel("结束整组 \(group.name)")
    }

    /// bundle 组:读 .app 目录的真实应用图标;其余:类别样式表的 SF Symbol
    /// (符号与图标色都取自 cardStyle,孤儿的高亮只是表里的一行)。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath = group.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: group.category.cardStyle.symbolName)
                .frame(width: 28)
                .foregroundStyle(group.category.cardStyle.iconColor)
        }
    }
}

/// 组卡样式表(工单 05/09,评审 T6):每个类别一份完整样式
/// (SF Symbol + 图标色 + 卡片底色 + 指标强调色)。孤儿进程的橙色高亮(GLOSSARY:
/// 它往往正是问题所在)是表中的一行,而非散落在视图里的 `.orphan` 特判。
struct GroupCardStyle {
    let symbolName: String
    let iconColor: Color
    let cardBackground: AnyShapeStyle
    /// 指标强调色:CPU 口径下驱动卡内 meter/微图(孤儿橙)。工单 03 tab 化后
    /// 内存口径由 GroupCardView 按当前 tab 的指标另行覆盖(孤儿仍橙,语义不变)。
    let accentColor: Color
}

extension GroupCategory {
    /// 组卡的类别样式:bundle 组由 UI 直接取应用图标,此表服务项目与兜底类别
    /// (spec:符号图 + 孤儿橙色);各类别符号互不相同——"可辨识的类别标记"。
    var cardStyle: GroupCardStyle {
        switch self {
        case .app:
            GroupCardStyle(
                symbolName: "shippingbox", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .project:
            GroupCardStyle(
                symbolName: "hammer", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .system:
            GroupCardStyle(
                symbolName: "cpu", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .backgroundService:
            GroupCardStyle(
                symbolName: "gearshape", iconColor: .secondary,
                cardBackground: AnyShapeStyle(.quaternary),
                accentColor: Metric.cpu.accentColor
            )
        case .orphan:
            GroupCardStyle(
                symbolName: "exclamationmark.triangle",
                iconColor: .orange,
                cardBackground: AnyShapeStyle(Color.orange.opacity(0.15)),
                accentColor: .orange
            )
        }
    }

    /// 组卡图标的 SF Symbol(样式表的符号字段,单测经此断言映射完备且互异)。
    var cardSymbolName: String {
        cardStyle.symbolName
    }
}

// MARK: - 处置确认对话框(工单 08)

/// 确认对话框(NSAlert):"确认后才杀"的唯一关口。
/// **取消按钮先添加 = NSAlert 默认按钮**——默认焦点与回车键都落在"取消"(防误触);
/// "结束"按钮无键盘等价键,只有明确点击才执行。
/// 文案构造在 KillCopy(纯函数,单测见 KillCopyTests);焦点次序属 UI,按 spec 以手动验收。
enum KillConfirmationDialog {
    @MainActor
    static func confirm(title: String, informativeText: String, actionTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: KillCopy.cancelButtonTitle) // 先加 = 默认焦点(回车 = 取消)
        let actionButton = alert.addButton(withTitle: actionTitle)
        actionButton.keyEquivalent = "" // 不给"结束"任何键盘触发
        return alert.runModal() == NSApplication.ModalResponse.alertSecondButtonReturn
    }
}

// MARK: - 处置编排与失败弹窗(工单 08;P0.5-01 起弹窗与主窗口共用)

/// 处置请求编排:确认对话框把关 → 确认后才发信号;返回失败汇总——
/// 全成功返回 nil 保持安静(行 / 组消失交给下轮采样自然反映)。
/// 原为 DashboardView 私有逻辑,工单 P0.5-01 主窗口需要同一流程,抽出共用;
/// 对话框构造(KillCopy)、焦点次序与"有失败才弹"口径与 P0 完全一致。
@MainActor
enum KillRequestFlow {
    /// 进程详情"结束进程"(单目标,确认时点名 name+pid)。
    static func endProcess(_ target: KillTarget, monitor: SystemMonitor) -> KillReport? {
        let targets = [target]
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.confirmationTitle(for: targets),
            informativeText: KillCopy.confirmationMessage(for: targets),
            actionTitle: KillCopy.singleActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminate(targets)
        return report.hasFailures ? report : nil
    }

    /// 组卡"结束整组"(确认时列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    static func endGroup(_ group: ProcessGroup, monitor: SystemMonitor) -> KillReport? {
        let confirmed = KillConfirmationDialog.confirm(
            title: KillCopy.groupConfirmationTitle(groupName: group.name),
            informativeText: KillCopy.groupConfirmationMessage(processCount: group.processes.count),
            actionTitle: KillCopy.groupActionTitle
        )
        guard confirmed else { return nil }
        let report = monitor.terminateGroup(id: group.id)
        return report.hasFailures ? report : nil
    }
}

/// 处置失败汇总弹窗:**有失败才弹**(标题 / 正文 / "知道了"按钮与工单 08 一致)。
struct KillFailureAlert: ViewModifier {
    @Binding var report: KillReport?

    func body(content: Content) -> some View {
        content.alert(
            report?.failureAlertTitle ?? "",
            isPresented: Binding(
                get: { report?.hasFailures == true },
                set: { if !$0 { report = nil } }
            )
        ) {
            Button("知道了") { report = nil }
        } message: {
            Text(report?.failureAlertMessage ?? "")
        }
    }
}

// MARK: - 预览(Synthetic 源,spec 测试决策:UI 以预览 + 手动下钻验收)

#Preview("弹窗") {
    let now = Date()
    let worktree = "/Users/x/work/octok-client/.worktrees/skill-manage-read-and-index"
    // 两张快照推进 cpuTime:第二轮差分出真 CPU(预览即验收锚点形态)。
    func tree(zcode: UInt64, node: UInt64, rustc: UInt64, waifud: UInt64) -> [RawProcess] {
        [
            RawProcess(
                pid: 10,
                parentPID: 1,
                executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode",
                cpuTimeNanoseconds: zcode,
                physicalFootprintBytes: 300_000_000,
                startTime: now.addingTimeInterval(-3 * 3600)
            ),
            RawProcess(
                pid: 11,
                parentPID: 10,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "server.js"],
                cwd: worktree,
                cpuTimeNanoseconds: node,
                physicalFootprintBytes: 80_000_000,
                startTime: now.addingTimeInterval(-25 * 60)
            ),
            RawProcess(
                pid: 100,
                parentPID: 11,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: worktree,
                cpuTimeNanoseconds: rustc,
                physicalFootprintBytes: 200_000_000,
                startTime: now.addingTimeInterval(-40)
            ),
            RawProcess(
                pid: 777,
                parentPID: 1,
                executablePath: "/opt/homebrew/bin/waifud",
                argv: ["waifud"],
                cpuTimeNanoseconds: waifud,
                physicalFootprintBytes: 30_000_000,
                startTime: now.addingTimeInterval(-3 * 86_400)
            ),
        ]
    }
    let monitor = SystemMonitor(
        source: SyntheticProcessSource(snapshots: [
            ProcessSnapshot(
                takenAt: now,
                processes: tree(zcode: 0, node: 0, rustc: 0, waifud: 0)
            ),
            ProcessSnapshot(
                takenAt: now.addingTimeInterval(5),
                processes: tree(
                    zcode: 150_000_000, node: 250_000_000, rustc: 4_500_000_000, waifud: 350_000_000
                )
            ),
        ]),
        projectRoots: ["/Users/x/work/octok-client"]
    )
    return DashboardView(monitor: monitor)
        .task { monitor.start() }
}

#Preview("组卡(紧凑行,CPU 口径)") {
    // meter 榜首 = 三张卡里最高的 445%(P0.6-02 榜首归一的验收锚点);
    // 微图:前两名给满窗锯齿序列,第三名短序列——紧凑行形态的验收锚点。
    return VStack(spacing: 12) {
        GroupCardView(
            group: ProcessGroup(
                id: "project:octok",
                name: "octok-client @ skill-manage-read-and-index",
                category: .project,
                bundlePath: nil,
                processes: [
                    RawProcess(pid: 100, parentPID: 1, physicalFootprintBytes: 200_000_000)
                ],
                cpuPercent: 445,
                memoryBytes: 2_400_000_000
            ),
            isExpanded: false,
            meterFraction: MeterNormalization.fraction(445, leader: 445),
            microGraphValues: (0..<13).map { i in Double(0.4 + Double(i % 5) * 0.15) },
            onToggle: {},
            onEndGroup: {}
        )
        GroupCardView(
            group: ProcessGroup(
                id: "bundle:calculator",
                name: "计算器",
                category: .app,
                bundlePath: "/System/Applications/Calculator.app",
                processes: [
                    RawProcess(pid: 200, parentPID: 1, physicalFootprintBytes: 80_000_000)
                ],
                cpuPercent: 12,
                memoryBytes: 120_000_000
            ),
            isExpanded: true,
            meterFraction: MeterNormalization.fraction(12, leader: 445),
            microGraphValues: [12],
            onToggle: {},
            onEndGroup: {}
        )
        GroupCardView(
            group: ProcessGroup(
                id: "orphan",
                name: "孤儿进程",
                category: .orphan,
                bundlePath: nil,
                processes: [
                    RawProcess(pid: 300, parentPID: 1, physicalFootprintBytes: 30_000_000)
                ],
                cpuPercent: 7,
                memoryBytes: 30_000_000
            ),
            isExpanded: false,
            meterFraction: MeterNormalization.fraction(7, leader: 445),
            onToggle: {},
            onEndGroup: {}
        )
    }
    .padding(16)
    .frame(width: 340)
}

#Preview("组卡(内存口径,内存 tab)") {
    // 内存口径:大数字 = 内存,副文 = CPU%,meter/微图用内存强调色(孤儿仍橙)。
    return VStack(spacing: 12) {
        GroupCardView(
            group: ProcessGroup(
                id: "bundle:browser",
                name: "浏览器",
                category: .app,
                bundlePath: "/Applications/Safari.app",
                processes: [RawProcess(pid: 400, parentPID: 1, physicalFootprintBytes: 3_100_000_000)],
                cpuPercent: 40,
                memoryBytes: 3_100_000_000
            ),
            metric: .memory,
            isExpanded: false,
            meterFraction: MeterNormalization.fraction(3_100_000_000, leader: 3_100_000_000),
            microGraphValues: (0..<13).map { i in Double(2_600_000_000 + UInt64(i) * 40_000_000) },
            onToggle: {},
            onEndGroup: {}
        )
        GroupCardView(
            group: ProcessGroup(
                id: "orphan",
                name: "孤儿进程",
                category: .orphan,
                bundlePath: nil,
                processes: [RawProcess(pid: 300, parentPID: 1, physicalFootprintBytes: 30_000_000)],
                cpuPercent: 7,
                memoryBytes: 30_000_000
            ),
            metric: .memory,
            isExpanded: false,
            meterFraction: MeterNormalization.fraction(30_000_000, leader: 3_100_000_000),
            onToggle: {},
            onEndGroup: {}
        )
    }
    .padding(16)
    .frame(width: 340)
}
