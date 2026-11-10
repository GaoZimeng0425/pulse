import PulseCore
import SwiftUI

// MARK: - 清理总览子页(p6-cleaner/03,丙案 v2):Hero + 七模块大卡 + 废纸篓卡

//
// 数据面全部来自 PulseCore 纯值:`JunkOverviewAggregator.overview`(Hero 与模块卡)、
// `TrashInventory`(废纸篓读数)、`JunkOverviewAggregator.safeAutoSelection`(一键清理,
// 经 CleanerModel.selectAllSafeAndRequestClean 落勾选并弹既有确认单)。本文件只描边配色;
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
    /// 在 `CleanerModel.selectAllSafeAndRequestClean`。
    let onOneClickClean: () -> Void

    private var accent: Color {
        Surface.cleanAccent
    }

    var body: some View {
        // 进总览只走自动入口:门卫放行(清点读成功过)才刷新废纸篓读数。首次读数
        // 归废纸篓卡的显式「清点」——枚举外置卷可能弹授权,弹窗不许出现在可见性
        // 切换上(CODING_STANDARDS 权限纪律)。
        content
            .frame(maxHeight: .infinity, alignment: .top)
            .task { model.refreshOverviewTrashIfUnlocked() }
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
                    trashCard
                } else {
                    OverviewHeroCard(
                        overview: overview,
                        trashBytes: model.overviewTrash?.totalBytes,
                        busy: isBusy,
                        onOneClickClean: onOneClickClean
                    )
                    AdaptiveCardGrid(
                        minimumCardWidth: OverviewCardGridMetrics.minimumCardWidth,
                        spacing: OverviewCardGridMetrics.spacing,
                        maximumColumns: OverviewCardGridMetrics.maximumColumns
                    ) {
                        ForEach(overview.rows) { row in
                            OverviewModuleCard(row: row) {
                                onDrill(row.group)
                            }
                        }
                        trashCard
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

    /// 废纸篓卡(空清单独占一行 / 网格末位两处同一装配)。两个动作都是用户点击,
    /// 清点与清空前的清点都只在这里发起。
    private var trashCard: some View {
        OverviewTrashCard(
            phase: model.overviewTrashPhase,
            busy: model.trashPhase != .idle,
            onCount: { model.refreshOverviewTrash() },
            onEmpty: { model.beginEmptyTrash() }
        )
    }
}

// MARK: - 图例(Hero / 模块大卡 / 废纸篓卡共用)

/// 总览图例的尺寸单出处(DESIGN.md §Components「清理总览页·图例」;p6-review-fixes:
/// 此前三处各写一份,色块 8×8 r2.5 / 7×7 r2、块字距 5 / 4、项间 14 互相漂移)。
private enum OverviewLegendMetrics {
    /// 色块边长 / 圆角(DESIGN.md Hero 图例既有值 8×8 圆角 2.5,三处统一到它)。
    static let swatchSize: CGFloat = 8
    static let swatchCornerRadius: CGFloat = 2.5
    /// 色块-文字间距 = {spacing.unit}。
    static let swatchTextSpacing: CGFloat = 4
    /// 图例项之间 = {spacing.group-gap}。
    static let itemSpacing: CGFloat = 12
}

/// 图例项:色块 + 文字(字号 / 颜色 / 等宽数字由所在图例行统一给)。
private struct OverviewLegendItem: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: OverviewLegendMetrics.swatchTextSpacing) {
            RoundedRectangle(cornerRadius: OverviewLegendMetrics.swatchCornerRadius, style: .continuous)
                .fill(tint)
                .frame(width: OverviewLegendMetrics.swatchSize, height: OverviewLegendMetrics.swatchSize)
            Text(text)
        }
    }
}

// MARK: - Hero 卡

/// Hero 卡(丙案 v2):可回收总量大数字 + 三段构成条 + 图例(含废纸篓)+ 一键清理主按钮。
private struct OverviewHeroCard: View {
    let overview: JunkOverview
    /// 废纸篓读数(nil = 没查 / 读不到,图例如实写「—」,不写 0)。
    let trashBytes: Int64?
    let busy: Bool
    let onOneClickClean: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                figureText(PulseFormat.memoryFigure(UInt64(max(0, overview.totalBytes))), size: FigureSize.main)
                caption
            }
            VStack(alignment: .leading, spacing: 8) {
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
        // 内距 24×28 随版式(DESIGN.md Hero 条目);卡壳走零件(padded: false 只给
        // 底色圆角,圆角令牌 CardMetrics.cornerRadius——不再手写 18)。
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .cardShell(compact: false, padded: false)
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

    /// 图例(11):三段 + 废纸篓(磁盘金色块,读数没查 / 读不到时如实「—」)。
    private var legend: some View {
        HStack(spacing: OverviewLegendMetrics.itemSpacing) {
            OverviewLegendItem(text: "可安全清理 \(bytesText(overview.safeBytes))", tint: Surface.positive)
            OverviewLegendItem(text: "先检查 \(bytesText(overview.checkBytes))", tint: Surface.caution)
            OverviewLegendItem(text: "在用保护 \(bytesText(overview.inUseBytes))", tint: Surface.inkTertiary)
            OverviewLegendItem(
                text: "另有废纸篓 \(trashBytes.map { PulseFormat.memory(UInt64(max(0, $0))) } ?? "—")",
                tint: JunkTrashIdentity.color
            )
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
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

    /// 图例(11,统一配方 OverviewLegendItem):先检查 / 在用只在 >0 时显(空段
    /// 不画,原型同款);N 项无色块。
    private var legendRow: some View {
        HStack(spacing: OverviewLegendMetrics.itemSpacing) {
            OverviewLegendItem(text: "可安全清理 \(bytesText(row.safeBytes))", tint: Surface.positive)
            if row.checkBytes > 0 {
                OverviewLegendItem(text: "先检查 \(bytesText(row.checkBytes))", tint: Surface.caution)
            }
            if row.inUseBytes > 0 {
                OverviewLegendItem(text: "在用 \(bytesText(row.inUseBytes))", tint: Surface.inkTertiary)
            }
            Text("\(row.itemCount) 项")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
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
    /// 读数状态:没查 / 清点中 / 读不到 / 查到了。「读不到」绝不是空或 0——
    /// 没查与读不到都走占位,数字只在查到了(或刷新在飞时的上次读数)出现。
    let phase: CleanerModel.OverviewTrashPhase
    /// inventorying / running 期间禁用(与原页头按钮同口径)。
    let busy: Bool
    /// 显式清点(用户动作——授权弹窗只许出现在这一下点击)。
    let onCount: () -> Void
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
            readingSlot
        }
    }

    /// 读数位:有读数给 24 档大数字;没读数时按状态给转圈或显式「清点」入口
    /// (授权型能力动作 = CardEmptyState 同款 11pt `.link`,系统授权弹窗只出现在
    /// 这一下点击;读不到不出数字,也不出 0)。
    @ViewBuilder private var readingSlot: some View {
        if let reading = phase.reading {
            let figure = PulseFormat.memoryFigure(UInt64(max(0, reading.totalBytes)))
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.card)
        } else if case .counting = phase {
            ProgressView()
                .controlSize(.small)
                .help("正在清点废纸篓…")
        } else {
            Button(phase == .failed ? "重试清点" : "清点废纸篓", action: onCount)
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(busy)
                .help("清点各卷废纸篓的占用(外置宗卷可能弹出访问授权)")
        }
    }

    private var metaRow: some View {
        HStack(spacing: OverviewLegendMetrics.itemSpacing) {
            OverviewLegendItem(text: metaText, tint: JunkTrashIdentity.color)
            if let reading = phase.reading,
               reading.volumes.filter({ $0.items > 0 }).count > 1 {
                Text("所有卷汇总")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    /// 读数副文:查到了「N 项」;没查 / 清点中 / 读不到如实说,不编数字。
    private var metaText: String {
        switch phase {
        case let .counted(inventory): "\(inventory.totalItems) 项"
        case let .counting(lastGood): lastGood.map { "\($0.totalItems) 项" } ?? "正在清点…"
        case .failed: "读不到(权限不足或宗卷不可用)"
        case .notCounted: "尚未清点"
        }
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
