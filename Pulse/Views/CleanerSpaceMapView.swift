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

    @State private var notice: String?
    @State private var hoveredRectIndex: Int?

    private var accent: Color {
        Metric.disk.accentColor
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
                treemapBody(rects: rects, tree: tree)
            }
        }
        .cardShell(compact: false)
    }

    // MARK: Canvas treemap(单次 draw call)

    private func treemapBody(rects: [TreemapRect], tree: SpaceMapNode) -> some View {
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
                                Text(pct).font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(textColor.opacity(0.8)),
                                at: CGPoint(x: rect.minX + 6, y: rect.maxY - 4),
                                anchor: .bottomLeading
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
