import AppKit
import SwiftUI

// 菜单栏徽标可配置(工单 09):槽位配置、配置 → 渲染输入的纯函数映射、
// 参数化位图渲染器。渲染先例的血泪教训沿用——MenuBarExtra 的 label 里
// 多张位图 Image 只渲染第一张,双徽标必须一次 ImageRenderer 合成**单张**
// 位图交系统(.renderingMode(.original),foregroundStyle 会被 NSStatusItem
// 剥掉,只有位图保得住颜色)。

// MARK: - 槽位配置

/// 徽标槽位指标(工单 09 四选一)。
enum MenuBarBadgeMetric: String, CaseIterable {
    case cpu
    case ram
    case diskRemaining
    case networkRate

    /// 设置页与无障碍文案。
    var label: String {
        switch self {
        case .cpu: "CPU 负载"
        case .ram: "内存占用"
        case .diskRemaining: "磁盘剩余"
        case .networkRate: "网络速率"
        }
    }
}

/// 槽位配置:1–3 个槽位,每槽一指标,顺序即菜单栏从左到右。
/// 以逗号连接的 rawValue 进 @AppStorage(RawRepresentable 直存),
/// 持久与"配置即时生效、重启保留"都由 UserDefaults 承担。
struct MenuBarBadgeConfiguration: Equatable, RawRepresentable {
    /// 合法槽位数(spec:1–3)。
    static let slotRange = 1...3
    /// 默认配置(Round-2 共识):CPU + RAM,与可配置前的现状一致。
    static let `default` = MenuBarBadgeConfiguration(slots: [.cpu, .ram])

    /// 降级(spec 验收):非法配置(空 / 超 3 槽)回落默认,不崩不猜。
    init(slots: [MenuBarBadgeMetric]) {
        self.slots = Self.slotRange.contains(slots.count) ? slots : Self.default.slots
    }

    /// 非法 rawValue(未知指标、空、数量越界)返回 nil,由调用方 `?? .default`
    /// 回默认——降级判定集中在一处,单测钉死。未知 token 不静默丢弃:
    /// 丢弃会把坏配置改写成另一个合法子集,宁可回默认让用户重选。
    init?(rawValue: String) {
        let tokens = rawValue.split(separator: ",")
        let metrics = tokens.compactMap { MenuBarBadgeMetric(rawValue: String($0)) }
        guard Self.slotRange.contains(metrics.count), metrics.count == tokens.count else { return nil }
        self.slots = metrics
    }

    var slots: [MenuBarBadgeMetric]

    var rawValue: String {
        slots.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - 数据快照与渲染输入

/// 徽标数据快照:视图层从 SystemMonitor 折叠而来,映射纯函数的唯一输入
/// (全部合成值可注入,单测不触碰真实采样)。
struct MenuBarBadgeData: Equatable {
    /// 系统 CPU 负载 0–100(GLOSSARY 口径);nil 视同 0(与旧标签一致)。
    var cpuLoadPercent: Double?
    /// 内存构成:RAM 占比与压力变色的来源;nil = 首轮前,占位。
    var memory: MemoryBreakdown?
    /// 磁盘实际可用字节(important 口径,工单 05 的 lastGood);nil = 未到读数。
    var diskAvailableBytes: Int64?
    /// 网络速率(工单 06 填充):直用 NetworkSensor 的 NetworkRates——09 的
    /// 壳契约副本已并入该类型(字段不再两次转译);nil = 未上线/未到读数,占位。
    var networkRate: NetworkRates?
}

/// 单枚徽标的渲染输入:纯值语义,不含 SwiftUI 颜色——强调级别由渲染器
/// 映射成色,缓存键得以用值比较(Equatable)。
struct MenuBarBadgeContent: Equatable {
    /// 数字上方的小标签("CPU"/"RAM"/"磁盘"/"网络")。
    let caption: String
    let text: String
    /// 强调级:normal = 墨色随外观,warning = 橙,critical = 红。
    let emphasis: Emphasis

    enum Emphasis: Equatable {
        case normal
        case warning
        case critical
    }
}

// MARK: - 配置 → 渲染输入(纯函数,spec 钉死的测试缝)

/// 槽位配置 × 数据快照 → 有序徽标内容。降级规则全在此折叠:
/// 读数缺失占位("–"/"—",不伪造);网络紧凑双行放不下 → 只显示下载。
enum MenuBarBadgeComposer {
    /// 网络徽标宽度预算(点,策略常量):紧凑双行典型宽 115–125pt、
    /// 超宽数字 ≥135pt(本机菜单栏字体实测),预算取中间 132——典型速率
    /// 保持双行,数字过长(三位整数百 MB 级对撞)自动降级只显示下载。
    static let networkWidthBudget: CGFloat = 132

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
            case .diskRemaining: diskContent(availableBytes: data.diskAvailableBytes)
            case .networkRate: networkContent(rate: data.networkRate)
            }
        }
    }

    /// CPU:口径 = PulseFormat.cpuPercent(0–100%),超 70% 红——与可配置前
    /// 的双徽标同源,默认态逐像素一致的第一半。
    static func cpuContent(load: Double?) -> MenuBarBadgeContent {
        MenuBarBadgeContent(
            caption: "CPU",
            text: PulseFormat.cpuPercent(load ?? 0),
            emphasis: (load ?? 0) > cpuRedThreshold ? .critical : .normal
        )
    }

    /// RAM:已用占总内存百分比,压力偏高橙/紧张红——默认态的第二半。
    static func ramContent(memory: MemoryBreakdown?) -> MenuBarBadgeContent {
        guard let memory, memory.totalBytes > 0 else {
            return MenuBarBadgeContent(caption: "RAM", text: "–", emphasis: .normal)
        }
        let percent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        let emphasis: MenuBarBadgeContent.Emphasis = switch memory.pressure {
        case .critical: .critical
        case .warning: .warning
        case .normal: .normal
        }
        return MenuBarBadgeContent(caption: "RAM", text: PulseFormat.cpuPercent(percent), emphasis: emphasis)
    }

    /// 磁盘剩余:实际可用(important 口径)十进制 GB 整数,读数未到占位 "—"。
    static func diskContent(availableBytes: Int64?) -> MenuBarBadgeContent {
        MenuBarBadgeContent(caption: "磁盘", text: PulseFormat.diskRemainingBadge(availableBytes), emphasis: .normal)
    }

    /// 网络:紧凑上下行 "↓下载 ↑上传";数据未到占位 "—";
    /// 紧凑文本估算渲染宽超预算 → 降级只显示下载。
    static func networkContent(rate: NetworkRates?) -> MenuBarBadgeContent {
        guard let rate else {
            return MenuBarBadgeContent(caption: "网络", text: "—", emphasis: .normal)
        }
        let download = PulseFormat.networkRateBadge(rate.downBytesPerSecond)
        let upload = PulseFormat.networkRateBadge(rate.upBytesPerSecond)
        let compact = "↓\(download) ↑\(upload)"
        if estimatedWidth(of: compact) <= networkWidthBudget {
            return MenuBarBadgeContent(caption: "网络", text: compact, emphasis: .normal)
        }
        return MenuBarBadgeContent(caption: "网络", text: "↓\(download)", emphasis: .normal)
    }

    /// 文本估算渲染宽(点):菜单栏字体实测——同字同字号必同宽,宽度判定
    /// 因此确定可测;徽标实际绘制带 monospacedDigit,此处允许近似。
    static func estimatedWidth(of text: String, fontSize: CGFloat = 11.5) -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: fontSize)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

// MARK: - 位图渲染器(参数化,单张合成)

/// 容量有界的 LRU 字典(纯逻辑):命中把键挪到最新,插入超容淘汰最旧。
/// 渲染器缓存的记账与淘汰规则单测钉在这里;值类型不设约束(NSImage 存取
/// 留在渲染器侧)。实现只有一张访问序表 + 一个字典,规模 ≤ 容量,线性
/// 移除即可,不值得上双向链表。
struct LRUBoundedCache<Key: Hashable, Value> {
    let capacity: Int
    private(set) var order: [Key] = []
    private var storage: [Key: Value] = [:]

    init(capacity: Int) {
        precondition(capacity > 0, "LRU 容量必须为正")
        self.capacity = capacity
    }

    /// 命中读值(并把键记为最新);未命中返回 nil。
    mutating func hit(_ key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// 插入/更新(键记为最新;超容淘汰最旧)。
    mutating func insert(_ value: Value, forKey key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// 菜单栏徽标位图渲染器:渲染输入数组 → ImageRenderer → 单张 NSImage,按
/// (全部内容, 外观) 缓存——每轮采样最多一次位图化,值不变时零开销。
/// 缓存键为纯函数(单测钉死"配置变键变"):槽位顺序 / 文案 / 强调级 /
/// 外观任一变化都换键,内容相同的不同配置共享缓存不亏。
/// 缓存有界(评审修复):徽标文案逐轮变新键(网络速率数字刷新最频),
/// 无上限会常驻数周持续累积;上限 ~20 项——新旧键命中率稳态极高(负载/
/// 内存/磁盘数字变化低频,网络速率在几秒窗内来回切换仍命中),被挤出的
/// 旧键下次复访只重渲染一次(数毫秒),换来内存有界。
@MainActor
enum MenuBarBadgeRenderer {
    static let cacheCapacity = 20
    private static var cache = LRUBoundedCache<String, NSImage>(capacity: cacheCapacity)

    static func image(for contents: [MenuBarBadgeContent], colorScheme: ColorScheme) -> NSImage {
        let key = cacheKey(for: contents, colorScheme: colorScheme)
        if let cached = cache.hit(key) { return cached }

        let ink = colorScheme == .dark ? Color.white : Color.black
        let renderer = ImageRenderer(
            content: HStack(alignment: .center, spacing: 5) {
                ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                    badge(
                        caption: content.caption,
                        valueText: content.text,
                        valueColor: color(for: content.emphasis, ink: ink),
                        ink: ink
                    )
                }
            }
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let rendered: NSImage
        if let nsImage = renderer.nsImage {
            rendered = nsImage
        } else {
            // ImageRenderer 失效兜底:退回单行纯文本(不变色,但读数可见)。
            let text = contents.map(\.text).joined(separator: "  ")
            let width = ceil(MenuBarBadgeComposer.estimatedWidth(of: text)) + 4
            let fallback = NSImage(size: NSSize(width: max(16, width), height: 18))
            fallback.lockFocus()
            (text as NSString).draw(
                at: NSPoint(x: 2, y: 2),
                withAttributes: [
                    .font: NSFont.menuBarFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            fallback.unlockFocus()
            rendered = fallback
        }
        rendered.isTemplate = false // 绝不让系统把颜色又模板化掉
        cache.insert(rendered, forKey: key)
        return rendered
    }

    /// 缓存键(纯函数):外观 + 全部徽标内容。槽位配置的差异完全由内容承载
    /// (顺序 = 数组序,caption/text/emphasis 逐枚进键)。
    static func cacheKey(for contents: [MenuBarBadgeContent], colorScheme: ColorScheme) -> String {
        let body = contents
            .map { "\($0.caption)|\($0.text)|\($0.emphasis)" }
            .joined(separator: ";")
        return "\(colorScheme == .dark ? "dark" : "light")|\(body)"
    }

    /// 单枚徽标:小标签在数字上方(与可配置前的双徽标逐像素同款)。
    private static func badge(caption: String, valueText: String, valueColor: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(ink.opacity(0.55))
            Text(valueText)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 1)
    }

    /// 强调级 → 色:normal 墨色随外观,warning 橙,critical 红。
    private static func color(for emphasis: MenuBarBadgeContent.Emphasis, ink: Color) -> Color {
        switch emphasis {
        case .normal: ink
        case .warning: .orange
        case .critical: .red
        }
    }
}
