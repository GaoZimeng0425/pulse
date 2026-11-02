import PulseCore
import SwiftUI

/// 页头统一组件(popover-header/01,2026-11-02 用户拍板:每个 tab 只有一个标题,且是
/// 统一组件):主窗口页头 / 弹窗页头 / 清理页页头三处同一出处,不再各自手写。
/// 结构 = 标题一行 + 可选副标题一行 + 右侧可选配件槽(弹窗运行时长、清理页扫描按钮)。
///
/// 副标题的「本机一行」(芯片 · 核数 · 内存)**只有总览带**(`init(tab:)` 是唯一判据,
/// 两窗不许各写一份);清理页的副标题是扫描状态,由 `CleanerPageHeader` 直接给字符串。
///
/// 两档:`.full` 主窗口 = `{typography.page-title}` 26 bold + `{typography.body}` 12 secondary;
/// `.compact` 弹窗 = 两行皆 `{typography.caption}` 11 secondary(弹窗既有观感,未改);
/// 标题-副标题行距 `{spacing.micro}` 2。配件由调用方自带字号(弹窗运行时长沿 caption)。
struct PageHeader<Accessory: View>: View {
    enum Style {
        case full
        case compact
    }

    let title: String
    let subtitle: String?
    let style: Style
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, subtitle: String? = nil, style: Style, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.accessory = accessory
    }

    /// 按 tab 组页头:标题 = tab 名;副标题 = 只有总览带本机一行,其余 tab 无。
    init(tab: MetricTab, style: Style, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(title: tab.title, subtitle: Self.hostSubtitle(for: tab), style: style, accessory: accessory)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(style == .compact ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            accessory()
        }
    }

    private var titleFont: Font {
        switch style {
        case .full: .system(size: 26, weight: .bold)
        case .compact: .system(size: 11)
        }
    }

    private var subtitleFont: Font {
        switch style {
        case .full: .system(size: 12)
        case .compact: .system(size: 11)
        }
    }

    /// 本机一行只在总览(用户拍板 2026-11-02:「应该只有总览有 CPU 数量这些信息」)。
    private static func hostSubtitle(for tab: MetricTab) -> String? {
        guard tab == .overview else { return nil }
        let host = HostInfo.current
        return PulseFormat.hostSummary(
            chipName: host.chipName,
            coreCount: host.coreCount,
            physicalMemoryBytes: host.physicalMemoryBytes
        )
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, style: Style) {
        self.init(title: title, subtitle: subtitle, style: style) { EmptyView() }
    }

    init(tab: MetricTab, style: Style) {
        self.init(tab: tab, style: style) { EmptyView() }
    }
}

#Preview("页头两档") {
    VStack(alignment: .leading, spacing: 24) {
        PageHeader(tab: .overview, style: .full)
        PageHeader(tab: .cpu, style: .full)
        PageHeader(title: "清理", subtitle: "按需扫描,不常驻 · 结果缓存到下次扫描", style: .full) {
            Button("扫描整台 Mac") {}
                .buttonStyle(.borderedProminent)
        }
        Divider()
        PageHeader(tab: .overview, style: .compact) {
            Label("6d 4h", systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        PageHeader(tab: .cpu, style: .compact) {
            Label("6d 4h", systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
    .padding(16)
    .frame(width: 400)
    .background(Surface.window)
}
