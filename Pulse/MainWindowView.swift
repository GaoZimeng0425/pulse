import SwiftUI

// MARK: - 主窗口(工单 P0.5-01):全部组列表 + 三层下钻
// P0.6-05 对齐 SHOT1:药丸 tab 进标题栏工具栏、齿轮在右;内容头 = 页名大标题 +
// "芯片 · 核数 · 内存";总览 = 指标卡网格 + "此刻"环形卡 + "当前最忙"排行卡;
// CPU / 内存 tab = 指标主卡 + 排行卡(内存再加按应用环形)。

/// 主窗口场景 id:弹窗头部"在窗口中打开"按钮与第二菜单栏项都以
/// `openWindow(id:)` 打开同一窗口——两个入口,一个目的地。
enum MainWindowSceneID {
    static let value = "main"
}

/// 主窗口:展示**全部组**(排行卡读 `monitor.allGroups`),排行行 → 进程表
/// (CPU%/内存可点表头排序)→ 进程详情,三层结构与弹窗同源;数据同源实时刷新
/// (@Observable),窗口开/关不触碰弹窗可见性——采样节奏与窗口无关
/// (spec:窗口不属于"弹窗打开"状态)。
struct MainWindowView: View {
    let monitor: SystemMonitor
    /// 工具栏齿轮:设置窗(项目根目录)。
    @Environment(\.openSettings) private var openSettings
    /// 告警通知路由(工单 P1-07):消费点开通知落下的 tab(nil = 无路由场景,预览)。
    var alertRouter: AlertNotificationRouter?

    /// 两窗共用呈现模型(评审 F4):卡模型 / 会话状态 / 处置请求同出处。
    @State private var model: DashboardModel
    /// 当前 tab(工单 03):药丸点击或 ←/→ 切换;初始 tab 可注入(走查预留)。
    @State private var tabSelection: MetricTabSelection
    /// 工具栏搜索框:窗口本地会话态,与 tab 选中同层;过滤纯视图层,不动数据。
    @State private var searchQuery: String = ""

    init(monitor: SystemMonitor, initialTab: MetricTab = .overview, alertRouter: AlertNotificationRouter? = nil) {
        self.monitor = monitor
        self.alertRouter = alertRouter
        _model = State(initialValue: DashboardModel(monitor: monitor))
        // 展示轴随电池可用性(工单 02):无内建电池的机器不含电池页。
        // 窗口新建/重建时先取路由落点(点通知时窗口可能还没开)。
        _tabSelection = State(initialValue: MetricTabSelection(
            current: alertRouter?.pendingTab ?? initialTab,
            axis: MetricTab.displayAxis(hasBattery: monitor.hasBattery)
        ))
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            // tab 条住内容区不住工具栏:P1 加到 6+ 个后工具栏 .principal 放不下,
            // macOS 对放不下的尾项是裁切不是换行(用户实测电池 tab 被剪)。
            // 钉在滚动区外——内容滚动时导航常驻。
            MetricPillTabBar(selection: $tabSelection)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pageHeader
                    AlertBannerView(center: monitor.alerts)
                    tabBody
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        // 首次电池读数落地 → 电池页入轴(工单 02);被隐藏的当前 tab 回落总览。
        .onChange(of: monitor.hasBattery) { _, hasBattery in
            tabSelection.setAxis(MetricTab.displayAxis(hasBattery: hasBattery))
        }
        // 点开告警通知 → 直达对应 tab(工单 P1-07):窗口存活时响应广播;
        // 窗口刚被 openWindow 拉起时 onAppear 消费落下的 pendingTab。
        .onReceive(NotificationCenter.default.publisher(
            for: AlertNotificationRouter.openMainWindowNotification
        )) { notification in
            if let raw = notification.userInfo?[AlertNotificationRouter.tabUserInfoKey] as? String,
               let tab = MetricTab(rawValue: raw) {
                tabSelection.current = tab
            }
        }
        .onAppear {
            if let tab = alertRouter?.consumePendingTab() {
                tabSelection.current = tab
            }
        }
        // spec 最小尺寸 ~720×560;弹窗的宽度约束是 MenuBarExtra 专用,此处不适用。
        .frame(minWidth: 720, minHeight: 560)
        .containerBackground(Surface.window, for: .window)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MainSearchField(query: $searchQuery)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置项目根目录")
            }
        }
        .modifier(KillFailureAlert(report: $model.killFailureReport))
    }

    /// 当前 tab 的展示内容(纯逻辑折叠,与弹窗同一出处):榜单序、组行口径、内存分段。
    private var content: MetricTabContent {
        model.content(tab: tabSelection.current)
    }

    /// 搜索过滤器(视图直接持有的归一口径;空查询时全部旁路)。
    private var searchFilter: ProcessSearchFilter {
        ProcessSearchFilter(query: searchQuery)
    }

    /// 搜索生效时的可见组(口径在 ProcessSearchFilter.filteredGroups)。
    private var displayGroups: [ProcessGroup] {
        ProcessSearchFilter.filteredGroups(content.ranking, filter: searchFilter) { group in
            monitor.drilldown.map { $0.rows(for: group) }
        }
    }

    /// 内容头(SHOT1:`Overview` 大标题 + `Apple M1 Max · 10 cores · 64 GB`)。
    private var pageHeader: some View {
        let host = HostInfo.current
        return VStack(alignment: .leading, spacing: 3) {
            Text(tabSelection.current.title)
                .font(.system(size: 26, weight: .bold))
            Text(PulseFormat.hostSummary(
                chipName: host.chipName,
                coreCount: host.coreCount,
                physicalMemoryBytes: host.physicalMemoryBytes
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch tabSelection.current {
        case .overview:
            HStack(alignment: .top, spacing: 16) {
                MetricCardView(model: model.cpuModel) { tabSelection.current = .cpu }
                MetricCardView(model: model.memoryModel) { tabSelection.current = .memory }
            }
            SectionTitle(title: "此刻")
                .padding(.top, 6)
            HStack(alignment: .top, spacing: 16) {
                RingCardView.memoryByType(monitor.memory)
                RingCardView.memoryByApp(segments: content.memorySegments, totalBytes: content.memoryTotalBytes)
            }
            SectionTitle(title: "当前最忙")
                .padding(.top, 6)
            rankingCard
        case .cpu:
            MetricMainCardView(model: model.cpuModel)
            rankingCard
        case .memory:
            MetricMainCardView(model: model.memoryModel)
            HStack(alignment: .top, spacing: 16) {
                RingCardView.memoryByType(monitor.memory)
                RingCardView.memoryByApp(segments: content.memorySegments, totalBytes: content.memoryTotalBytes)
            }
            rankingCard
        case .battery:
            // 电池页(工单 02):六项读数主卡;组排行与电池无关,不放。
            MetricMainCardView(model: model.batteryModel)
        case .disk:
            // 磁盘页(工单 05):主卡 + 各卷对账明细 + 快照列表(弹窗同构,紧凑)。
            MetricMainCardView(model: model.diskModel)
            HStack(alignment: .top, spacing: 16) {
                DiskVolumeBreakdownView(capacity: monitor.diskCapacity)
                DiskSnapshotsCardView(listing: monitor.diskCapacity?.snapshots)
            }
        case .history:
            // 历史页(工单 04):指标 × 时间范围 Canvas 走势;查询走引擎 actor,
            // 主窗口是它唯一的入口(弹窗轴滤掉了历史页)。
            HistoryTabView(monitor: monitor)
        }
    }

    /// 排行卡:全部组;搜索生效时换成过滤后的组(无命中 → 专用空态);
    /// 点行展开主窗口版进程表(表头可排序);前 3 名带 26×14 微图(工单 03 兑现)。
    /// meter 归一榜首仍取全榜单(content 口径),过滤不改变条的相对读数。
    @ViewBuilder
    private var rankingCard: some View {
        let filter = searchFilter
        if filter.isActive {
            if displayGroups.isEmpty {
                searchMissState
            } else {
                rankingCardList(displayGroups)
            }
        } else if monitor.allGroups.isEmpty {
            emptyState
        } else {
            rankingCardList(content.ranking)
        }
    }

    /// 排行卡本体(有无搜索共用一份构造,只差组列表)。
    private func rankingCardList(_ groups: [ProcessGroup]) -> some View {
        RankingCardView(
            groups: groups,
            metric: content.metric,
            cpuLeader: content.cpuLeader,
            memoryLeaderBytes: content.memoryLeaderBytes,
            expandedGroupIDs: model.expandedGroupIDs,
            microGraphValues: model.microGraphValues(for: content),
            onToggle: model.toggleExpansion(of:),
            onEndGroup: model.requestEndGroup
        ) { group in
            if let drilldown = monitor.drilldown {
                SortableProcessTableView(
                    group: group,
                    drilldown: drilldown,
                    searchFilter: searchFilter,
                    selectedProcessID: $model.selectedProcessID,
                    onEndProcess: model.requestEndProcess
                )
            }
        }
    }

    /// 搜索无命中:与"暂无活动组"区分开——首轮空载和搜不到是两回事。
    private var searchMissState: some View {
        VStack(spacing: 8) {
            Text("没有匹配“\(searchFilter.normalized)”的结果")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("试试应用名的片段,或输入纯数字按 PID 前缀搜")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Surface.card, in: .rect(cornerRadius: 18))
    }

    /// 首轮采样前 / 极端空闲:与弹窗同一句安静文案。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("暂无活动组")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("首轮采样尚未完成,或系统极端空闲")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Surface.card, in: .rect(cornerRadius: 18))
    }
}

// MARK: - 工具栏搜索框

/// 主窗口工具栏搜索框:放大镜 + 无边框输入 + 一键清空。⌘F 聚焦;
/// Esc 先清空、再按一次失焦。药丸 tab 占了 principal,搜索框与齿轮同为
/// primaryAction(声明序在前 → 摆齿轮左侧);宽度定长,药丸 tab 在 720
/// 最小窗宽下不挤。⌘F / Esc 行为属手动验收。
private struct MainSearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索应用或 PID", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .keyboardShortcut("f", modifiers: .command)
                .onExitCommand {
                    if query.isEmpty {
                        isFocused = false
                    } else {
                        query = ""
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .frame(width: 168)
    }
}

// MARK: - 主窗口进程表(表头可排序)

/// 主窗口进程表:组卡展开后的表区。表头 CPU%/内存两列可点排序
/// (排序纯逻辑在 `ProcessTableOrder`,单测见 MainWindowModelTests;
/// 表头指示符渲染与点按属手动验收);进程行与进程详情直接复用弹窗的
/// `ProcessRowView` / `ProcessDetailView`——同一批组件,窗口版只多了排序。
struct SortableProcessTableView: View {
    let group: ProcessGroup
    let drilldown: DrilldownState
    /// 工具栏搜索:组名命中 → 全部行,否则只留命中行(口径在 ProcessSearchFilter)。
    let searchFilter: ProcessSearchFilter
    /// 当前展开详情的进程(nil = 全部收起),跨组唯一由主窗口持有。
    @Binding var selectedProcessID: pid_t?
    @State private var order = ProcessTableOrder()
    /// 处置请求上抛:请求 ≠ 执行,确认对话框把关后才发信号(与弹窗同关卡)。
    let onEndProcess: (KillTarget) -> Void

    var body: some View {
        // rows(for:) 保持引擎既定序(进程 CPU% 降序)——搜索过滤保序叠加其上,
        // 排序再叠加过滤结果:同值次键 pid 升序,排序跨采样轮稳定,进窗口默认
        // 观感与弹窗一致。
        let rows = order.sorted(searchFilter.filterRows(for: group, in: drilldown.rows(for: group)))
        // 进程行 meter 榜首(工单 P0.6-02):当前表内 CPU% 最大者——
        // 无论按哪列排序,meter 恒以 CPU 占比取值(CPU 指标驱动 meter),
        // 换列排序只换行序,不换条的口径。
        let cpuLeader = rows.map(\.cpuPercent).max() ?? 0
        VStack(spacing: 0) {
            tableHeader
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ProcessRowView(
                        row: row,
                        isSelected: selectedProcessID == row.pid,
                        meterFraction: MeterNormalization.fraction(row.cpuPercent, leader: cpuLeader)
                    ) {
                        selectedProcessID = selectedProcessID == row.pid ? nil : row.pid
                    }
                    if selectedProcessID == row.pid, let detail = drilldown.detail(for: row.pid) {
                        ProcessDetailView(detail: detail, onEnd: onEndProcess)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
    }

    /// 排序表头:列布局与 ProcessRowView 对齐(名/pid 在前,CPU%/内存尾部对齐),
    /// 只有 CPU% 与内存两列可点;活跃列带小箭头(降序▾ / 升序▴),非活跃列无箭头。
    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("进程")
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            headerButton(title: "CPU%", key: .cpu, minWidth: 44)
            headerButton(title: "内存", key: .memory, minWidth: 56)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// 单个可点表头:点同列 = 升降切换;换列 = 该列降序(主视角)。
    /// minWidth 与 ProcessRowView 的数值列一致,尾部对齐不跑偏。
    private func headerButton(
        title: String,
        key: ProcessTableSortKey,
        minWidth: CGFloat
    ) -> some View {
        Button {
            order.toggle(key)
        } label: {
            HStack(spacing: 2) {
                if order.key == key {
                    Image(systemName: order.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: minWidth, alignment: .trailing)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
        .accessibilityLabel("按\(title)排序")
        .accessibilityValue(order.key == key ? (order.ascending ? "升序" : "降序") : "未启用")
    }
}

// MARK: - 预览(Synthetic 源,spec 测试决策:UI 以预览 + 手动下钻验收)

/// 预览树:7 个 App 组 + 1 个系统组 = 8 组,弹窗只显示 Top-5,
/// 主窗口全显示——预览即"超出 Top-5 仍可见"的验收锚点。
#Preview("主窗口:全部 8 组(弹窗只装下 5 组)") {
    let now = Date()
    let apps = (1...7).map { index in
        RawProcess(
            pid: pid_t(200 + index),
            parentPID: 1,
            executablePath: "/Applications/A\(index * 10).app/Contents/MacOS/A\(index * 10)",
            cpuTimeNanoseconds: UInt64(index) * 300_000_000,
            physicalFootprintBytes: UInt64(index) * 40_000_000
        )
    }
    let windowServer = RawProcess(
        pid: 1,
        parentPID: 0,
        executablePath: "/System/Library/CoreServices/WindowServer.app/Contents/MacOS/WindowServer"
    )
    let monitor = SystemMonitor(
        source: SyntheticProcessSource(snapshots: [
            ProcessSnapshot(takenAt: now, processes: apps + [windowServer]),
            ProcessSnapshot(
                takenAt: now.addingTimeInterval(5),
                // 差分出互不相同的 CPU%(A70 最高,榜单降序一目了然)。
                processes: apps.map { process in
                    RawProcess(
                        pid: process.pid,
                        parentPID: process.parentPID,
                        executablePath: process.executablePath,
                        cpuTimeNanoseconds: process.cpuTimeNanoseconds
                            + UInt64(process.pid - 200) * 100_000_000,
                        physicalFootprintBytes: process.physicalFootprintBytes
                    )
                } + [windowServer]
            ),
        ])
    )
    return MainWindowView(monitor: monitor)
        .task { monitor.start() }
}
