import PulseCore
import SwiftUI

// MARK: - 空间地图(space-map-forms/01)

//
// 磁盘页的空间地图卡,只在主窗口出现(弹窗不画,见 MetricTabStack `.disk`)。
// 方块 / 旭日双形态同一种画法:单个 Canvas 一次 draw call,命中一律坐标反算、
// 不依赖形状 hit test——不留两套渲染方案。
// 组成:卡头(形态切换 + 在 Finder 中显示)→ 路径栏 → 图表区(方块 / 旭日二选一)。
// 悬停读数、点击解释、「这块能清」都浮在图表区内。
// 树变换与两种几何在 PulseCore(SpaceMap.swift / TreemapLayout.swift),这里只管
// 描边、配色、命中与交互。

/// 方块形态图表区高下限({layout.spacemap-chart-min-height})。
private let chartMinHeight: CGFloat = 220

/// 旭日图表区高下限(= 直径下限,{layout.spacemap-sunburst-min-side},
/// space-map-forms/05):窄窗防过小。宽度下限由主窗口最小宽 720 保障。
private let sunburstMinSide: CGFloat = 360

/// 图表区高占滚动视口高的份额({layout.spacemap-sunburst-viewport-share}),两形态共用:
/// 扣掉的两成留给页头、卡头、路径栏与下方摘要卡露头。
private let sunburstViewportShare: CGFloat = 0.8

/// 图表区高上限({layout.spacemap-sunburst-max-side};对旭日 = 直径上限):高窗 /
/// 最大化时卡片不跟着视口无限变长(卡总高 ≈ 图表区 + 头部约 150)。
private let sunburstMaxSide: CGFloat = 520

/// 展示形态(用户偏好,@AppStorage 记住上次;默认方块)。
private enum SpaceMapForm: String, CaseIterable {
    case treemap
    case sunburst

    var pillTitle: String {
        self == .treemap ? "方块" : "旭日"
    }

    var pillSymbol: String {
        self == .treemap ? "square.grid.3x3" : "chart.pie"
    }
}

struct SpaceMapSection: View {
    let model: CleanerModel
    @Binding var drillPath: String?
    @Binding var treeIndex: Int
    /// 命中白名单的块「去清理清单」动作:宿主经 DashboardModel 跨页轻桥切清理页并定位组
    /// (tab-regroup/03)。
    let onGoToJunk: (JunkGroup) -> Void

    @AppStorage("settings.spaceMapForm") private var formRaw = SpaceMapForm.treemap.rawValue
    @State private var notice: String?
    /// 悬浮命中键(两形态各编各的:treemap "t<下标>";旭日 = SunburstArc.id)。
    @State private var hoveredKey: String?

    private var accent: Color {
        Surface.cleanAccent
    }

    private var form: SpaceMapForm {
        SpaceMapForm(rawValue: formRaw) ?? .treemap
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

    /// 地图卡的版面纪律,两形态同守:
    /// - 悬停零重排:卡内不出现 / 消失任何占行元素,悬停读数、解释与按钮都浮在图表区内;
    /// - 高度紧张时挤只挤图表区,卡头与路径栏不被压缩截断;
    /// - 块与弧不做动画(悬停提亮、下钻换图都直切,与 meter 条同款纪律)。
    private func mapCard(_ tree: SpaceMapNode) -> some View {
        let root = resolveDrill(in: tree)
        let isTopLevel = root.path == tree.path
        // 角标判定 = 白名单规则表 ∪ 本次卸载残留候选(p5-cleaner/02;与清单同源同家目录),
        // 两形态同一个解析器。
        let resolve = model.mapCleanableResolver()
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: "square.grid.3x3.square", title: "空间地图", tint: accent) {
                // 页内头部动作按钮统一配方(与垃圾页组头「全选安全项」同款):
                // borderless + 12 semibold secondary。
                HStack(spacing: 10) {
                    formPicker
                    Button("在 Finder 中显示") { reveal(root) }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            if model.mapTrees.count > 1 {
                rootPicker
                    .layoutPriority(1)
            }
            breadcrumbRow(tree)
                .layoutPriority(1)
            switch form {
            case .treemap:
                treemapArea(root: root, tree: tree, resolve: resolve)
            case .sunburst:
                sunburstArea(root: root, tree: tree, isTopLevel: isTopLevel, resolve: resolve)
            }
        }
        .cardShell(compact: false)
    }

    /// 形态切换 = 通用件 PillTabBar 的 `.selectedOnly` 形态(space-map-forms/02)。
    /// 记住上次选择;切换不重置下钻位置——同一棵树换个透镜看,不是重新导航
    /// (下钻位置由宿主 DashboardModel 持有,切 tab / 切页同样不丢)。
    private var formPicker: some View {
        PillTabBar(SpaceMapForm.allCases, selection: formBinding, textVisibility: .selectedOnly) { form in
            PillTabItem(title: form.pillTitle, symbol: form.pillSymbol, tint: accent)
        }
        .onChange(of: formRaw) { _, _ in
            hoveredKey = nil
        }
    }

    private var formBinding: Binding<SpaceMapForm> {
        Binding(
            get: { SpaceMapForm(rawValue: formRaw) ?? .treemap },
            set: { formRaw = $0.rawValue }
        )
    }

    private var emptyTreeText: some View {
        Text("此目录下没有子目录(文件已聚合进大小)。")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
    }

    // MARK: 方块形态(Canvas 单次 draw call;命中 = rect.contains)

    /// 「其他」合并线两形态同值:各是 TreemapLayout / SunburstLayout.layout 的默认参数
    /// (占同级合计 1%),视图不传、各取默认——改一处要同步另一处。
    private func treemapArea(
        root: SpaceMapNode,
        tree: SpaceMapNode,
        resolve: (String) -> JunkGroup?
    ) -> some View {
        let rects = TreemapLayout.layout(root: root)
        // 角标判定预计算一次(与 rects 同源);Canvas 里只查表,hover 重绘零重算。
        // 只命中非密封非合并块——密封区不可删、「其他」是合成块,都零暗示(ADR-0008)。
        let cleanable: [JunkGroup?] = rects.map { rect in
            guard !rect.node.isSealed, !rect.node.isAggregate else { return nil }
            return resolve(rect.node.path)
        }
        return Group {
            if rects.isEmpty {
                emptyTreeText
            } else {
                treemapBody(rects: rects, tree: tree, cleanable: cleanable)
            }
        }
    }

    private func treemapBody(
        rects: [TreemapRect],
        tree: SpaceMapNode,
        cleanable: [JunkGroup?]
    ) -> some View {
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

                    let fill = SpaceMapPalette.blockFill(
                        node: tr.node,
                        rank: index,
                        isHovered: hoveredTreemapIndex == index
                    )

                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 5),
                        with: .color(fill.color.opacity(fill.opacity))
                    )

                    if rect.width > 48, rect.height > 16 {
                        let name = tr.node.name
                        let sz = PulseFormat.memory(UInt64(max(0, tr.node.bytes)))
                        let pct = String(format: "%.1f%%", tr.rect.width * tr.rect.height * 100)
                        let textColor = fill.textColor
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
                    if cleanable.indices.contains(index), cleanable[index] != nil {
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
                    hoveredKey = hitIndex(at: location, in: geo.size, rects: rects)
                        .map(Self.treemapKey)
                case .ended:
                    hoveredKey = nil
                }
            }
            treemapBridgeButton(rects: rects, cleanable: cleanable, in: geo.size)
            noticeOverlay
        }
        // 图表区高 = clamp(滚动视口高 × 份额, 本形态下限, 上限),两形态同式(旭日处同此;
        // containerRelativeFrame 量的是滚动视口,不是内容高)。不用弹性 maxHeight:卡在
        // 页面滚动里,弹性区拿到无限高提案,会塌到最小高、矮成一条(space-map-forms/10)。
        .containerRelativeFrame(.vertical) { length, _ in
            min(max(length * sunburstViewportShare, chartMinHeight), sunburstMaxSide)
        }
    }

    private static func treemapKey(_ index: Int) -> String {
        "t\(index)"
    }

    private var hoveredTreemapIndex: Int? {
        guard let hoveredKey, hoveredKey.first == "t" else { return nil }
        return Int(hoveredKey.dropFirst())
    }

    private func hitIndex(at point: CGPoint, in size: CGSize, rects: [TreemapRect]) -> Int? {
        let p = CGPoint(x: point.x / size.width, y: point.y / size.height)
        return rects.firstIndex { $0.rect.contains(p) }
    }

    /// 方块的「这块能清」:悬停命中白名单块时浮在该块右上角。卡头不放悬停信息行
    /// (路径与大小块内已有,读数不另起一行)。
    @ViewBuilder
    private func treemapBridgeButton(
        rects: [TreemapRect],
        cleanable: [JunkGroup?],
        in size: CGSize
    ) -> some View {
        if let index = hoveredTreemapIndex,
           rects.indices.contains(index),
           cleanable.indices.contains(index),
           let group = cleanable[index] {
            let tr = rects[index]
            // 块太小时按钮会溢出到邻块,只在装得下的块上浮。
            let width = tr.rect.width * size.width
            let height = tr.rect.height * size.height
            if width > 140, height > 48 {
                bridgeButton(group)
                    .position(x: tr.rect.maxX * size.width - 44, y: tr.rect.minY * size.height + 16)
            }
        }
    }

    // MARK: 旭日形态(Canvas 单次 draw call;命中 = atan2 角度 + sqrt 半径)

    private func sunburstArea(
        root: SpaceMapNode,
        tree: SpaceMapNode,
        isTopLevel: Bool,
        resolve: @escaping (String) -> JunkGroup?
    ) -> some View {
        let arcs = SunburstLayout.layout(root: root)
        return Group {
            if arcs.isEmpty {
                emptyTreeText
            } else {
                sunburstBody(arcs: arcs, root: root, tree: tree, isTopLevel: isTopLevel, resolve: resolve)
            }
        }
    }

    /// 环形半径的比例(中心圈 / 内环 / 外环)没有具名常量:绘制(这里与 drawCenter)、
    /// 命中(hitArc)、中心圈点按(handleSunburstTap)也各写一遍,改一处要同步其余。
    private func sunburstBody(
        arcs: [SunburstArc],
        root: SpaceMapNode,
        tree: SpaceMapNode,
        isTopLevel: Bool,
        resolve: @escaping (String) -> JunkGroup?
    ) -> some View {
        let colored = SpaceMapPalette.coloredArcs(arcs)
        return GeometryReader { geo in
            Canvas { context, size in
                let radius = sunburstRadius(in: size)
                let center = sunburstCenter(in: size)
                let hovered = arcs.first { $0.id == hoveredKey }

                for item in colored {
                    let arc = item.arc
                    let inner = arc.ring == 1 ? radius * 0.28 : radius * 0.65
                    let outer = arc.ring == 1 ? radius * 0.65 : radius * 0.99
                    // 角向留缝让相邻弧可见分离;窄弧按比例缩缝,不把弧吞没。
                    let pad = min(0.012, arc.span / 4)
                    var path = Path()
                    path.addArc(
                        center: center,
                        radius: outer,
                        startAngle: .radians(arc.start + pad),
                        endAngle: .radians(arc.end - pad),
                        clockwise: false
                    )
                    path.addLine(to: polar(center, inner, arc.end - pad))
                    path.addArc(
                        center: center,
                        radius: inner,
                        startAngle: .radians(arc.end - pad),
                        endAngle: .radians(arc.start + pad),
                        clockwise: true
                    )
                    path.closeSubpath()
                    let isHovered = hovered?.id == arc.id
                    let fillOpacity = isHovered ? min(item.opacity + SpaceMapPalette.hoverBoost, 0.95) : item.opacity
                    context.fill(path, with: .color(item.color.opacity(fillOpacity)))
                }

                // 「可清理」小圆点(treemap 小块退化为点的同款口径;药丸文字弧里放不下)。
                for item in colored {
                    let arc = item.arc
                    guard !arc.node.isSealed, !arc.node.isAggregate,
                          resolve(arc.node.path) != nil else { continue }
                    let dotRadius = arc.ring == 1 ? radius * 0.33 : radius * 0.94
                    guard dotRadius * CGFloat(arc.span) > 10 else { continue }
                    let dotCenter = polar(center, dotRadius, arc.midAngle)
                    let dot = CGRect(x: dotCenter.x - 2.5, y: dotCenter.y - 2.5, width: 5, height: 5)
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(Surface.cleanAccent.opacity(0.95))
                    )
                }

                // 弧内标签:份额阈值内才显示,文字沿半径排,左半圆翻转 180° 保持外向可读。
                // 长度上限 = 本环带宽 ×0.9,不是弧长——按弧长量,大弧的文字会长过环带、
                // 压到相邻环的名上。Canvas 里 Text 没有 maxWidth 约束,先量宽后截断。
                for item in colored {
                    let arc = item.arc
                    guard arc.isLabelReadable, !arc.node.isSealed, !arc.node.isAggregate else { continue }
                    let midRadius = arc.ring == 1 ? radius * 0.47 : radius * 0.83
                    let point = polar(center, midRadius, arc.midAngle)
                    let ringWidth = arc.ring == 1 ? radius * 0.37 : radius * 0.34
                    let label = arcLabel(arc.node, maxWidth: ringWidth * 0.9)
                    guard !label.isEmpty else { continue }
                    let rotation = arc.midAngle + (arc.flipsLabel ? .pi : 0)
                    context.drawLayer { layer in
                        layer.translateBy(x: point.x, y: point.y)
                        layer.rotate(by: .radians(rotation))
                        layer.draw(
                            Text(label).font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(item.opacity >= 0.5 ? Color.white : Color.primary),
                            at: .zero,
                            anchor: .center
                        )
                    }
                }

                drawCenter(
                    context,
                    center: center,
                    radius: radius,
                    root: root,
                    hovered: hovered,
                    isTopLevel: isTopLevel
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleSunburstTap(at: location, in: geo.size, arcs: arcs, tree: tree, isTopLevel: isTopLevel)
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoveredKey = hitArc(at: location, in: geo.size, arcs: arcs)?.id
                case .ended:
                    hoveredKey = nil
                }
            }
            sunburstBridgeButton(arcs: arcs, resolve: resolve, in: geo.size)
            noticeOverlay
        }
        // 图表区高与方块同式(见 treemapBody)。
        .containerRelativeFrame(.vertical) { length, _ in
            min(max(length * sunburstViewportShare, sunburstMinSide), sunburstMaxSide)
        }
    }

    /// 中心圈 = 旭日的悬停读数位:悬停弧 → 该块名字 + 实际占用 + 占当前根的份额
    /// (密封 / 「其他」换成只读 / 合并项数说明);不悬停 → 当前根 + 返回上级
    /// (顶层换成下钻提示)。小弧画不下标签,名字与大小的全读数靠这里兜底。
    private func drawCenter(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        root: SpaceMapNode,
        hovered: SunburstArc?,
        isTopLevel: Bool
    ) {
        let r = radius * 0.26
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .color(Surface.cardHigh)
        )
        let node = hovered?.node ?? root
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let name = measuredTruncation(node.name, font: nameFont, maxWidth: r * 1.9)
        context.draw(
            Text(name).font(.system(size: 12, weight: .semibold)),
            at: CGPoint(x: center.x, y: center.y - 20),
            anchor: .center
        )
        context.draw(
            Text(PulseFormat.memory(UInt64(max(0, node.bytes))))
                .font(.system(size: 14.5, weight: .bold)).monospacedDigit(),
            at: CGPoint(x: center.x, y: center.y - 3),
            anchor: .center
        )
        let hint: (text: String, color: Color, weight: Font.Weight)
        if let hovered {
            if hovered.node.isSealed {
                hint = ("只读系统区", Color.secondary, .regular)
            } else if hovered.node.isAggregate {
                hint = ("含 \(hovered.node.mergedCount) 项", Color.secondary, .regular)
            } else {
                let share = String(format: "%.1f%%", hovered.volumeFraction * 100)
                hint = ("占当前 \(share)", Color.secondary, .regular)
            }
        } else if root.isPartial {
            hint = ("部分扫描", Surface.warning, .regular)
        } else if isTopLevel {
            hint = ("点击色块下钻", Color.secondary, .regular)
        } else {
            hint = ("↩ 返回上级", accent, .semibold)
        }
        context.draw(
            Text(hint.text).font(.system(size: 10.5, weight: hint.weight)).monospacedDigit()
                .foregroundColor(hint.color),
            at: CGPoint(x: center.x, y: center.y + 15),
            anchor: .center
        )
    }

    /// 旭日的「这块能清」:悬停命中白名单弧时锚在该弧中角的外缘并钳制在图内
    /// (弧带窄,方块「浮在块右上角」的配方套不进来)。
    @ViewBuilder
    private func sunburstBridgeButton(
        arcs: [SunburstArc],
        resolve: (String) -> JunkGroup?,
        in size: CGSize
    ) -> some View {
        if let hoveredKey,
           let arc = arcs.first(where: { $0.id == hoveredKey }),
           !arc.node.isSealed, !arc.node.isAggregate,
           let group = resolve(arc.node.path) {
            let anchor = polar(sunburstCenter(in: size), sunburstRadius(in: size) * 0.9, arc.midAngle)
            bridgeButton(group)
                .position(
                    x: min(max(anchor.x, 60), size.width - 60),
                    y: min(max(anchor.y, 16), size.height - 16)
                )
        }
    }

    // MARK: 命中(极坐标反算,不做形状 hit test)

    /// 旭日半径:直径 = min(卡内容宽, 图表区高),卡内居中——固定直径在宽卡里太小,
    /// 直径跟卡宽走又顶天立地,所以取两者的小值。别改成量图表自身的宽来定直径:
    /// 它与内容宽互为因果,会正反馈把卡撑爆。
    private func sunburstRadius(in size: CGSize) -> CGFloat {
        min(size.width, size.height) / 2
    }

    private func sunburstCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// 给定图表局部坐标,返回命中的弧(nil = 中心圈或图外)。
    private func hitArc(at point: CGPoint, in size: CGSize, arcs: [SunburstArc]) -> SunburstArc? {
        let radius = sunburstRadius(in: size)
        let center = sunburstCenter(in: size)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        // 中心圆区域 → 无弧(中心有自己的交互:返回上级);图外 → 无弧。
        guard distance > radius * 0.26, distance <= radius * 0.995 else { return nil }
        // atan2 的结果就是标准极角,与弧的 start/end 同一坐标系,直接比对。不要换算到
        // 「0 = 正上」:多加 π/2 会让命中恒偏 90°、落到顺时针下一段(space-map-forms/05,
        // 回归测试钉在 SpaceMapTests)。
        let angle = atan2(dy, dx)
        let ring = distance <= radius * 0.65 ? 1 : 2
        return arcs.first { $0.ring == ring && $0.contains(angle: angle) }
    }

    private func handleSunburstTap(
        at point: CGPoint,
        in size: CGSize,
        arcs: [SunburstArc],
        tree: SpaceMapNode,
        isTopLevel: Bool
    ) {
        if let arc = hitArc(at: point, in: size, arcs: arcs) {
            handleTap(arc.node, in: tree)
            return
        }
        // 中心圈:下钻态点按 = 返回上级(顶层中心只有提示,点按不响应)。
        guard !isTopLevel, drillPath != nil else { return }
        let radius = sunburstRadius(in: size)
        let center = sunburstCenter(in: size)
        let dx = point.x - center.x
        let dy = point.y - center.y
        if sqrt(dx * dx + dy * dy) <= radius * 0.26 {
            goUp(in: tree)
        }
    }

    // MARK: 共享交互(两形态同一套文案与行为)

    private func handleTap(_ node: SpaceMapNode, in tree: SpaceMapNode) {
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

    private func handleTap(
        at point: CGPoint,
        in size: CGSize,
        rects: [TreemapRect],
        tree: SpaceMapNode
    ) {
        guard let index = hitIndex(at: point, in: size, rects: rects) else { return }
        handleTap(rects[index].node, in: tree)
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

    /// 密封区 / 叶子 / 「其他」的点击解释(notice):浮在地图左上角的胶囊,不吃点击、
    /// 不占卡内一行——做成占位行时,路径栏与地图之间会常年空一大截。
    @ViewBuilder
    private var noticeOverlay: some View {
        if let notice {
            Text(notice)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Surface.cardHigh.opacity(0.9), in: .capsule)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .padding(4)
        }
    }

    /// 「这块能清」浮层按钮,两形态同一配方。地图只读:卡上不放任何删除控件
    /// (ADR-0008),它只带去清理清单定位对应组——help 文案明示判定来源与这一点。
    private func bridgeButton(_ group: JunkGroup) -> some View {
        Button {
            onGoToJunk(group)
        } label: {
            Label("这块能清", systemImage: "arrow.right.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Surface.cleanAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Surface.cardHigh.opacity(0.9), in: .capsule)
        .help(group == .uninstallLeftovers
            ? "这块是卸载残留:命名它的 app 已不在已装应用清单(与清理清单同源);地图本身只读——点击去全部清单定位对应组"
            : "能删的判定来自清理白名单(与清理清单同源);地图本身只读——点击去全部清单定位对应组")
    }

    // MARK: 面包屑与多根选择(与形态无关)

    /// 路径栏(面包屑)是通用件,写法以 DESIGN.md 的面包屑组件规范为准;这里只把当前
    /// 下钻链接给它。
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

    // MARK: 几何小工具

    private func polar(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    /// 量宽截断(Canvas 里 Text 没有 maxWidth 约束,先量后截;放不下返回空串)。
    private func measuredTruncation(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        guard width(text) > maxWidth else { return text }
        var chars = Array(text)
        while !chars.isEmpty {
            chars.removeLast()
            let candidate = "\(String(chars))…"
            if width(candidate) <= maxWidth {
                return candidate
            }
        }
        return ""
    }

    /// 弧内标签 = 名字优先:名字截断到可用宽,大小后缀放得下才带。给大小预留位置会把
    /// 名字多截成「…」、小弧整条放弃——放不下就只显名字,全读数由悬停时的中心圈兜底。
    private func arcLabel(_ node: SpaceMapNode, maxWidth: CGFloat) -> String {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let name = measuredTruncation(node.name, font: font, maxWidth: maxWidth)
        guard !name.isEmpty else { return "" }
        let suffix = " · \(PulseFormat.memory(UInt64(max(0, node.bytes))))"
        let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
        let suffixWidth = (suffix as NSString).size(withAttributes: [.font: font]).width
        return maxWidth - nameWidth >= suffixWidth ? name + suffix : name
    }
}
