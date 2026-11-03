import PulseCore
import SwiftUI

// MARK: - 空间地图(p4-cleaner/07 v2:Canvas 分层条形图)

//
// 用户拍板(2026-11-03):「不要扇形了,非常的卡顿」。
// 替换:单个 Canvas 一次 draw call 渲染全部条形(GPU 加速,零卡顿);
// 命中 = y 坐标反算(不依赖 SwiftUI 形状 hit test);
// 交互不变:点行下钻 / 面包屑返回 / 悬浮信息 / 密封块解释 / Finder 跳转 / v1 只读。

/// 内环配色:十个既有 accent 令牌按序循环;密封 = inkTertiary 灰;其他 = cardHigh。
private let barColors: [Color] = [
    Metric.cpu, .memory, .network, .battery, .gpu,
    .sensors, .sound, .bluetooth, .containers, .disk,
].map(\.accentColor)

/// 条形图高度(所有行共享;行高 = fraction × 此值)。
private let chartHeight: CGFloat = 320

struct SpaceMapSection: View {
    let model: CleanerModel
    @Binding var drillPath: String?
    @Binding var treeIndex: Int

    @State private var notice: String?
    @State private var hoveredBarIndex: Int?

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
        let bars = SpaceMapBarLayout.layout(root: root)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "chart.bar.doc.horizontal", title: "空间地图", tint: accent) {
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
            if bars.isEmpty {
                Text("此目录下没有子目录(文件已聚合进大小)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            } else {
                barChart(bars: bars, root: root, tree: tree)
            }
        }
        .cardShell(compact: false)
    }

    // MARK: Canvas 条形图(单次 draw call)

    private func barChart(bars: [SpaceMapBar], root: SpaceMapNode, tree: SpaceMapNode) -> some View {
        Canvas { context, size in
            for (index, bar) in bars.enumerated() {
                let y = bar.y * size.height
                let h = max(bar.height * size.height - 2, 4) // 2pt 间隙,最小 4pt
                let rect = CGRect(x: 0, y: y, width: size.width, height: h)
                let color = barColor(bar.node, index: index)
                let isHovered = hoveredBarIndex == index

                // 填充
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 6),
                    with: .color(color.opacity(isHovered ? 0.85 : bar.node.isSealed ? 0.55 : 0.7))
                )

                // 文字(行高够才画)
                if h >= 22 {
                    let label = "\(bar.node.name)  \(PulseFormat.memory(UInt64(max(0, bar.node.bytes))))"
                    let pct = String(format: "%.1f%%", bar.height * 100)
                    drawLabel(
                        &context, text: label, pct: pct,
                        in: rect, color: color, isSealed: bar.node.isSealed
                    )
                }
            }
        }
        .frame(height: chartHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { location in
            handleTap(atBar: hitBar(bars: bars, at: location), root: root, tree: tree)
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                hoveredBarIndex = hitBarIndex(bars: bars, at: location)
            case .ended:
                hoveredBarIndex = nil
            }
        }
    }

    // MARK: 命中(y 坐标反算,不依赖形状 hit test)

    private func hitBar(bars: [SpaceMapBar], at point: CGPoint) -> SpaceMapBar? {
        let normalizedY = point.y / chartHeight
        return bars.first { normalizedY >= $0.y && normalizedY < $0.y + $0.height }
    }

    private func hitBarIndex(bars: [SpaceMapBar], at point: CGPoint) -> Int? {
        let normalizedY = point.y / chartHeight
        return bars.firstIndex { normalizedY >= $0.y && normalizedY < $0.y + $0.height }
    }

    // MARK: 交互

    private func handleTap(atBar bar: SpaceMapBar?, root: SpaceMapNode, tree: SpaceMapNode) {
        guard let bar else { return }
        let node = bar.node
        if node.isSealed {
            notice = "系统密封区:macOS 只读系统文件,不可删除也不可下钻。清理请去「开发者垃圾」——那里只列白名单担保过的目录。"
            return
        }
        if node.isAggregate {
            notice = "「其他」= \(node.mergedCount) 个小于显示阈值的目录合并(单行太矮看不清);进入上一层的目录可见完整子项。"
            return
        }
        if node.children.isEmpty {
            notice = "「\(node.name)」下面没有更深的目录了——文件已聚合进这一块的大小。"
            return
        }
        notice = nil
        drillPath = node.path == tree.path ? nil : node.path
    }

    private func goUp(in tree: SpaceMapNode) {
        notice = nil
        guard let current = drillPath else { return }
        let parent = (current as NSString).deletingLastPathComponent
        drillPath = parent == tree.path || parent.isEmpty ? nil : parent
    }

    private func resolveDrill(in tree: SpaceMapNode) -> SpaceMapNode {
        guard let drillPath, let node = tree.descendant(atPath: drillPath) else { return tree }
        return node
    }

    // MARK: 绘制辅助

    private func barColor(_ node: SpaceMapNode, index: Int) -> Color {
        if node.isSealed {
            return Surface.inkTertiary
        }
        if node.isAggregate {
            return Surface.cardHigh
        }
        return barColors[index % barColors.count]
    }

    private func drawLabel(
        _ context: inout GraphicsContext,
        text: String,
        pct: String,
        in rect: CGRect,
        color: Color,
        isSealed: Bool
    ) {
        let textColor: Color = isSealed ? .primary : .white
        let font = Font.system(size: 11, weight: .medium)
        // 名字 + 大小(左)
        context.draw(
            Text(text).font(font).foregroundColor(textColor),
            at: CGPoint(x: rect.minX + 10, y: rect.midY),
            anchor: .leading
        )
        // 百分比(右)
        context.draw(
            Text(pct).font(.system(size: 10, design: .monospaced)).foregroundColor(textColor.opacity(0.8)),
            at: CGPoint(x: rect.maxX - 10, y: rect.midY),
            anchor: .trailing
        )
    }

    // MARK: 面包屑(逐级可跳)

    private func breadcrumbRow(_ tree: SpaceMapNode) -> some View {
        let chain = SpaceMapNode.breadcrumb(to: drillPath ?? tree.path, in: tree) ?? [tree]
        return HStack(spacing: 4) {
            ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Text("›").foregroundStyle(.tertiary)
                }
                if index == chain.count - 1 {
                    Text(node.name)
                        .font(.system(size: 11, weight: .semibold))
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
                Button("回到整卷") {
                    notice = nil
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
        .onChange(of: treeIndex) { _, _ in
            drillPath = nil
        }
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
