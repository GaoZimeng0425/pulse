import PulseCore
import SwiftUI

// MARK: - 空间地图(p4-cleaner/07 v3:Canvas treemap,用户拍板)

//
// 旭日图(Shape 逐弧,卡顿+命中不可靠)→ 条形图(过渡)→ treemap(用户选定)。
// 单个 Canvas 一次 draw call;命中 = rect.contains(归一化点)。
// 交互:点块下钻 / 面包屑返回 / 密封块解释 / Finder / v1 只读。

private let treemapColors: [Color] = [
    Metric.cpu, .memory, .network, .battery, .gpu,
    .sensors, .sound, .bluetooth, .containers, .disk,
].map(\.accentColor)

/// treemap 高度。
private let chartHeight: CGFloat = 340

struct SpaceMapSection: View {
    let model: CleanerModel
    @Binding var drillPath: String?
    @Binding var treeIndex: Int
    /// 命中白名单的块「去清理清单」动作(壳层切子药丸 + 定位组)。
    let onGoToJunk: (JunkGroup) -> Void

    @State private var notice: String?
    @State private var hoveredRectIndex: Int?

    private var accent: Color {
        Surface.cleanAccent
    }

    var body: some View {
        if let tree {
            mapCard(tree)
        } else {
            CardEmptyState(
                title: "本次扫描没有产出空间树",
                detail: "扫描开始后很快被取消——重新扫描即可",
                actionTitle: "重新扫描",
                action: { model.startScan() }
            )
            .cardShell(compact: false)
        }
    }

    private var tree: SpaceMapNode? {
        let trees = model.mapTrees
        guard !trees.isEmpty else { return nil }
        return trees[min(max(treeIndex, 0), trees.count - 1)]
    }

    // MARK: 卡片

    private func mapCard(_ tree: SpaceMapNode) -> some View {
        let root = resolveDrill(in: tree)
        let rects = TreemapLayout.layout(root: root)
        // 角标判定预计算一次(与 rects 同源);Canvas 里只查表,hover 重绘零重算。
        // 只命中非密封非合并块——密封区不可删、「其他」是合成块,都零暗示(ADR-0008)。
        // 判定 = 白名单规则表 ∪ 本次卸载残留候选(p5-cleaner/02;与清单同源同家目录)。
        let resolve = model.mapCleanableResolver()
        let cleanable: [JunkGroup?] = rects.map { rect in
            guard !rect.node.isSealed, !rect.node.isAggregate else { return nil }
            return resolve(rect.node.path)
        }
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "square.grid.3x3.square", title: "空间地图", tint: accent) {
                Button("在 Finder 中显示") { reveal(root) }
                    .controlSize(.small)
            }
            if model.mapTrees.count > 1 {
                rootPicker
            }
            breadcrumbRow(tree)
            if let notice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if rects.isEmpty {
                Text("此目录下没有子目录(文件已聚合进大小)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            } else {
                hoverInfoRow(rects: rects, cleanable: cleanable)
                treemapBody(rects: rects, tree: tree, cleanable: cleanable)
            }
        }
        .cardShell(compact: false)
    }

    // MARK: Canvas treemap(单次 draw call)

    private func treemapBody(rects: [TreemapRect], tree: SpaceMapNode, cleanable: [JunkGroup?]) -> some View {
        GeometryReader { geo in
            Canvas { context, size in
                for (index, tr) in rects.enumerated() {
                    let rect = CGRect(
                        x: tr.rect.minX * size.width + 1,
                        y: tr.rect.minY * size.height + 1,
                        width: tr.rect.width * size.width - 2,
                        height: tr.rect.height * size.height - 2
                    )
                    guard rect.width > 6, rect.height > 6 else { continue }

                    let color = rectColor(tr.node, index: index)
                    let isHovered = hoveredRectIndex == index

                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 5),
                        with: .color(color.opacity(isHovered ? 0.9 : tr.node.isSealed ? 0.5 : 0.75))
                    )

                    if rect.width > 48, rect.height > 16 {
                        let name = tr.node.name
                        let sz = PulseFormat.memory(UInt64(max(0, tr.node.bytes)))
                        let pct = String(format: "%.1f%%", tr.rect.width * tr.rect.height * 100)
                        let textColor: Color = tr.node.isSealed ? .primary : .white
                        let font = Font.system(size: min(11, rect.height / 2.2), weight: .medium)

                        context.draw(
                            Text("\(name)  \(sz)").font(font).foregroundColor(textColor),
                            at: CGPoint(x: rect.minX + 6, y: rect.minY + 4),
                            anchor: .topLeading
                        )
                        if rect.height > 32 {
                            context.draw(
                                Text(pct).font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(textColor.opacity(0.8)),
                                at: CGPoint(x: rect.minX + 6, y: rect.maxY - 4),
                                anchor: .bottomLeading
                            )
                        }
                    }

                    // 轻桥角标(p4-uninstaller/05):白名单命中块右上角「可清理」;
                    // 块太小画不下文字时退化为一个点——存在感保留,不给版面压力。
                    if cleanable.indices.contains(index), let group = cleanable[index] {
                        _ = group
                        if rect.width > 72, rect.height > 30 {
                            let badge = CGRect(x: rect.maxX - 42, y: rect.minY + 2.5, width: 38, height: 14)
                            context.fill(
                                Path(roundedRect: badge, cornerRadius: 7),
                                with: .color(Surface.cleanAccent.opacity(0.95))
                            )
                            context.draw(
                                Text("可清理").font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.white),
                                at: CGPoint(x: badge.midX, y: badge.midY),
                                anchor: .center
                            )
                        } else {
                            let dot = CGRect(x: rect.maxX - 9, y: rect.minY + 3, width: 5, height: 5)
                            context.fill(
                                Path(ellipseIn: dot),
                                with: .color(Surface.cleanAccent.opacity(0.95))
                            )
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(at: location, in: geo.size, rects: rects, tree: tree)
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoveredRectIndex = hitIndex(at: location, in: geo.size, rects: rects)
                case .ended:
                    hoveredRectIndex = nil
                }
            }
        }
        .frame(height: chartHeight)
    }

    // MARK: 命中

    private func hitIndex(at point: CGPoint, in size: CGSize, rects: [TreemapRect]) -> Int? {
        let p = CGPoint(x: point.x / size.width, y: point.y / size.height)
        return rects.firstIndex { $0.rect.contains(p) }
    }

    // MARK: 交互

    private func handleTap(at point: CGPoint, in size: CGSize, rects: [TreemapRect], tree: SpaceMapNode) {
        guard let index = hitIndex(at: point, in: size, rects: rects) else { return }
        let node = rects[index].node
        if node.isSealed {
            notice = "系统密封区:macOS 只读系统文件,不可删除也不可下钻。"
            return
        }
        if node.isAggregate {
            notice = "「其他」= \(node.mergedCount) 个小于显示阈值的目录合并。"
            return
        }
        if node.children.isEmpty {
            notice = "「\(node.name)」下面没有更深的目录了——文件已聚合进这一块的大小。"
            return
        }
        notice = nil
        drillPath = node.path == tree.path ? nil : node.path
    }

    private func resolveDrill(in tree: SpaceMapNode) -> SpaceMapNode {
        guard let drillPath, let node = tree.descendant(atPath: drillPath) else { return tree }
        return node
    }

    // MARK: 辅助

    private func rectColor(_ node: SpaceMapNode, index: Int) -> Color {
        if node.isSealed {
            return Surface.inkTertiary
        }
        if node.isAggregate {
            return Surface.cardHigh
        }
        return treemapColors[index % treemapColors.count]
    }

    /// hover 信息行(轻桥):路径 + 大小;白名单命中块给「去清理清单」跳转。
    /// 文案明示判定来源(清理白名单)与地图只读立场(checklist)。
    @ViewBuilder
    private func hoverInfoRow(rects: [TreemapRect], cleanable: [JunkGroup?]) -> some View {
        if let index = hoveredRectIndex, rects.indices.contains(index) {
            let node = rects[index].node
            HStack(spacing: 8) {
                Text(node.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.path)
                Spacer(minLength: 8)
                Text("\(PulseFormat.memory(UInt64(max(0, node.bytes)))) · \(node.name)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if cleanable.indices.contains(index), let group = cleanable[index] {
                    Button {
                        onGoToJunk(group)
                    } label: {
                        Label("这块能清", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Surface.cleanAccent)
                    .help(group == .uninstallLeftovers
                        ? "这块是卸载残留:命名它的 app 已不在已装应用清单(与开发者垃圾清单同源);地图本身只读——点击去开发者垃圾定位对应组"
                        : "能删的判定来自清理白名单(与开发者垃圾清单同源);地图本身只读——点击去开发者垃圾定位对应组")
                }
            }
        }
    }

    private func breadcrumbRow(_ tree: SpaceMapNode) -> some View {
        let chain = SpaceMapNode.breadcrumb(to: drillPath ?? tree.path, in: tree) ?? [tree]
        return HStack(spacing: 4) {
            ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Text("›").foregroundStyle(.tertiary)
                }
                if index == chain.count - 1 {
                    Text(node.name).font(.system(size: 11, weight: .semibold))
                } else {
                    Button(node.name) {
                        notice = nil
                        drillPath = node.path == tree.path ? nil : node.path
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            if drillPath != nil {
                Text("›").foregroundStyle(.tertiary)
                Button("回到整卷") { notice = nil
                    drillPath = nil
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var rootPicker: some View {
        Picker("扫描根", selection: $treeIndex) {
            ForEach(Array(model.mapTrees.enumerated()), id: \.offset) { index, tree in
                Text(tree.name).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: treeIndex) { _, _ in drillPath = nil }
    }

    private func reveal(_ node: SpaceMapNode) {
        let url = URL(fileURLWithPath: node.path)
        if node.path == "/" {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
