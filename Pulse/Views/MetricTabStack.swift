import PulseCore
import SwiftUI

// MARK: - 每个 tab 的内容栈(主窗口与弹窗共用)

//
// 这里是每个 tab 卡片组成与顺序的唯一出处:主窗口与弹窗同一套,只差排版档。
// 两类内容只在主窗口——传感器的风扇卡与温度明细卡、磁盘页的空间地图,见
// `.sensors` 与 `.disk` 分支;不要为了两处一致把它们加回弹窗。

/// 一个 tab 的内容栈:主窗口与弹窗读同一份——卡片组成、顺序、数据出处全在这里,
/// 两处只差排版档(`isCompact`:弹窗 360pt 定宽)。排版差异只有三种,全由宽度决定:
/// 卡用紧凑档;主窗口并排的两卡一组在弹窗里上下排;节标题(总览的「此刻」)
/// 弹窗不画,卡片各自带标题。排行卡一律卡内标题,不配节标题。
///
/// 组排行卡由宿主经 `ranking` 给:主窗口带搜索过滤与可排序进程表,弹窗是紧凑行与
/// 简版下钻——只差交互深度,出现在哪些 tab、排在哪里由本栈决定。
/// 本栈只出卡片序列,外层 VStack / ScrollView 与间距由宿主给。
struct MetricTabStack<Ranking: View>: View {
    let tab: MetricTab
    let isCompact: Bool
    let monitor: SystemMonitor
    let model: DashboardModel
    /// 清理扫描模型(tab-regroup/03):磁盘页空间地图块的数据源;弹窗不画地图
    /// (360pt 塞不下旭日;与传感器页「弹窗只放派生卡」同理)→ 弹窗宿主传 nil。
    let cleanerModel: CleanerModel?
    /// 当前 tab 的展示内容(内存分段等,DashboardModel.content 折叠)。
    let content: MetricTabContent
    /// 总览卡点击跳转。
    let onSelectTab: (MetricTab) -> Void
    /// 排行截断的溢出策略(ranking-limit/01):主窗口原地展开 / 弹窗跳主窗口;模块排行卡
    /// 在本栈内按卡 id 派生动作,组排行卡由宿主在 `ranking` 里自配(同一策略、同一 id 规则)。
    let overflowPolicy: RankingOverflowPolicy
    @ViewBuilder let ranking: () -> Ranking

    var body: some View {
        ForEach(blocks) { block in
            switch block.kind {
            case let .card(view): view
            case .groupRanking: ranking()
            case let .moduleRanking(spec):
                ModuleRankingCardView(
                    spec: spec,
                    isCompact: isCompact,
                    overflow: overflowPolicy.action(for: block.id, model: model)
                )
            }
        }
    }

    /// 本 tab 的卡片序列(native-list):组成、顺序、数据出处的唯一出处——SwiftUI 宿主
    /// (body)与原生列表(弹窗,逐卡 / 逐排行行拼装)读同一份。
    var blocks: [MetricTabBlock] {
        var builder = MetricTabBlockBuilder(tab: tab)
        switch tab {
        case .overview:
            builder.card("grid", overviewGrid)
            sectionTitle("此刻", into: &builder)
            builder.card("memory-pair", pair {
                RingCardView.memoryByType(monitor.memory, isCompact: isCompact)
            } second: {
                memoryByApp
            })
            builder.groupRanking()
        case .agents:
            // 智能体页两子 tab(agent-tab/06 三子页结构被 tab-regroup/01 缩编:
            // 消耗(账本)/ 会话(在跑)——dev server 卡迁服务页):清理页子药丸
            // 同款模式,默认落「消耗」;子页切换状态在 DashboardModel(切 tab 不丢)。
            let snapshot = monitor.features.agentSessions.snapshot
            builder.card(
                "agent-subtabs",
                AgentSubTabBar(selection: Binding(
                    get: { model.agentSubTab },
                    set: { model.agentSubTab = $0 }
                ), isCompact: isCompact)
            )
            switch model.agentSubTab {
            case .usage:
                // 消耗子页:数字卡排 → 走势 | 日历 → 项目榜单;在跑数从会话快照
                // 按项目名匹配,组装时传入。
                builder.card(
                    "agent-usage-pane",
                    AgentUsagePaneView(
                        rows: monitor.features.agentUsage.rows,
                        projectRows: monitor.features.agentUsage.projectRows,
                        modelRows: monitor.features.agentUsage.modelRows,
                        sessionCounts: monitor.features.agentUsage.sessionCounts,
                        usage: snapshot.usage,
                        liveProjectCounts: AgentUsageWindow.liveProjectCounts(
                            claudeSessions: snapshot.claudeSessions,
                            zcodeSessions: snapshot.zcodeSessions
                        ),
                        isCompact: isCompact,
                        isScanning: monitor.features.agentUsage.isScanning,
                        onRescan: { monitor.features.agentUsage.requestFullRescan() }
                    )
                )
            case .sessions:
                let gitStatuses = monitor.features.agentSessions.gitStatuses
                builder.card(
                    "claude-sessions",
                    ClaudeSessionsCardView(
                        sessions: snapshot.claudeSessions,
                        gitStatuses: gitStatuses,
                        isCompact: isCompact
                    )
                )
                builder.card(
                    "zcode-sessions",
                    ZCodeSessionsCardView(
                        sessions: snapshot.zcodeSessions,
                        gitStatuses: gitStatuses,
                        isCompact: isCompact
                    )
                )
            }
        case .cpu:
            builder.card("main", MetricMainCardView(model: model.cpuModel, isCompact: isCompact))
            builder.groupRanking()
        case .memory:
            builder.card("main", MetricMainCardView(model: model.memoryModel, isCompact: isCompact))
            builder.card("memory-pair", pair {
                RingCardView.memoryByType(monitor.memory, isCompact: isCompact)
            } second: {
                memoryByApp
            })
            builder.groupRanking()
        case .sensors:
            // 传感器页(p2-sensors/04):主窗口 = 派生读数 + 风扇 pair,温度明细折叠其下。
            // 弹窗只画派生卡(Average/Hottest + 最快风扇):逐核明细会把 360pt 弹窗撑得
            // 不可用的高;风扇信息由派生卡的最快风扇行承载。
            if isCompact {
                builder.card("derived", SmcDerivedCardView(reading: monitor.features.smc.reading, isCompact: true))
            } else {
                builder.card("pair", pair {
                    SmcDerivedCardView(reading: monitor.features.smc.reading, isCompact: false)
                } second: {
                    SmcFansCardView(reading: monitor.features.smc.reading, isCompact: false)
                })
                builder.card("temps", SmcTempsDetailCardView(reading: monitor.features.smc.reading, isCompact: false))
            }
        case .peripherals:
            // 外设页(p2-sensors/05/06 + app-volume/01):蓝牙设备表(三源电量合并,
            // 可见 30s 扫描;默认关,卡片按钮 / 设置开关是唯一触发源——权限原则)
            // + 声音区(读数纯展示、事件驱动零轮询;每应用混音卡 1.5s 枚举走
            // shows(.sound) 可见性闸,已接管管线不随可见性拆)。
            builder.card("bluetooth", BluetoothDevicesCardView(
                reading: monitor.features.bluetooth.reading,
                accessState: monitor.features.bluetooth.accessState,
                isCompact: isCompact,
                isAwaitingRead: monitor.features.bluetooth.isAwaitingRead,
                onEnable: { monitor.features.bluetooth.setEnabled(true) },
                onAuthorize: { monitor.features.bluetooth.requestAuthorization() }
            ))
            builder.card("sound", SoundCardView(reading: monitor.features.sound.reading, isCompact: isCompact))
            builder.card("app-volume", AppVolumeCardView(feature: monitor.features.appVolume, isCompact: isCompact))
        case .gpu:
            // GPU 页(p2-sensors/02/03):利用率主卡 + ANE 卡与五路功率区
            // (同一 Energy Model 订阅,一鱼五吃);每 App GPU 归因是 P3(root
            // helper)的事,本页不设排行。
            builder.card("main", MetricMainCardView(model: model.gpuModel, isCompact: isCompact))
            builder.card("pair", pair {
                MetricMainCardView(model: model.aneModel, isCompact: isCompact)
            } second: {
                PowerDomainsCardView(reading: monitor.features.power.reading, isCompact: isCompact)
            })
        case .services:
            // 服务页:三张卡上下堆叠(dev server 卡 / 监听端口卡 / 容器卡),都是「本机跑着
            // 的服务」盘点;页面骨架见 DevServerViews.swift 文件头。全部停止只上抛请求,
            // 确认对话框(KillRequestFlow 关口)把关后才发信号。容器卡不做数据卷占用行。
            builder.card(
                "dev-servers",
                DevServerCardView(servers: monitor.features.devServers.servers, isCompact: isCompact) {
                    model.requestStopAllDevServers(monitor.features.devServers.servers)
                }
            )
            // 监听端口卡(port-view/01):全机监听 TCP 口 + 占用者,行「结束」
            // 上抛该端口全部占用进程(同一 KillRequestFlow 关口)。
            builder.card(
                "ports",
                PortsCardView(inventory: monitor.features.ports.inventory, isCompact: isCompact) { targets in
                    model.requestEndPortHolders(targets)
                }
            )
            builder.card(
                "containers",
                ContainersCardView(reading: monitor.features.containers.reading, isCompact: isCompact)
            )
        case .battery:
            // 电池页(p1-history/02 + battery-energy/01+02):六项读数主卡 + 耗电排行
            // 成对——全部应用 / AI 助手同走 root 能耗指数口径(占比主值 + 指数副文,
            // 活动监视器同族);helper 链不可用或尚无读数时两卡收成一条紧凑引导行
            // (battery-energy/02,双胞胎空卡观感案),读到数据自动还原。组排行与
            // 电池无关,不放。
            builder.card("main", MetricMainCardView(model: model.batteryModel, isCompact: isCompact))
            let impact = monitor.features.energyImpact.reading
            let totalImpact = impact?.totalImpact ?? 0
            let gate = monitor.features.energyImpact.helperGate
            let allAppsRows = EnergyImpactTable.allAppsRows(impact?.top ?? [], totalImpact: totalImpact)
            let agentRows = EnergyImpactTable.agentRows(impact?.agents ?? [], totalImpact: totalImpact)
            switch BatteryRankingsLayout.resolve(
                gate: gate,
                allAppsRowCount: allAppsRows.count,
                agentRowCount: agentRows.count
            ) {
            case .cards:
                let gateEmpty = Self.energyGateEmptyMessage(gate: gate)
                builder.moduleRanking("energy", ModuleRankingSpec(
                    title: "耗电排行 · 全部应用",
                    valueLabel: "占比",
                    rows: allAppsRows,
                    accent: Metric.battery.accentColor,
                    cadenceNote: "能耗指数 · 60 秒一档",
                    emptyMessage: gateEmpty
                ))
                builder.moduleRanking("agents", ModuleRankingSpec(
                    title: "耗电排行 · AI 助手",
                    valueLabel: "占比",
                    rows: agentRows,
                    accent: Metric.battery.accentColor,
                    cadenceNote: "能耗指数 · 60 秒一档",
                    emptyMessage: gateEmpty
                ))
            case let .hint(gate):
                builder.card(
                    "energy-gate-hint",
                    BatteryGateHintRow(
                        message: Self.energyGateEmptyMessage(gate: gate),
                        isCompact: isCompact,
                        showsProgress: gate == .approvedAwaitingReading
                    )
                )
            }
        case .disk:
            // 磁盘页:主卡 → 空间地图 → 各卷 + 快照 → 读写最多排行。地图紧跟主卡折线图
            // (容量总览与占用地图同族相邻),读的是清理扫描这条管线(tab-regroup/03)。
            builder.card("main", MetricMainCardView(model: model.diskModel, isCompact: isCompact))
            // 地图只在主窗口画:旭日下限 360pt,弹窗塞不下。它是「主窗口与弹窗同一套
            // 卡片组成」里只在主窗口的两类内容之一(另一类是传感器的风扇卡与温度明细卡)。
            if !isCompact, let cleanerModel {
                builder.card(
                    "spacemap",
                    DiskSpaceMapSection(
                        model: cleanerModel,
                        drillPath: Binding(
                            get: { model.spaceMapDrillPath },
                            set: { model.spaceMapDrillPath = $0 }
                        ),
                        treeIndex: Binding(
                            get: { model.spaceMapTreeIndex },
                            set: { model.spaceMapTreeIndex = $0 }
                        ),
                        onGoToJunk: { group in
                            // 跨页轻桥:记路由态 + 切清理 tab;CleanerTabView 进页
                            // 消费(落全部清单 + 定位组),「这块能清」动线不因迁页断。
                            model.pendingCleanerJunkGroup = group
                            onSelectTab(.cleaner)
                        }
                    )
                )
            }
            builder.card("pair", pair {
                DiskVolumeBreakdownView(capacity: monitor.features.disk.capacity, isCompact: isCompact)
            } second: {
                DiskSnapshotsCardView(listing: monitor.features.disk.capacity?.snapshots, isCompact: isCompact)
            })
            builder.moduleRanking("disk", ModuleRankingSpec(
                title: "读写最多",
                valueLabel: "读写",
                rows: monitor.features.rankings.diskRows,
                accent: Metric.disk.accentColor,
                cadenceNote: "30 秒一档"
            ))
        case .network:
            // 网络页(工单 p1-history/06):主卡 + 流量累计明细 + 每进程流量排行(nettop 归组)。
            builder.card("main", MetricMainCardView(model: model.networkModel, isCompact: isCompact))
            builder.card(
                "totals",
                NetworkTotalsCardView(totals: monitor.features.history.networkTotals, isCompact: isCompact)
            )
            builder.moduleRanking("network", ModuleRankingSpec(
                title: "每进程流量",
                valueLabel: "流量",
                rows: monitor.features.rankings.networkRows,
                accent: Metric.network.accentColor,
                cadenceNote: "5 秒一档"
            ))
        case .history:
            // 历史页(工单 p1-history/04):指标 × 时间范围走势,查询走引擎 actor。
            builder.card("history", HistoryTabView(history: monitor.features.history, isCompact: isCompact))
        case .cleaner:
            // 清理页整页自持(p4-cleaner/03):主窗口在 MainWindowView 直接特例、
            // 不进本栈;弹窗轴已排除。此分支理论不可达,空序列仅保 switch 完备。
            break
        }
        return builder.blocks
    }

    /// 总览模块卡网格(用户拍板 2026-10-17:全部模块一屏可点,点卡跳对应 tab);
    /// 电池卡随有无内建电池。卡间距 full 16 / compact 8(DESIGN.md §Components)。
    /// 主窗口列数**自适应 1–3**(2026-10-24 拍板,上限 4→3 = agent-tab/06)且
    /// **同行等高**(2026-11-21 拍板「多卡一组相同高度」):单卡最小宽 340
    /// (DESIGN.md `layout.overview-card-min-width`)——720 最小窗宽下 1 列、744 起
    /// 两列、约 1100 三列;弹窗定宽 360 固定 2 列(弹窗卡单行内容天然等高,不走
    /// 等高机制)。
    @ViewBuilder
    private var overviewGrid: some View {
        let style: MetricCardView.Style = isCompact ? .compact : .full
        if isCompact {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(overviewCardItems) { item in
                    MetricCardView(model: item.model, style: style) { onSelectTab(item.tab) }
                }
            }
        } else {
            AdaptiveCardGrid(
                items: overviewCardItems,
                minimumCardWidth: AdaptiveCardGridMetrics.minimumCardWidth,
                spacing: AdaptiveCardGridMetrics.spacing,
                maximumColumns: AdaptiveCardGridMetrics.maximumColumns
            ) { item in
                MetricCardView(model: item.model, style: style) { onSelectTab(item.tab) }
            }
        }
    }

    /// 总览卡的数据轴(卡序 = 数组序;电池卡随有无内建电池)——两档排版共用,
    /// 组成与顺序的单点出处。
    private var overviewCardItems: [OverviewCardItem] {
        var items = [
            OverviewCardItem(model: model.cpuModel, tab: .cpu),
            OverviewCardItem(model: model.memoryModel, tab: .memory),
            OverviewCardItem(model: model.gpuModel, tab: .gpu),
            OverviewCardItem(model: model.diskModel, tab: .disk),
            OverviewCardItem(model: model.networkModel, tab: .network),
        ]
        if monitor.features.battery.hasBattery {
            items.append(OverviewCardItem(model: model.batteryModel, tab: .battery))
        }
        return items
    }

    private var memoryByApp: some View {
        RingCardView.memoryByApp(
            segments: content.memorySegments,
            totalBytes: content.memoryTotalBytes,
            isCompact: isCompact
        )
    }

    /// 两卡一组:主窗口走 `AdaptiveCardPair`(宽够两列并排**等高**,不足上下排;
    /// 2026-11-21 用户拍板响应式 + 同组等高),弹窗上下排(卡间距 8,360 定宽)。
    @ViewBuilder
    private func pair(
        @ViewBuilder _ first: @escaping () -> some View,
        @ViewBuilder second: @escaping () -> some View
    ) -> some View {
        if isCompact {
            VStack(spacing: 8) {
                first()
                second()
            }
        } else {
            AdaptiveCardPair(first: first, second: second)
        }
    }

    /// 节标题只在主窗口画(弹窗卡片自带标题,17pt 节标题在 360pt 里喧宾夺主)。
    private func sectionTitle(_ title: String, into builder: inout MetricTabBlockBuilder) {
        if !isCompact {
            builder.card("section-\(title)", SectionTitle(title: title).padding(.top, 6))
        }
    }
}

/// tab 内容栈的一块:普通卡整块渲染;两种排行另列,原生列表逐行拼装(行才是长列表)。
struct MetricTabBlock: Identifiable {
    enum Kind {
        case card(AnyView)
        /// 组排行(当前最忙):由宿主给(弹窗 / 主窗口交互深度不同)。
        case groupRanking
        case moduleRanking(ModuleRankingSpec)
    }

    /// tab 前缀 + 卡名:切 tab 不复用上一页同名卡的视图身份。
    let id: String
    let kind: Kind
}

extension MetricTabStack {
    /// 耗电排行两卡的门槛空态(battery-energy/01;energy-gate-fix 四态;
    /// energy-one-tap 一键直达):各给一条出路,不留死空态、不假称运行中、
    /// 不停在自家开关让用户猜下一步——需要批准的动作直接带到系统设置的
    /// 登录项批准页(高亮待批准项)。批准仍是用户自点(TCC 原则),app 只带路。
    static func energyGateEmptyMessage(gate: EnergyHelperGate) -> RankingEmptyMessage {
        switch gate {
        case .notInstalled:
            RankingEmptyMessage(
                title: "耗电排行需要特权助手",
                detail: "每分钟采集一次各 App 能耗(活动监视器同口径)。点一下:登记并带你到系统设置允许(仅首次)",
                actionTitle: "开启并去批准",
                action: {
                    PrivilegedHelperStatus.reRegisterAndOpenApproval()
                }
            )
        case .awaitingSystemApproval:
            RankingEmptyMessage(
                title: "等待系统批准",
                detail: "已提交安装,只差你在系统设置里点允许",
                actionTitle: "去批准",
                action: {
                    PrivilegedHelperStatus.openApprovalPane()
                }
            )
        case .approvedButNotRunning:
            // status 说谎态(2026-11-22 用户实案):换 bundle 后 BTM 残留旧批准,
            // 新助手从未跑起。说实话 + 一键重登直达批准页,不绕自家开关。
            RankingEmptyMessage(
                title: "助手已批准但没在运行",
                detail: "Pulse 更新后系统要求重新批准一次。点一下:重新登记并带你到系统设置允许",
                actionTitle: "重新登记并去批准",
                action: {
                    PrivilegedHelperStatus.reRegisterAndOpenApproval()
                }
            )
        case .approvedAwaitingReading:
            RankingEmptyMessage(
                title: "等待读数",
                detail: "特权助手运行中,首档约 1 分钟内到达"
            )
        }
    }
}

/// 卡片序列的拼装器(tab 前缀统一在这里加)。
struct MetricTabBlockBuilder {
    let tab: MetricTab
    private(set) var blocks: [MetricTabBlock] = []

    mutating func card(_ name: String, _ view: some View) {
        blocks.append(MetricTabBlock(id: "\(tab)-\(name)", kind: .card(AnyView(view))))
    }

    mutating func groupRanking() {
        blocks.append(MetricTabBlock(id: Self.groupRankingID(for: tab), kind: .groupRanking))
    }

    /// 组排行卡的 id(tab 前缀 + 卡名):宿主给组排行卡配截断动作时与本栈同一 id 规则,
    /// 弹窗「查看全部」带去主窗口的落点才对得上(ranking-limit/01)。
    static func groupRankingID(for tab: MetricTab) -> String {
        "\(tab)-group-ranking"
    }

    mutating func moduleRanking(_ name: String, _ spec: ModuleRankingSpec) {
        blocks.append(MetricTabBlock(id: "\(tab)-\(name)", kind: .moduleRanking(spec)))
    }
}

/// 自适应网格的常量(泛型 struct 不支持 static 存储属性,独立枚举承载;
/// 网格本体 = CardFamily 的 `AdaptiveCardGrid`,2026-11-10 合一)。
private enum AdaptiveCardGridMetrics {
    /// 单卡最小宽(DESIGN.md `layout.overview-card-min-width`)。
    static let minimumCardWidth: CGFloat = 340
    static let spacing: CGFloat = 16
    /// 列数上限(agent-tab/06 用户拍板:最多 3 列,不再出 4 列)。
    static let maximumColumns = 3
}

/// 总览卡数据轴的一项:卡模型 + 点击跳的 tab(id 稳定 = tab,重组不闪)。
private struct OverviewCardItem: Identifiable {
    let model: MetricCardModel
    let tab: MetricTab
    var id: String {
        tab.rawValue
    }
}

/// 两卡一组(主窗口):内容宽容纳两列(DESIGN.md
/// `{layout.card-pair-two-column-min-width}`)→ 并排**等高**(行内每卡
/// `.frame(maxHeight: .infinity)` 顶对齐,短卡背景铺满行高,agent 页同行等高
/// 同款机制),否则上下排。用户拍板 2026-11-21。排布交给 `AdaptiveColumnsLayout`
/// (单卡最小宽 340 + 列距 16、最多 2 列 = 断点 696):宽度当场定排法,不经状态——
/// 原生列表离屏量高与可见行显示同一结果(main-window-native-list)。
private struct AdaptiveCardPair<A: View, B: View>: View {
    @ViewBuilder let first: () -> A
    @ViewBuilder let second: () -> B

    var body: some View {
        AdaptiveColumnsLayout(
            minimumItemWidth: AdaptiveCardGridMetrics.minimumCardWidth,
            spacing: AdaptiveCardGridMetrics.spacing,
            maximumColumns: 2
        ) {
            first().frame(maxHeight: .infinity, alignment: .top)
            second().frame(maxHeight: .infinity, alignment: .top)
        }
    }
}
