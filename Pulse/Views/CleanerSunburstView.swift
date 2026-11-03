import PulseCore
import SwiftUI

// MARK: - 空间地图(p4-cleaner/07):两环旭日(只读)+ 下钻 + 面包屑 + 悬浮

//
// 树变换与弧几何全部在 PulseCore(SpaceMap.swift);本文件只做描边、配色、命中
// 与交互。v1 只读(ADR-0008 的边界):地图上没有任何删除控件,唯一越界动作是
// 「在 Finder 中显示」。悬浮口径 = 名字 + 路径 + 实际占用 + 占整卷百分比(分母 =
// 整卷树,不是环内归一化)。弧与标签不做宽度/角度动画(meter 条同款纪律)。

/// 内环按序循环的既有 accent 令牌(DESIGN.md 色板;零新色),外环随父色;
/// 「其他」= {colors.surface-card-high}(环形"其他/空闲"段既有口径),密封块 =
/// {colors.inkTertiary}(缓存段既有口径)。
private let sunburstRingColors: [Color] = [
    Metric.cpu, .memory, .network, .battery, .gpu,
    .sensors, .sound, .bluetooth, .containers, .disk,
].map(\.accentColor)

struct SpaceMapSection: View {
    let model: CleanerModel
    /// 下钻位置(nil = 整卷)。由 CleanerTabView 持有——切子药丸再回来不丢。
    @Binding var drillPath: String?
    /// 多根(取消过早 / 测试注入)时当前展示哪棵。
    @Binding var treeIndex: Int

    @State private var notice: String?

    private var accent: Color {
        Metric.disk.accentColor
    }

    var body: some View {
        if let tree {
            mapCard(tree)
        } else {
            // finished 但树空:扫描在第一棵树完成前就被取消——如实说明,不硬造空图。
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
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "chart.pie", title: "空间地图", tint: accent) {
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
            SunburstChart(
                root: root,
                tint: accent,
                isTopLevel: root.path == tree.path,
                onTap: { handleTap($0, in: tree) },
                onGoUp: { goUp(in: tree) }
            )
            .frame(maxWidth: .infinity)
        }
        .cardShell(compact: false)
    }

    // MARK: 导航态

    private func resolveDrill(in tree: SpaceMapNode) -> SpaceMapNode {
        guard let drillPath, let node = tree.descendant(atPath: drillPath) else { return tree }
        return node
    }

    private func handleTap(_ node: SpaceMapNode, in tree: SpaceMapNode) {
        if node.isSealed {
            notice = "系统密封区:macOS 只读系统文件,不可删除也不可下钻。清理请去「开发者垃圾」——那里只列白名单担保过的目录。"
            return
        }
        if node.isAggregate {
            notice = "「其他」= \(node.mergedCount) 个小于显示阈值的目录合并(单块太窄看不清);进入上一层的目录可见完整子项。"
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

    // MARK: 面包屑(逐级可跳)与多根选择

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

// MARK: - 旭日图本体(薄壳:几何来自 SunburstLayout)

private struct SunburstChart: View {
    /// {layout.sunburst-diameter}
    static let diameter: CGFloat = 340

    let root: SpaceMapNode
    let tint: Color
    let isTopLevel: Bool
    let onTap: (SpaceMapNode) -> Void
    let onGoUp: () -> Void

    @State private var hoveredID: SunburstArc.ID?

    private var arcs: [SunburstArc] {
        SunburstLayout.layout(root: root)
    }

    var body: some View {
        let radius = Self.diameter / 2
        ZStack {
            ForEach(coloredArcs) { item in
                ArcShape(arc: item.arc, radius: radius)
                    .fill(item.color)
                    // SwiftUI 默认按矩形框架命中测试——ZStack 里所有弧都占 340×340,
                    // 只剩最顶(ForEach 最后一个)吃到全部事件(用户实拍:悬浮/下钻只
                    // 认 700M 那块)。contentShape 用弧自身路径做命中区域。
                    .contentShape(ArcShape(arc: item.arc, radius: radius))
                    .opacity(item.arc.id == hoveredID ? 0.72 : item.arc.node.isSealed ? 1.0 : 0.92)
                    .onTapGesture { onTap(item.arc.node) }
                    .onHover { hovering in
                        if hovering {
                            hoveredID = item.arc.id
                        } else if hoveredID == item.arc.id {
                            hoveredID = nil
                        }
                    }
            }
            center(radius: radius)
            labels(radius: radius)
            if let arc = hoveredArc {
                tip(arc, radius: radius)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }

    // MARK: 配色(内环循环既有令牌,外环随父色;布局按父-子顺序产出,顺序即着色依据)

    private struct ColoredArc: Identifiable {
        let id: SunburstArc.ID
        let arc: SunburstArc
        let color: Color
    }

    private var coloredArcs: [ColoredArc] {
        var result: [ColoredArc] = []
        var ring1Index = 0
        var current = sunburstRingColors[0]
        for arc in arcs {
            if arc.ring == 1 {
                current = sunburstRingColors[ring1Index % sunburstRingColors.count]
                ring1Index += 1
            }
            let color = arc.node.isSealed
                ? Surface.inkTertiary
                : (arc.node.isAggregate ? Surface.cardHigh : current)
            result.append(ColoredArc(id: arc.id, arc: arc, color: color))
        }
        return result
    }

    // MARK: 中心(当前根 + 返回上级)

    private func center(radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Surface.cardHigh)
                .frame(width: radius * 0.68, height: radius * 0.68)
            VStack(spacing: 2) {
                Text(root.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(PulseFormat.memory(UInt64(max(0, root.bytes))))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                if root.isPartial {
                    Text("部分扫描")
                        .font(.system(size: 9))
                        .foregroundStyle(Surface.warning)
                }
                if isTopLevel {
                    Text("点击色块下钻")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Button("↩ 返回上级", action: onGoUp)
                        .font(.system(size: 10.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(tint)
                }
            }
            .frame(maxWidth: radius * 0.6)
        }
        .allowsHitTesting(!isTopLevel)
    }

    // MARK: 弧内标签(阈值内才显示;左半圆翻转保证外向可读)

    private func labels(radius: CGFloat) -> some View {
        ForEach(arcs.filter { $0.isLabelReadable && !$0.node.isSealed && !$0.node.isAggregate }) { arc in
            let midRadius = arc.ring == 1 ? radius * 0.52 : radius * 0.835
            let point = CGPoint(
                x: radius + midRadius * CGFloat(cos(arc.midAngle)),
                y: radius + midRadius * CGFloat(sin(arc.midAngle))
            )
            Text("\(arc.node.name) · \(PulseFormat.memory(UInt64(max(0, arc.node.bytes))))")
                .font(.system(size: arc.ring == 1 ? 10 : 9, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: max(24, midRadius * arc.span * 0.9))
                .rotationEffect(.degrees(arc.midAngle * 180 / .pi + (arc.flipsLabel ? 180 : 0)))
                .position(point)
                .allowsHitTesting(false)
        }
    }

    // MARK: 悬浮提示(锚在弧中角外侧,钳制在图内;内容与树数据同源)

    private var hoveredArc: SunburstArc? {
        arcs.first { $0.id == hoveredID }
    }

    private func tip(_ arc: SunburstArc, radius: CGFloat) -> some View {
        let anchorRadius = radius * 0.92
        let raw = CGPoint(
            x: radius + anchorRadius * CGFloat(cos(arc.midAngle)),
            y: radius + anchorRadius * CGFloat(sin(arc.midAngle))
        )
        let halfWidth: CGFloat = 112
        let halfHeight: CGFloat = 32
        let position = CGPoint(
            x: min(max(raw.x, halfWidth + 6), Self.diameter - halfWidth - 6),
            y: min(max(raw.y, halfHeight + 6), Self.diameter - halfHeight - 6)
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(arc.node.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if arc.node.isPartial {
                    Text("部分扫描")
                        .font(.system(size: 9))
                        .foregroundStyle(Surface.warning)
                }
            }
            Text(arc.node.path.isEmpty ? "合并块" : arc.node.path)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(hoverMetrics(arc))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 220, alignment: .leading)
        .background(Surface.cardHigh, in: RoundedRectangle(cornerRadius: 8))
        .position(position)
        .allowsHitTesting(false)
    }

    private func hoverMetrics(_ arc: SunburstArc) -> String {
        let size = PulseFormat.memory(UInt64(max(0, arc.node.bytes)))
        let percent = String(format: "%.1f%%", arc.volumeFraction * 100)
        var extras = [String]()
        if arc.node.isAggregate {
            extras.append("含 \(arc.node.mergedCount) 项")
        }
        if arc.node.isSealed {
            extras.append("只读系统区")
        }
        let suffix = extras.isEmpty ? "" : "(" + extras.joined(separator: "、") + ")"
        return "\(size) · 占整卷 \(percent)\(suffix)"
    }
}

/// 一段弧的 Path(两环半径比与原型 B 一致:0.36–0.68 / 0.68–0.99)。
private struct ArcShape: Shape {
    let arc: SunburstArc
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inner = arc.ring == 1 ? radius * 0.36 : radius * 0.68
        let outer = arc.ring == 1 ? radius * 0.68 : radius * 0.99
        // 角向留缝让相邻弧可见分离;窄弧按比例缩缝,不把弧吞没。
        let pad = min(0.012, arc.span / 4)
        var path = Path()
        path.addArc(
            center: center, radius: outer,
            startAngle: .radians(arc.start + pad), endAngle: .radians(arc.end - pad),
            clockwise: false
        )
        path.addLine(to: point(center, inner, arc.end - pad))
        path.addArc(
            center: center, radius: inner,
            startAngle: .radians(arc.end - pad), endAngle: .radians(arc.start + pad),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }
}
