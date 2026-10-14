import SwiftUI

// MARK: - 主窗口(工单 P0.5-01):全部组列表 + 三层下钻

/// 主窗口场景 id:弹窗头部"在窗口中打开"按钮与第二菜单栏项都以
/// `openWindow(id:)` 打开同一窗口——两个入口,一个目的地。
enum MainWindowSceneID {
    static let value = "main"
}

/// 主窗口:展示**全部组**(读 `monitor.allGroups`,非弹窗的 Top-5 截取),
/// 组卡 → 进程表(CPU%/内存可点表头排序)→ 进程详情,三层结构与弹窗同源;
/// 数据同源实时刷新(@Observable),窗口开/关不触碰弹窗可见性——
/// 采样节奏与窗口无关(spec:窗口不属于"弹窗打开"状态)。
struct MainWindowView: View {
    let monitor: SystemMonitor

    /// 展开中的组(按稳定组 id),跨采样轮保持;组消失时残留 id 无害(少渲染一张卡)。
    @State private var expandedGroupIDs: Set<String> = []
    /// 展开详情的进程(跨组唯一):下钻期间进程退出时详情安静收起。
    @State private var selectedProcessID: pid_t?
    /// 处置失败汇总(工单 08,与弹窗共用弹窗与流程):**有失败才弹**。
    @State private var killFailureReport: KillReport?

    var body: some View {
        VStack(spacing: 12) {
            header
            if monitor.allGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // 普通 VStack:组卡即时构卡参与布局;组内数十行的惰性渲染
                    // 由 SortableProcessTableView 的 LazyVStack 承担。
                    VStack(spacing: 12) {
                        ForEach(monitor.allGroups) { group in
                            groupSection(for: group)
                        }
                    }
                }
            }
        }
        .padding(16)
        // spec 最小尺寸 ~720×560:内容最小尺寸约束窗口最小尺寸;
        // 弹窗的 480pt 高度上限与 340pt 宽度是 MenuBarExtra 专用,此处不适用。
        .frame(minWidth: 720, minHeight: 560)
        .modifier(KillFailureAlert(report: $killFailureReport))
    }

    /// 单个组卡 + 展开后的进程表。组卡 / 结束入口复用弹窗组件(同一确认对话框把关),
    /// 进程表换成主窗口版(表头可排序)。
    private func groupSection(for group: ProcessGroup) -> some View {
        VStack(spacing: 6) {
            GroupCardView(
                group: group,
                history: monitor.history.series(forGroup: group.id),
                isExpanded: expandedGroupIDs.contains(group.id),
                meterFraction: MeterNormalization.fraction(group.cpuPercent, leader: groupCPULeader),
                onToggle: { toggleExpansion(of: group.id) },
                onEndGroup: {
                    killFailureReport = KillRequestFlow.endGroup(group, monitor: monitor)
                }
            )
            if expandedGroupIDs.contains(group.id), let drilldown = monitor.drilldown {
                SortableProcessTableView(
                    group: group,
                    drilldown: drilldown,
                    selectedProcessID: $selectedProcessID,
                    onEndProcess: { target in
                        killFailureReport = KillRequestFlow.endProcess(target, monitor: monitor)
                    }
                )
            }
        }
    }

    /// 组卡 meter 的归一榜首(工单 P0.6-02):与弹窗同一口径——当前榜单
    /// (主窗口 = 全部组)CPU% 最大者,两处榜单的条宽直接可比。
    private var groupCPULeader: Double {
        monitor.allGroups.map(\.cpuPercent).max() ?? 0
    }

    private func toggleExpansion(of groupID: String) {
        if !expandedGroupIDs.insert(groupID).inserted {
            expandedGroupIDs.remove(groupID)
        }
    }

    /// 头部与弹窗同款式(Pulse + 系统 CPU 负载),另给全部组计数——
    /// 窗口的卖点正是"Top-5 之外还有多少组"。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pulse")
                    .font(.headline)
                loadLine
                    .font(.caption)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    /// 系统 CPU 负载读数(工单 P0.6-02):文案不变,数值用 CPU 指标强调色
    /// (与弹窗头部同一处理)。
    private var loadLine: Text {
        Text("系统 CPU 负载 ")
            .foregroundStyle(.secondary)
            + Text(PulseFormat.cpuPercent(monitor.systemCPULoad))
                .foregroundStyle(Metric.cpu.accentColor)
            + Text(" · 共 \(monitor.allGroups.count) 组")
                .foregroundStyle(.secondary)
    }

    /// 极端空载 / 首轮采样前:与弹窗同一句安静文案,大画布上居中。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("暂无活动组")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("首轮采样尚未完成,或系统极端空闲")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// 当前展开详情的进程(nil = 全部收起),跨组唯一由主窗口持有。
    @Binding var selectedProcessID: pid_t?
    @State private var order = ProcessTableOrder()
    /// 处置请求上抛:请求 ≠ 执行,确认对话框把关后才发信号(与弹窗同关卡)。
    let onEndProcess: (KillTarget) -> Void

    var body: some View {
        // rows(for:) 保持引擎既定序(进程 CPU% 降序)——排序叠加其上:
        // 同值次键 pid 升序,排序跨采样轮稳定,进窗口默认观感与弹窗一致。
        let rows = order.sorted(drilldown.rows(for: group))
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
