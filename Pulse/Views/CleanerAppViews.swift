import PulseCore
import SwiftUI

// 应用子页清单(AppListSection)——solid-split 后本文件只留清单主体。

// MARK: - 应用子页(p4-uninstaller/01 清单 + 02 残留信任 / 排序搜索 / 选中交互)

//
// 交互口径(2026-11-04 原型裁决,存档 prototype/uninstaller-ui):
// 点行任意处 = 选中 app 本体(checkbox 语义、行高亮、再点取消;灰行点不选中);
// 点行尾箭头 = 展开残留清单(人话副标 + 「删了会怎样」,默认不勾,「全选残留」
// 不收「先检查」项);选中态与展开态相互独立。
// 「彻底删除」勾选与「卸载」按钮随票 03 一起上——不上没有执行后果的半截交互。
// 无 bundle id 的 app:不探测残留,展开只给「未识别,不敢猜」标注(Q4)。

struct AppListSection: View {
    let model: UninstallModel
    @State private var expanded: Set<String> = []

    private var accent: Color {
        Surface.cleanAccent
    }

    var body: some View {
        @Bindable var model = model
        // 卡头只在 content(完成态大卡)里出一次;装载/空态不带卡头(与垃圾/地图的
        // 扫描态/空态同款)。曾因页层 header 与卡内 header 并存出现双层标题
        // (2026-11-09 用户实报),此为修复。
        return VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle, .collecting:
                loadingView(text: "正在收集应用清单…")
            case let .sizing(entries):
                loadingView(text: "正在统计占用 · 已扫描 \(entries) 项")
            case .finished:
                content
            }
        }
        // 进子页空态才自动扫(已有清单不重复烧);切走取消(无常驻采集,spec)。
        .task { model.loadIfNeeded() }
        .onDisappear { model.cancel() }
    }

    // MARK: 头部

    /// 卡头(四子页统一形态,2026-11-09 用户实报收编:可清理/空间地图 = 大卡 +
    /// CardHeader,应用/历史跟齐):清理页强调色 + 右侧汇总与刷新。
    private var header: some View {
        CardHeader(symbolName: "square.grid.2x2", title: "应用", tint: accent) {
            HStack(spacing: 8) {
                if let output = model.output {
                    Text(summaryText(output))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: IconSize.inline))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("重新收集(签名、brew 徽标、运行态都可能已变化)")
            }
        }
    }

    private func summaryText(_ output: AppCatalogOutput) -> String {
        var text = "共 \(output.entries.count) 个应用"
        if output.ledger.excludedAppleSigned > 0 {
            text += " · 已隐藏 \(output.ledger.excludedAppleSigned) 个 Apple 系统应用"
        }
        if output.ledger.excludedUnverifiableSignature > 0 {
            text += " · \(output.ledger.excludedUnverifiableSignature) 个签名无法验证未列出"
        }
        return text
    }

    // MARK: 清单

    private var content: some View {
        let entries = model.displayedEntries
        return Group {
            if entries.isEmpty {
                emptyView
            } else {
                // 四子页统一形态(2026-11-09):一张大卡 + CardHeader,banner / 控件条 /
                // 条目小卡全部进卡(垃圾页同构);条目小卡与展开=卡内裸行保留。
                VStack(alignment: .leading, spacing: 8) {
                    header
                    uninstallBanner
                    if model.uninstallPhase == .running {
                        runningBanner
                    }
                    controlsBar
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(entries) { entry in
                                appCard(entry, leader: entries.compactMap(\.sizeBytes).max() ?? 0)
                            }
                        }
                    }
                    // 2026-11-08 实报:清单短于视口时 ScrollView 默认把内容悬中——锚顶。
                    .defaultScrollAnchor(.top)
                    .frame(minHeight: 120, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .cardShell(compact: false)
            }
        }
        .sheet(isPresented: uninstallSheetPresented) {
            if case let .confirming(plan) = model.uninstallPhase {
                AppUninstallConfirmSheet(plan: plan) {
                    model.confirmUninstall()
                } onCancel: {
                    model.cancelUninstall()
                }
            }
        }
        .alert("这个应用由 Homebrew 安装", isPresented: rerouteAlertPresented) {
            Button("取消", role: .cancel) { model.cancelUninstall() }
            Button("仍要直接删文件(绕过 Homebrew)", role: .destructive) { model.proceedAfterReroute() }
        } message: {
            if case let .reroute(_, cask) = model.uninstallPhase {
                Text("建议让 Homebrew 卸载(\(cask))以保持安装记录一致——取消后此应用会带 brew 徽标,用 brew 卸载即可。")
            }
        }
    }

    /// 应用条目小卡:头排(AppRow)+ 展开的残留区同卡收拢(与项目大卡同构),
    /// card-hi 抬升底、12 圆角,选中 = 强调色 12% 染底——垃圾条目同配方。
    private func appCard(_ entry: UninstallAppEntry, leader: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AppRow(
                entry: entry,
                leader: leader,
                isSelected: model.isSelected(entry),
                isExpanded: expanded.contains(entry.path),
                onToggleSelect: { model.toggleSelect(entry) },
                onToggleExpand: { toggleExpand(entry) }
            )
            if expanded.contains(entry.path) {
                LeftoverDisclosure(model: model, entry: entry)
            }
        }
        .background(
            model.isSelected(entry) ? Surface.cleanAccent.opacity(0.12) : Surface.cardHigh,
            in: .rect(cornerRadius: 12)
        )
    }

    private var uninstallSheetPresented: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = model.uninstallPhase {
                    true
                } else {
                    false
                }
            },
            set: { presented in
                if !presented {
                    model.cancelUninstall()
                }
            }
        )
    }

    private var rerouteAlertPresented: Binding<Bool> {
        Binding(
            get: {
                if case .reroute = model.uninstallPhase {
                    true
                } else {
                    false
                }
            },
            set: { presented in
                if !presented {
                    model.cancelUninstall()
                }
            }
        )
    }

    /// 完成横幅(Q10:页内,不发系统通知)/ 中止红字;关闭回空态。
    @ViewBuilder
    private var uninstallBanner: some View {
        switch model.uninstallPhase {
        case let .finished(report):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Surface.positive)
                Text(finishedText(report))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    model.dismissUninstallBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(10)
            .background(Surface.positive.opacity(0.1), in: .rect(cornerRadius: 10))
        case let .aborted(reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Surface.negative)
                Text(reason)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(3)
                Spacer()
                Button {
                    model.dismissUninstallBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(10)
            .background(Surface.negative.opacity(0.1), in: .rect(cornerRadius: 10))
        default:
            EmptyView()
        }
    }

    private func finishedText(_ report: CleanRunReport) -> String {
        var text = "已处理 \(report.items.filter(\.isReleased).count) 项"
        if report.recycled.count > 0 {
            text += "(移入废纸篓 \(report.recycled.count)"
        }
        if report.permanentItems.count > 0 {
            text += report.recycled.count > 0 ? " · 永久删除 \(report.permanentItems.count)" : "(永久删除 \(report.permanentItems.count)"
        }
        if report.recycled.count > 0 || report.permanentItems.count > 0 {
            text += " · 释放 \(PulseFormat.memory(UInt64(max(0, report.freedBytes))))"
        }
        if report.failed.count > 0 {
            text += ",失败 \(report.failed.count) 项"
        }
        return text + ")"
    }

    private var runningBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在卸载…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 10))
    }

    /// 搜索 + 排序 + 操作提示(Q5:默认占用降序,可切按名;子页内过滤)。
    /// 搜索框(agent-tab/08 改):11-08 换的系统 roundedBorder 输入框实测画出
    /// 26pt(边框画在框外)vs 分段控件 24pt,且内嵌放大镜被原生框底盖住看不见
    /// ——用户实报「input 高度不对,没和右侧切换对齐」。改走工具栏搜索框
    /// (`MainSearchField`)同配方:放大镜 + 无边框输入 + primary 6% 底,
    /// **定高 24 = 分段控件 regular 实测高**,圆角 7 与分段轨道同形。
    private var controlsBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            CleanerSearchField(prompt: "搜索应用", text: $model.searchQuery)
                .frame(width: 220)

            Picker("排序", selection: $model.sortOrder) {
                Text("占用").tag(AppSortOrder.sizeDescending)
                Text("名称").tag(AppSortOrder.name)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tint(accent)
            .help("默认按 .app 实际占用降序(与空间地图同口径)")

            Spacer(minLength: 8)
            Text("点行选中 · 箭头看残留")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func toggleExpand(_ entry: UninstallAppEntry) {
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            model.onExpand(entry) // 彻底删除勾选重置 + 残留按需探测
        }
    }

    private var emptyView: some View {
        // 空态统一走 CardEmptyState + 卡壳(DESIGN.md 卡片家族,不手写空态)。
        CardEmptyState(
            title: model.searchQuery.isEmpty ? "未发现可卸载的应用" : "没有匹配的应用",
            detail: model.searchQuery.isEmpty ? "扫描完成后,可卸载的应用会列在这里" : "清空搜索或换个关键词"
        )
        .cardShell(compact: false)
    }

    private func loadingView(text: String) -> some View {
        // 装载态与垃圾/地图的扫描态同款:CardEmptyState + 卡壳,不再自绘横条卡。
        CardEmptyState(title: text)
            .cardShell(compact: false)
    }
}
