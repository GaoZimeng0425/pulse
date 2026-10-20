import SwiftUI
import AppKit

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
            axis: MetricTab.displayAxis(hasBattery: monitor.battery.hasBattery)
        ))
    }

    var body: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader
                AlertBannerView(center: monitor.alerts)
                tabBody
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        // 首次电池读数落地 → 电池页入轴(工单 02);被隐藏的当前 tab 回落总览。
        .onChange(of: monitor.battery.hasBattery) { _, hasBattery in
            tabSelection.setAxis(MetricTab.displayAxis(hasBattery: hasBattery))
        }
        // 模块排行采样闸(工单 01):主窗口停在电池/磁盘/网络页才开闸,切走或
        // 关窗即关。只表达主窗口自己的贡献——与弹窗信号的 OR 合并在 monitor
        // 内做,这里不碰弹窗语义;重复同值调用在 provider 侧是 no-op。
        .onChange(of: tabSelection.current) { _, newTab in
            monitor.setModuleRankingsVisible(newTab.hostsModuleRanking)
        }
        .onDisappear {
            monitor.setModuleRankingsVisible(false)
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
            // 模块排行闸(工单 01):窗口可能直接深链落在排行页,进场即按当前
            // tab 开闸(onChange 只管后续切换,不覆盖进场初值)。
            monitor.setModuleRankingsVisible(tabSelection.current.hostsModuleRanking)
            MainWindowView.repositionIfOffscreen()
            // 系统窗口恢复套旧 frame 发生在 onAppear 之后——补一拍延迟守卫。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainWindowView.repositionIfOffscreen()
            }
        }
        // 外接屏断电后系统把窗口还回幻影屏坐标(AX/截屏/人眼都够不着),
        // 应用重新激活时再守一次——"打开主窗口像没反应"的根因之一。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            MainWindowView.repositionIfOffscreen()
        }
        // spec 最小尺寸 ~720×560;弹窗的宽度约束是 MenuBarExtra 专用,此处不适用。
        .frame(minWidth: 720, minHeight: 560)
        .containerBackground(Surface.window, for: .window)
        .toolbar {
            // 老样式:药丸 tab 居中挂工具栏 .principal。P1 加到 6-7 个后靠收紧
            // 药丸内距(12→9)保 720 最小窗宽装得下,样式不变。
            ToolbarItem(placement: .principal) {
                MetricPillTabBar(selection: $tabSelection)
            }
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
                .accessibilityLabel("设置")
            }
        }
        // 工具栏不展示窗口标题(Window 场景名"Pulse")——标题文字占掉左侧一截,
        // 是 720 最小窗宽下工具栏溢出(搜索框被收进 >> 菜单)的推手之一;
        // NSWindow.title 仍是 Pulse,离屏守卫按标题找窗口不受影响。
        .toolbar(removing: .title)
        .modifier(KillFailureAlert(report: $model.killFailureReport))
    }

    /// 当前 tab 的展示内容(纯逻辑折叠,与弹窗同一出处):榜单序、组行口径、内存分段。
    private var content: MetricTabContent {
        model.content(tab: tabSelection.current)
    }

    /// 窗口落在**用户看不见的屏**(典型:外接屏断电留幻影屏,系统状态恢复把窗口
    /// 还回旧坐标)时,搬回用户光标所在的在线屏。判据依据 2026-10-16 验收走查的
    /// 实测排除法:幻影屏在 CG/NSScreen 层仍是"活跃在线",甚至可以是
    /// NSScreen.main(用户把它设过主屏)——"面板灭没灭"没有任何 API 可问,唯一
    /// 骗不掉的锚点是用户此刻的光标(点"打开主窗口"时光标必然在他们看得见的
    /// 屏上);光标定位不到就退回内建屏(笔记本开盖必亮)。
    static func repositionIfOffscreen() {
        let window = NSApp.windows.first {
            $0.identifier?.rawValue == MainWindowSceneID.value || $0.title == "Pulse"
        }
        guard let window else {
            LogService.info("离屏守卫:未找到主窗口(windows=\(NSApp.windows.map { "\($0.title)|\($0.identifier?.rawValue ?? "-")" }.joined(separator: ",")))", category: "MainWindow")
            return
        }
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        guard onlineCount > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let online = ids.prefix(Int(onlineCount)).map { ($0, CGDisplayBounds($0)) }
        // 目标屏 = 光标所在屏;光标落点无归属(极端)则内建屏,再退最大在线屏。
        let target = online.first { $0.1.contains(cursor) }?.1
            ?? online.first { CGDisplayIsBuiltin($0.0) != 0 }?.1
            ?? online.map { $0.1 }.max { $0.width < $1.width }
        guard let target else { return }
        guard !target.intersects(window.frame) else { return }
        var origin = CGPoint(
            x: target.midX - window.frame.width / 2,
            y: target.midY - window.frame.height / 2
        )
        origin.x = max(target.minX + 8, min(origin.x, target.maxX - window.frame.width - 8))
        origin.y = max(target.minY + 8, min(origin.y, target.maxY - window.frame.height - 8))
        LogService.info("离屏守卫:窗口在 \(window.frame),按光标搬回 \(origin)", category: "MainWindow")
        window.setFrameOrigin(origin)
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
        return VStack(alignment: .leading, spacing: 2) {
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

    /// tab 内容:与弹窗共用一份(MetricTabStack),主窗口用全尺寸档;组排行卡
    /// 带搜索过滤与可排序进程表。
    private var tabBody: some View {
        MetricTabStack(
            tab: tabSelection.current,
            isCompact: false,
            monitor: monitor,
            model: model,
            content: content,
            onSelectTab: { tabSelection.current = $0 }
        ) {
            rankingCard
        }
    }

    /// 排行卡:全部组;搜索生效时换成过滤后的组(无命中 → 卡内专用空态,与首轮
    /// 空载区分开);点行展开主窗口版进程表(表头可排序)。
    /// meter 归一榜首仍取全榜单(content 口径),过滤不改变条的相对读数。
    private var rankingCard: some View {
        let filter = searchFilter
        return RankingCardView(
            groups: filter.isActive ? displayGroups : content.ranking,
            metric: content.metric,
            cpuLeader: content.cpuLeader,
            memoryLeaderBytes: content.memoryLeaderBytes,
            expandedGroupIDs: model.expandedGroupIDs,
            emptyMessage: filter.isActive
                ? RankingEmptyMessage(
                    title: "没有匹配“\(filter.normalized)”的结果",
                    detail: "试试应用名的片段,或输入纯数字按 PID 前缀搜"
                )
                : RankingEmptyMessage(title: "暂无活动组", detail: "首轮采样尚未完成,或系统极端空闲"),
            onToggle: model.toggleExpansion(of:),
            onEndGroup: model.requestEndGroup
        ) { group in
            if let drilldown = monitor.drilldown {
                SortableProcessTableView(
                    group: group,
                    drilldown: drilldown,
                    searchFilter: filter,
                    selectedProcessID: $model.selectedProcessID,
                    onEndProcess: model.requestEndProcess
                )
            }
        }
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
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: .capsule)
        // 132(原 168):右侧空间收紧后,工具栏在 720 最小窗宽也装得下,
        // 不再触发 >> 溢出菜单(用户拍板:宁可框窄,不要溢出菜单)。
        .frame(width: 132)
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
        let cpuLeader = Leaderboard.leader(rows, by: \.cpuPercent)
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
        .padding(.horizontal, 12)
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
    let monitor = SystemMonitor.preview(
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
