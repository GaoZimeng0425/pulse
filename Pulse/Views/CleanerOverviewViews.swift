import PulseCore
import SwiftUI

// MARK: - 清理总览子页(p6-cleaner/03,丙案 v2):Hero + 七模块大卡 + 废纸篓卡

//
// 数据面全部来自 PulseCore 纯值:`JunkOverviewAggregator.overview`(Hero 与模块卡)、
// `TrashInventory`(废纸篓读数)、`JunkOverviewAggregator.safeAutoSelection`(一键清理,
// 经 CleanerModel.selectAllAndRequestClean 落勾选并弹既有确认单)。本文件只描边配色;
// 数值令牌见 DESIGN.md §Components「清理总览页」。

// MARK: - 品类卡文案(蓝本 = 丙案 v2 原型;身份色在 MetricAccent.swift 单出处)

extension JunkGroup {
    /// 总览模块大卡的一句人话(丙案 v2 原型文案蓝本)。
    var overviewTagline: String {
        switch self {
        case .globalToolCache: "工具链与包管理器的下载缓存"
        case .browserCache: "网页临时文件,清了下次访问重建"
        case .appCache: "各 App 与系统的缓存、日志"
        case .projectArtifacts: "构建中间产物,删了重新构建"
        case .aiModels: "本地大模型,删了要重新下载"
        case .uninstallLeftovers: "已卸载应用留下的数据"
        }
    }

    /// 总览图标瓦符号(42pt 大瓦);清单行 / 确认单的逐条符号仍取候选自带 symbolName。
    var overviewSymbolName: String {
        switch self {
        case .globalToolCache: "wrench.and.screwdriver"
        case .browserCache: "globe"
        case .appCache: "app"
        case .projectArtifacts: "hammer"
        case .aiModels: "brain"
        case .uninstallLeftovers: "app.dashed"
        }
    }
}

/// 废纸篓卡的文案(与品类文案同表管理)。
enum JunkTrashCardCopy {
    static let title = "废纸篓"
    static let tagline = "清空 = 永久删除,单独操作"
    static let symbolName = "trash"
}

// MARK: - 子页

/// 总览子页:未扫描给 CTA,扫描中给提示,完成给 Hero + 模块大卡 + 废纸篓卡。
struct CleanerOverviewSection: View {
    let model: CleanerModel
    /// 点模块大卡 = 下钻全部清单按品类过滤(导航由壳层做,它持有 subTab / junkFilter)。
    let onDrill: (JunkGroup) -> Void
    /// Hero 主按钮「一键清理…」:导航到清单(确认单挂在那)由壳层做,勾选 + requestClean
    /// 在 `CleanerModel.selectAllAndRequestClean`。
    let onOneClickClean: () -> Void

    private var accent: Color {
        Surface.cleanAccent
    }

    var body: some View {
        // 进总览即取废纸篓读数(只为显示;fire-and-forget,后写覆盖)。
        content
            .frame(maxHeight: .infinity, alignment: .top)
            .task { model.refreshOverviewTrash() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
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
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .cardShell(compact: false)
        case .scanning:
            CardEmptyState(
                title: "正在扫描",
                detail: "扫描结束后这里给出可回收总量与各品类构成(进度在「空间地图」子页)"
            )
            .cardShell(compact: false)
        case .finished:
            overviewScroll
        }
    }

    private var overviewScroll: some View {
        let overview = model.junkOverview
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if overview.isEmpty {
                    CardEmptyState(
                        title: "白名单没有识别出可回收项",
                        detail: "只显示担保过的目录(ADR-0008);这台机器的开发工具与应用缓存已经干净"
                    )
                    .cardShell(compact: false)
                    // 空清单时废纸篓卡独占一行(网格里孤卡半宽反而失衡)。
                    OverviewTrashCard(
                        inventory: model.overviewTrash,
                        busy: model.trashPhase != .idle,
                        onEmpty: { model.beginEmptyTrash() }
                    )
                } else {
                    OverviewHeroCard(
                        overview: overview,
                        trashBytes: model.overviewTrash?.totalBytes,
                        busy: isBusy,
                        onOneClickClean: onOneClickClean
                    )
                    OverviewCardGrid {
                        ForEach(overview.rows) { row in
                            OverviewModuleCard(row: row) {
                                onDrill(row.group)
                            }
                        }
                        OverviewTrashCard(
                            inventory: model.overviewTrash,
                            busy: model.trashPhase != .idle,
                            onEmpty: { model.beginEmptyTrash() }
                        )
                    }
                }
                Text("点模块卡进入对应清单(与「全部清单」子页同源,勾选跨页保持);大小按实际占用口径,构成条 = 可安全清理 / 先检查 / 在用保护。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(.vertical, 2)
        }
        .defaultScrollAnchor(.top)
    }

    private var isBusy: Bool {
        if case .running = model.cleanPhase {
            return true
        }
        return false
    }
}

// MARK: - Hero 卡

/// Hero 卡(丙案 v2):可回收总量大数字 + 三段构成条 + 图例(含废纸篓)+ 一键清理主按钮。
private struct OverviewHeroCard: View {
    let overview: JunkOverview
    /// 废纸篓读数(nil = 尚未清点,图例如实写「—」)。
    let trashBytes: Int64?
    let busy: Bool
    let onOneClickClean: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                figureText(PulseFormat.memoryFigure(UInt64(max(0, overview.totalBytes))), size: FigureSize.main)
                caption
            }
            VStack(alignment: .leading, spacing: 7) {
                // 构成条:hero 高 8 圆角 4,inuse 段最小可见 2%(DESIGN.md 清理总览页)。
                CompositionBar(
                    safeBytes: overview.safeBytes,
                    checkBytes: overview.checkBytes,
                    inUseBytes: overview.inUseBytes,
                    height: 8,
                    cornerRadius: 4,
                    minInUseFraction: 0.02
                )
                legend
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onOneClickClean()
            } label: {
                Text("一键清理 \(PulseFormat.memory(UInt64(max(0, overview.safeBytes)))) 安全项…")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Surface.cleanAccent)
            .disabled(overview.safeBytes <= 0 || busy)
            .help("勾选全部「可安全清理」且不在用的项,并弹确认单——「先检查」与在用保护项永不在内")
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .background(Surface.card, in: .rect(cornerRadius: 18, style: .continuous))
    }

    /// 大数字(figure 族唯一实现 FigureText;hero 取既有最大档 44)。
    private func figureText(_ figure: (value: String, unit: String), size: CGFloat) -> some View {
        FigureText(value: figure.value, unit: figure.unit, size: size)
    }

    private var caption: some View {
        Text("可回收 · 其中 ")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            + Text(PulseFormat.memory(UInt64(max(0, overview.safeBytes))))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Surface.positive)
            + Text(" 可放心清")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    /// 图例(11):三段 + 废纸篓(磁盘金色块,读数未清点时如实「—」)。
    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("可安全清理 \(bytesText(overview.safeBytes))", tint: Surface.positive)
            legendItem("先检查 \(bytesText(overview.checkBytes))", tint: Surface.caution)
            legendItem("在用保护 \(bytesText(overview.inUseBytes))", tint: Surface.inkTertiary)
            legendItem(
                "另有废纸篓 \(trashBytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—")",
                tint: JunkTrashIdentity.color
            )
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legendItem(_ text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    private func bytesText(_ bytes: Int64) -> String {
        PulseFormat.memory(UInt64(max(0, bytes)))
    }
}

// MARK: - 模块大卡

/// 模块大卡:图标瓦 42 + 类名 17 bold + 一句人话 + 24pt 大数字 + 构成条 + 图例 +
/// 最大一项行 + chevron;整卡可点 = 下钻(行内数值全走 DESIGN.md 令牌)。
private struct OverviewModuleCard: View {
    let row: JunkOverviewGroupRow
    let onDrill: () -> Void

    var body: some View {
        Button(action: onDrill) {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                CompositionBar(
                    safeBytes: row.safeBytes,
                    checkBytes: row.checkBytes,
                    inUseBytes: row.inUseBytes,
                    height: 7,
                    cornerRadius: 3.5,
                    minInUseFraction: 0.03
                )
                legendRow
                Divider().padding(.top, 0)
                largestRow
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardShell(compact: false)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("查看「\(row.group.title)」清单")
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            CategoryIconTile(
                symbolName: row.group.overviewSymbolName,
                color: row.group.identityColor,
                size: 42
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(row.group.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Text(row.group.overviewTagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            let figure = PulseFormat.memoryFigure(UInt64(max(0, row.totalBytes)))
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.card)
        }
    }

    /// 图例(11):先检查 / 在用只在 >0 时显(空段不画,原型同款);N 项无色块。
    private var legendRow: some View {
        HStack(spacing: 14) {
            legendItem("可安全清理 \(bytesText(row.safeBytes))", tint: Surface.positive, swatch: 7)
            if row.checkBytes > 0 {
                legendItem("先检查 \(bytesText(row.checkBytes))", tint: Surface.caution, swatch: 7)
            }
            if row.inUseBytes > 0 {
                legendItem("在用 \(bytesText(row.inUseBytes))", tint: Surface.inkTertiary, swatch: 7)
            }
            Text("\(row.itemCount) 项")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legendItem(_ text: String, tint: Color, swatch: CGFloat) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: swatch, height: swatch)
            Text(text)
        }
    }

    private var largestRow: some View {
        HStack(spacing: 6) {
            Text("最大一项:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(row.largestTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("· \(bytesText(row.largestBytes))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func bytesText(_ bytes: Int64) -> String {
        PulseFormat.memory(UInt64(max(0, bytes)))
    }
}

// MARK: - 废纸篓卡(变体:读数 + 独立按钮,点卡不下钻)

private struct OverviewTrashCard: View {
    /// nil = 尚未清点(进总览页现取,通常亚秒)。
    let inventory: TrashInventory?
    /// inventorying / running 期间禁用(与原页头按钮同口径)。
    let busy: Bool
    let onEmpty: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            metaRow
            Divider()
            actionRow
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardShell(compact: false)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            CategoryIconTile(
                symbolName: JunkTrashCardCopy.symbolName,
                color: JunkTrashIdentity.color,
                size: 42
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(JunkTrashCardCopy.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Text(JunkTrashCardCopy.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let inventory {
                let figure = PulseFormat.memoryFigure(UInt64(max(0, inventory.totalBytes)))
                FigureText(value: figure.value, unit: figure.unit, size: FigureSize.card)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .help("正在清点废纸篓…")
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(JunkTrashIdentity.color)
                    .frame(width: 7, height: 7)
                Text(inventory.map { "\($0.totalItems) 项" } ?? "正在清点…")
            }
            if let inventory, inventory.volumes.filter({ $0.items > 0 }).count > 1 {
                Text("所有卷汇总")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var actionRow: some View {
        HStack {
            Text("不进勾选与一键清理,单独走二次确认")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                onEmpty()
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("清空废纸篓…")
                }
            }
            .controlSize(.large)
            .disabled(busy)
            .help("清空所有卷的废纸篓(永久删除,不可恢复)——腾出它占着的空间")
        }
    }
}

// MARK: - 构成条(Hero 与模块大卡共用)

/// 三段构成条(safe positive / check caution / inuse inkTertiary,互斥切分、合计恒满宽):
/// 空段不画;inuse > 0 时保最小可见宽(条不因占比过小而消失),其余两段按余量分摊。
private struct CompositionBar: View {
    let safeBytes: Int64
    let checkBytes: Int64
    let inUseBytes: Int64
    let height: CGFloat
    let cornerRadius: CGFloat
    /// inuse 段最小可见宽(hero 2% / 卡 3%,DESIGN.md 清理总览页)。
    let minInUseFraction: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                if total > 0 {
                    let inUseWidth = inUseBytes > 0
                        ? max(width * minInUseFraction, width * Double(inUseBytes) / Double(total))
                        : 0
                    let rest = width - inUseWidth
                    let restTotal = safeBytes + checkBytes
                    Rectangle()
                        .fill(Surface.positive)
                        .frame(width: restTotal > 0 ? rest * Double(safeBytes) / Double(restTotal) : 0)
                    Rectangle()
                        .fill(Surface.caution)
                        .frame(width: restTotal > 0 ? rest * Double(checkBytes) / Double(restTotal) : 0)
                    if inUseBytes > 0 {
                        Rectangle()
                            .fill(Surface.inkTertiary)
                            .frame(width: inUseWidth)
                    }
                }
            }
            .frame(width: width, height: height, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: height)
        .background(Surface.cardHigh, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true) // 占比信息由图例文字承载,条本身按装饰处理
    }

    private var total: Int64 {
        safeBytes + checkBytes + inUseBytes
    }
}

// MARK: - 2 列自适应网格({layout.module-card-min-width})

private enum OverviewCardGridMetrics {
    /// 单卡最小宽(DESIGN.md `{layout.module-card-min-width}`)。
    static let minimumCardWidth: CGFloat = 340
    /// 列距 = {spacing.group-gap}(原型 grid gap 12)。
    static let spacing: CGFloat = 12
    static let maximumColumns = 2
}

/// 模块大卡网格:列数 = min(2, 内容宽容纳列数)——720 最小窗 1 列、默认窗 2 列、
/// 上限 2(品类只有六卡,不随 ultrawide 拉列)。宽度经 onGeometryChange 读取,
/// 只在跨档时改状态(`AdaptiveCardGrid` 同法)。
private struct OverviewCardGrid<Card: View>: View {
    @State private var columnCount = 2
    @ViewBuilder let cards: () -> Card

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: OverviewCardGridMetrics.spacing),
                count: columnCount
            ),
            spacing: OverviewCardGridMetrics.spacing
        ) {
            cards()
        }
        .onGeometryChange(for: Int.self) { proxy in
            let perColumn = OverviewCardGridMetrics.minimumCardWidth + OverviewCardGridMetrics.spacing
            let fitted = Int((proxy.size.width + OverviewCardGridMetrics.spacing) / perColumn)
            return min(OverviewCardGridMetrics.maximumColumns, max(1, fitted))
        } action: { newValue in
            if newValue != columnCount {
                columnCount = newValue
            }
        }
    }
}
