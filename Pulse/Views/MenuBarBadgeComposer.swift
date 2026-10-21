import AppKit
import PulseCore

// 菜单栏徽标(p1-history/09):槽位配置 × 数据快照 → 渲染输入。槽位定宽按菜单栏实际
// 绘制字体量(NSFont),故留 app;配置与数据快照是纯值,在核心层
// MenuBarBadgeConfiguration.swift;位图渲染在 MenuBarBadge.swift。

// MARK: - 渲染输入

/// 单枚徽标的渲染输入:纯值语义,不含 SwiftUI 颜色——强调级别由渲染器
/// 映射成色,缓存键得以用值比较(Equatable)。
struct MenuBarBadgeContent: Equatable {
    /// 数字上方的小标签("CPU"/"RAM"/"磁盘"/"网络");叠两行版式不绘制,只作无障碍
    /// 与调试文案。
    let caption: String
    /// 数值文案;叠两行版式以 "\n" 分上下两行。
    let text: String
    /// 强调级:normal = 墨色随外观,warning = 橙,critical = 红。
    let emphasis: Emphasis
    /// 槽位定宽(nil = 自然宽):按该指标**最大现实读数**量好钉死,数字位数
    /// 逐轮变化(38%↔100%)不再改变位图宽——状态项宽度恒定,相邻菜单栏图标
    /// 不被挤动(2026-10-17 用户反馈"menu 有时宽度会变")。网络槽不定宽:
    /// 速率单位跨档(KB/MB/GB)文本长度本就跨档,按最坏情形钉死会长期大片
    /// 留白,得不偿失。
    var slotWidth: CGFloat?
    /// 版式:小标签 + 数字(默认),或不带标签的上下两行小字(网络上下行)。
    var layout: Layout = .captioned

    enum Layout: Equatable {
        case captioned
        case stacked
    }

    enum Emphasis: Equatable {
        case normal
        case warning
        case critical
    }
}

// MARK: - 配置 → 渲染输入(纯函数,spec 钉死的测试缝)

/// 槽位配置 × 数据快照 → 有序徽标内容。降级规则全在此折叠:
/// 读数缺失占位("–"/"—",不伪造)。
enum MenuBarBadgeComposer {
    /// CPU 变红阈值:与菜单栏红线同一出处语义。字面量直写绕开
    /// SystemMonitor 的 MainActor 隔离(先例:StatusBadgeRules),漂移由
    /// MenuBarBadgeTests 的 @MainActor 断言拦截。
    static let cpuRedThreshold: Double = 70

    static func compose(
        _ configuration: MenuBarBadgeConfiguration,
        data: MenuBarBadgeData
    ) -> [MenuBarBadgeContent] {
        configuration.slots.map { slot in
            switch slot {
            case .cpu: cpuContent(load: data.cpuLoadPercent)
            case .ram: ramContent(memory: data.memory)
            case .diskRemaining:
                diskContent(availableBytes: data.diskAvailableBytes, totalBytes: data.diskTotalBytes)
            case .networkRate: networkContent(rate: data.networkRate)
            }
        }
    }

    /// CPU:口径 = PulseFormat.cpuPercent(0–100%),超 70% 红——与可配置前
    /// 的双徽标同源,默认态逐像素一致的第一半。槽位按最大现实读数 "100%" 定宽。
    static func cpuContent(load: Double?) -> MenuBarBadgeContent {
        MenuBarBadgeContent(
            caption: "CPU",
            text: PulseFormat.cpuPercent(load ?? 0),
            emphasis: (load ?? 0) > cpuRedThreshold ? .critical : .normal,
            slotWidth: slotWidth(for: "100%")
        )
    }

    /// RAM:已用占总内存百分比,压力偏高橙/紧张红——默认态的第二半。
    /// 槽位同 CPU 按 "100%" 定宽;占位 "–" 也在定宽槽内,首轮前后不变宽。
    static func ramContent(memory: MemoryBreakdown?) -> MenuBarBadgeContent {
        guard let memory, memory.totalBytes > 0 else {
            return MenuBarBadgeContent(caption: "RAM", text: "–", emphasis: .normal, slotWidth: slotWidth(for: "100%"))
        }
        let percent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        let emphasis: MenuBarBadgeContent.Emphasis = switch memory.pressure {
        case .critical: .critical
        case .warning: .warning
        case .normal: .normal
        }
        return MenuBarBadgeContent(
            caption: "RAM",
            text: PulseFormat.cpuPercent(percent),
            emphasis: emphasis,
            slotWidth: slotWidth(for: "100%")
        )
    }

    /// 磁盘剩余:实际可用(important 口径)占容器总容量的百分比(2026-10-20 用户
    /// 拍板,替代 GB 整数);任一读数未到或总量为 0 占位 "—"。槽位同 CPU 按 "100%" 定宽。
    static func diskContent(availableBytes: Int64?, totalBytes: UInt64?) -> MenuBarBadgeContent {
        let text: String = if let availableBytes, let totalBytes, totalBytes > 0 {
            PulseFormat.cpuPercent(Double(max(0, availableBytes)) / Double(totalBytes) * 100)
        } else {
            "—"
        }
        return MenuBarBadgeContent(
            caption: "磁盘",
            text: text,
            emphasis: .normal,
            slotWidth: slotWidth(for: "100%")
        )
    }

    /// 网络:上行在上、下行在下叠两行(2026-10-20 用户拍板,Stats 同款),两行都恒
    /// 显示——不再超宽降级只留下载;数据未到两行各占位 "—"。槽位按两行里最宽的
    /// 现实读数 "↓999.9 KB/s"(跨到 MB 前的最长串)定宽。
    static func networkContent(rate: NetworkRates?) -> MenuBarBadgeContent {
        let upload = rate.map { PulseFormat.networkRateBadge($0.upBytesPerSecond) } ?? "—"
        let download = rate.map { PulseFormat.networkRateBadge($0.downBytesPerSecond) } ?? "—"
        return MenuBarBadgeContent(
            caption: "网络",
            text: "↑\(upload)\n↓\(download)",
            emphasis: .normal,
            slotWidth: slotWidth(for: "↓999.9 KB/s", fontSize: stackedFontSize),
            layout: .stacked
        )
    }

    /// 徽标数值字号(渲染器与槽位量宽共用的唯一出处,DESIGN.md 菜单栏特例)。
    static let valueFontSize: CGFloat = 11.5
    /// 叠两行版式的字号(DESIGN.md 菜单栏特例):两行合高不超过「7pt 标签 + 11.5pt
    /// 数字」的徽标高。
    static let stackedFontSize: CGFloat = 9

    /// 文本估算渲染宽(点):菜单栏字体实测——同字同字号必同宽,宽度判定
    /// 因此确定可测;徽标实际绘制带 monospacedDigit,此处允许近似。
    static func estimatedWidth(of text: String, fontSize: CGFloat = valueFontSize) -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: fontSize)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 槽位定宽 = 参考串(该指标最大现实读数形态)按**实际绘制字体**量宽 +
    /// 2pt 余量。不能用 estimatedWidth 量:等宽数字的 "1" 与其他数字同宽、
    /// 字重 medium,"100%" 比菜单栏常规字体宽 ~3pt——2026-10-19 前按常规字体
    /// 量,"100%" 溢出定宽槽被折成两行(用户反馈)。
    static func slotWidth(for reference: String, fontSize: CGFloat = valueFontSize) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        return ceil((reference as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}
