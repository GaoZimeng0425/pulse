import SwiftUI
import PulseCore

/// 设置窗外壳(2026-10-16,形态参考 NemoNotch 的 SettingsView / 系统设置):
/// `NavigationSplitView` 双栏——左侧分组列表 + 系统设置风格彩色渐变图标,
/// 右侧详情页;`@AppStorage` 记住上次到访页。保留对方实测沉淀的 macOS 26
/// 修正:删自动侧栏开关(Liquid Glass 下渲染成悬浮圆钮,两处都删)、
/// 窗口补 `.resizable`(见 SettingsWindowChrome)。未移植:侧栏搜索
/// (页少)、整窗玻璃、本地化键(Pulse 全中文硬编码)。
struct SettingsView: View {
    let rootsStore: ProjectRootsStore
    /// 采样管线(工单 11):诊断报告的统计数据源,透传给通用页。
    let monitor: SystemMonitor

    /// 上次到访页(@AppStorage 持久)。
    @AppStorage("settings.selectedPage") private var selectedPageRaw = SettingsPage.general.rawValue

    var body: some View {
        NavigationSplitView {
            sidebarColumn
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 540)
        .toolbar(removing: .sidebarToggle)
        .onAppear { SettingsWindowChrome.install() }
    }

    // MARK: - 侧栏

    private var sidebarColumn: some View {
        List(selection: Binding(
            get: { SettingsPage(rawValue: selectedPageRaw) ?? .general },
            set: { if let page = $0 { selectedPageRaw = page.rawValue } }
        )) {
            // 页面尚少,P1 的菜单栏/告警页暂仍单节直列;分组待 P1 页并齐后统一做。
            ForEach(SettingsPage.allCases) { page in
                sidebarRow(page)
                    .tag(page)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        .toolbar(removing: .sidebarToggle)
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        HStack(spacing: 8) {
            SidebarIconView(symbol: page.symbol, tintA: page.tintA, tintB: page.tintB)
            Text(page.label)
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detailView: some View {
        switch SettingsPage(rawValue: selectedPageRaw) ?? .general {
        case .general: GeneralSettingsView(monitor: monitor)
        case .alerts: AlertSettingsView(center: monitor.alerts)
        case .projectRoots: ProjectRootsSettingsView(store: rootsStore)
        case .menuBar: MenuBarBadgeSettingsView()
        }
    }
}

/// 设置页清单:侧栏标签 / SF Symbol / 图标渐变色(固定色不随明暗切换,
/// 与系统设置的侧栏图标行为一致)。P1 加页时在此登记。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case alerts
    case projectRoots
    case menuBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "通用"
        case .alerts: "告警"
        case .projectRoots: "项目根目录"
        case .menuBar: "菜单栏"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .alerts: "bell.badge"
        case .projectRoots: "folder.badge.gearshape"
        case .menuBar: "menubar.rectangle"
        }
    }

    var tintA: Color {
        switch self {
        case .general: Color(red: 0.62, green: 0.62, blue: 0.66)
        case .alerts: Color(red: 0.95, green: 0.62, blue: 0.20)
        case .projectRoots: Color(red: 0.30, green: 0.55, blue: 0.95)
        case .menuBar: Color(red: 0.58, green: 0.40, blue: 0.92)
        }
    }

    var tintB: Color {
        switch self {
        case .general: Color(red: 0.42, green: 0.42, blue: 0.47)
        case .alerts: Color(red: 0.85, green: 0.35, blue: 0.10)
        case .projectRoots: Color(red: 0.15, green: 0.35, blue: 0.75)
        case .menuBar: Color(red: 0.42, green: 0.22, blue: 0.78)
        }
    }
}

/// 系统设置风格的彩色渐变图标方块(参考 NemoNotch SettingsComponents):
/// 渐变底 + 白色 SF Symbol + 0.5pt 高光描边 + 柔影。装饰性图标,行文本
/// 自身即完整可访问性标签。
private struct SidebarIconView: View {
    let symbol: String
    let tintA: Color
    let tintB: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tintA, tintB],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - 预览(arch-review-2026-10-18/02:预览缺口补齐;项目根不落盘)

#Preview("设置窗") {
    SettingsView(
        rootsStore: ProjectRootsStore(load: { ["~/Documents/Learn"] }, persist: { _ in }),
        monitor: .preview()
    )
}
