import AppKit
import Charts
import PulseCore
import SwiftUI

// MARK: - 环形卡(工单 P0.6-05,参考文档 §2.2 "Right Now" / §3-4 donut)

/// 环形的一段:名称 + 字节 + 占比 + 填充色 + 图例图标。
struct RingSlice: Identifiable {
    enum Icon {
        /// 应用图标(.app bundle 路径)。
        case app(String)
        /// SF Symbol + 外壳底色(项目 / 兜底类别 / "其他")。
        case symbol(String, Color)
        /// 色点(构成类分段)。
        case dot
    }

    let id: String
    let name: String
    let bytes: UInt64
    /// 0–1,占环总量的比例。
    let fraction: Double
    let color: Color
    let icon: Icon
}

extension RingSlice {
    /// Memory by App(§2.2):top-5 单色梯度(tint 100/83/66/49/32%),"其他" = card-hi。
    static func memoryByApp(_ segments: [MemoryRingSegment]) -> [RingSlice] {
        let opacities: [Double] = [1.0, 0.83, 0.66, 0.49, 0.32]
        let tint = Metric.memory.accentColor
        return segments.enumerated().map { index, segment in
            let icon: Icon = if let bundlePath = segment.bundlePath {
                .app(bundlePath)
            } else if segment.isOther {
                .symbol("ellipsis", GroupCategory.system.identityColor)
            } else {
                .symbol(
                    segment.category?.cardStyle.symbolName ?? "shippingbox",
                    segment.category?.identityColor ?? GroupCategory.system.identityColor
                )
            }
            let color = segment.isOther || index >= opacities.count
                ? Surface.cardHigh
                : tint.opacity(opacities[index])
            return RingSlice(
                // 展示层键:环形图切片身份,非组身份——组身份止于 MemoryRingSegment。
                id: segment.id?.stableKey ?? "ring-slice-other",
                name: segment.name, bytes: segment.bytes,
                fraction: segment.fraction, color: color, icon: icon
            )
        }
    }

    /// Memory by Type(§2.2):分段直接走 MemoryCompositionKey 单表(评审 F5)——
    /// 名称与色和总览内存卡统计点同出处,App = CPU 蓝 / 联动 = Projects 橙 /
    /// 压缩 = Network 绿 / 缓存 = ink-3 / 空闲 = card-hi。
    static func memoryByType(_ memory: MemoryBreakdown) -> [RingSlice] {
        let total = max(Double(memory.totalBytes), 1)
        return MemoryCompositionKey.allCases.map { key in
            let bytes = memory.bytes(for: key)
            return RingSlice(
                id: key.rawValue, name: key.title, bytes: bytes,
                fraction: Double(bytes) / total, color: key.color, icon: .dot
            )
        }
    }
}

/// 环形卡:标题行(徽章 + 名称)+ 环形(环心大数字 + 两字说明)+ 图例。
struct RingCardView: View {
    let title: String
    let symbolName: String
    let tint: Color
    let centerValue: String
    let centerUnit: String
    let centerCaption: String
    let slices: [RingSlice]
    var isCompact = false

    var body: some View {
        // 两档都画卡头:弹窗里两张环上下排(2026-10-20 起与主窗口同内容),没有标题分不清。
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: symbolName, title: title, tint: tint)
            if slices.isEmpty {
                CardEmptyState(title: "暂无内存数据")
            } else {
                HStack(spacing: isCompact ? 14 : 20) {
                    ring
                    legend
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    private var ring: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("内存", slice.bytes),
                innerRadius: .ratio(0.74),
                angularInset: 1.2
            )
            .cornerRadius(2.5)
            .foregroundStyle(slice.color)
        }
        .frame(width: isCompact ? 104 : 124, height: isCompact ? 104 : 124)
        .overlay {
            VStack(spacing: 2) {
                FigureText(
                    value: centerValue,
                    unit: centerUnit,
                    size: isCompact ? FigureSize.ringCompact : FigureSize.ring
                )
                Text(centerCaption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true) // 数值与名称由图例文字承载
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(slices) { slice in
                HStack(spacing: 6) {
                    legendIcon(slice)
                        .frame(width: 16, height: 16)
                    Text(slice.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(PulseFormat.systemMemory(slice.bytes))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                    Text("\(Int((slice.fraction * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
    }

    @ViewBuilder
    private func legendIcon(_ slice: RingSlice) -> some View {
        switch slice.icon {
        case let .app(path):
            Image(nsImage: AppIconCache.icon(forBundle: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        case let .symbol(name, color):
            CategoryIconTile(symbolName: name, color: color, size: 16)
        case .dot:
            Circle()
                .fill(slice.color)
                .frame(width: 8, height: 8)
        }
    }
}

extension RingCardView {
    /// Memory by Type 卡:环心 = 已用占比。
    static func memoryByType(_ memory: MemoryBreakdown?, isCompact: Bool = false) -> RingCardView {
        let usedPercent = memory.map { Double($0.usedBytes) / max(Double($0.totalBytes), 1) * 100 } ?? 0
        return RingCardView(
            title: "内存构成",
            symbolName: "memorychip",
            tint: Metric.cpu.accentColor,
            centerValue: memory == nil ? "—" : PulseFormat.cpuPercentNumber(usedPercent),
            centerUnit: memory == nil ? "" : "%",
            centerCaption: "已使用",
            slices: memory.map(RingSlice.memoryByType) ?? [],
            isCompact: isCompact
        )
    }

    /// Memory by App 卡:环心 = 全部组内存合计。
    static func memoryByApp(
        segments: [MemoryRingSegment],
        totalBytes: UInt64,
        isCompact: Bool = false
    ) -> RingCardView {
        let figure = PulseFormat.systemMemoryFigure(totalBytes)
        return RingCardView(
            title: "按应用",
            symbolName: "square.grid.2x2",
            tint: Metric.memory.accentColor,
            centerValue: figure.value,
            centerUnit: figure.unit,
            centerCaption: "全部应用",
            slices: RingSlice.memoryByApp(segments),
            isCompact: isCompact
        )
    }
}

// MARK: - 预览(arch-review-2026-10-18/02:预览缺口补齐)

#Preview("环形卡") {
    let memory = MemoryBreakdown(
        totalBytes: 51_539_607_552, appBytes: 21_000_000_000, wiredBytes: 6_000_000_000,
        compressedBytes: 9_000_000_000, cachedBytes: 8_000_000_000, pressure: .normal
    )
    VStack(spacing: 16) {
        HStack(alignment: .top, spacing: 16) {
            RingCardView.memoryByType(memory)
            RingCardView.memoryByType(nil)
        }
        RingCardView.memoryByType(memory, isCompact: true)
            .frame(width: 332)
    }
    .padding(24)
    .frame(width: 720)
    .background(Surface.window)
}
