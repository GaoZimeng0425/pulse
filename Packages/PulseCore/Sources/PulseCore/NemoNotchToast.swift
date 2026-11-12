import Foundation

// MARK: - NemoNotch 外部 toast(公开契约 v1)

//
// 契约出处:NemoNotch `docs/external-toast-agent-guide.md`(端点发现与 HTTP
// 发送属 Live 适配器,在 app target 的 NemoNotchToastSender;本文件只有可单测
// 的纯逻辑:载荷模型 + 告警文案拼装)。要点:
//
// - `POST http://127.0.0.1:<port>/v1/toast`,端口/令牌读 `~/.NemoNotch/` 下
//   两个文件,令牌缺失静默跳过,任何失败不影响宿主主流程;
// - 字段上限:app ≤48、key ≤128、title ≤120、body ≤280;`app`/`key` 禁含 `::`;
// - 带同一 `key` 的推送整体替换同一张卡(持续状态卡)——告警冷却期后重发
//   用稳定 key,同一主体永远只占一张卡,不堆叠。

/// 契约载荷(字段名即 JSON 键;`schema`/`app`/`title` 恒定,其余可缺省)。
public struct NemoNotchToastPayload: Equatable, Sendable {
    /// 契约 schema 版本(固定 1;其它值 NemoNotch 侧 400)。
    public static let schema = 1
    /// 宿主应用显示名(卡片归属;Pulse 恒定,≤48)。
    public static let appName = "Pulse"

    /// 持续状态卡键(同 key 整卡替换);nil = 一次性卡。
    public let key: String?
    public let title: String
    public let body: String?
    /// 仅 `sf:<SF Symbol 名>`;未知符号名 NemoNotch 侧回落通用图标,不报错。
    public let icon: String?
    /// 点击卡片激活该 bundle id 的应用;nil = 点击只关卡。
    public let jumpBundleId: String?

    public init(
        key: String?,
        title: String,
        body: String?,
        icon: String?,
        jumpBundleId: String?
    ) {
        self.key = key
        self.title = title
        self.body = body
        self.icon = icon
        self.jumpBundleId = jumpBundleId
    }

    /// 请求体封套:payload + 恒定的 schema/app。字段名即契约 JSON 键(合成
    /// Encodable 对 nil 可选走 encodeIfPresent,契约的"缺省即未提供"天然满足)。
    public var envelope: NemoNotchToastEnvelope {
        NemoNotchToastEnvelope(payload: self)
    }
}

/// POST `/v1/toast` 的请求体(只编码,不回读——发送是单向的)。
public struct NemoNotchToastEnvelope: Encodable, Sendable {
    public let schema: Int
    public let app: String
    public let key: String?
    public let title: String
    public let body: String?
    public let icon: String?
    public let jumpBundleId: String?

    public init(payload: NemoNotchToastPayload) {
        schema = NemoNotchToastPayload.schema
        app = NemoNotchToastPayload.appName
        key = payload.key
        title = payload.title
        body = payload.body
        icon = payload.icon
        jumpBundleId = payload.jumpBundleId
    }
}

/// 告警 → toast 载荷(纯拼装,单测钉死文案与契约上限)。
///
/// 四类进 toast(2026-11-01 拍板:A + 磁盘不足):系统负载 / 组 CPU / 新组内存 /
/// 磁盘不足;dev server 闲置与「谁在消耗资源」无关,返回 nil 不发。
public enum NemoNotchToastContent {
    /// 契约上限(NemoNotch 侧超限即 400,拼装侧必须钳住)。
    public static let titleLimit = 120
    public static let bodyLimit = 280
    public static let keyLimit = 128

    /// 拼装一条告警的 toast 载荷;nil = 该种类不进 toast。
    ///
    /// 文案原则:标题点名「谁」(承载组),正文列「哪些进程、各占多少」——
    /// 卡片存在的意义就是让用户不打开 Pulse 也知道该去找谁。
    public static func make(
        for occurrence: AlertOccurrence,
        offender: AlertOffenderSummary,
        jumpBundleId: String?
    ) -> NemoNotchToastPayload? {
        switch occurrence.kind {
        case .systemLoad:
            let who = offender.groupName.map { ":\($0)" } ?? ""
            return NemoNotchToastPayload(
                key: key(for: occurrence),
                title: clamp("系统负载过高\(who)", to: titleLimit),
                body: clamp(AlertOffenderAttribution.bodyText(
                    lead: "最耗 CPU", entries: offender.entries,
                    metric: { entry in entry.cpuPercent.map { PulseFormat.cpuPercent($0) } }
                ), to: bodyLimit),
                icon: "sf:cpu",
                jumpBundleId: jumpBundleId
            )
        case .groupCPU:
            return NemoNotchToastPayload(
                key: key(for: occurrence),
                title: clamp(
                    "「\(occurrence.subjectName ?? "组")」CPU \(PulseFormat.cpuPercent(occurrence.value))",
                    to: titleLimit
                ),
                body: clamp(AlertOffenderAttribution.bodyText(
                    lead: "最耗 CPU", entries: offender.entries,
                    metric: { entry in entry.cpuPercent.map { PulseFormat.cpuPercent($0) } }
                ), to: bodyLimit),
                icon: "sf:cpu",
                jumpBundleId: jumpBundleId
            )
        case .newGroupMemory:
            return NemoNotchToastPayload(
                key: key(for: occurrence),
                title: clamp(
                    "新组「\(occurrence.subjectName ?? "未知")」内存 \(PulseFormat.memory(UInt64(max(0, occurrence.value))))",
                    to: titleLimit
                ),
                body: clamp(AlertOffenderAttribution.bodyText(
                    lead: "占内存最多", entries: offender.entries,
                    metric: { entry in PulseFormat.memory(entry.memoryBytes) }
                ), to: bodyLimit),
                icon: "sf:memorychip",
                jumpBundleId: jumpBundleId
            )
        case .diskAvailable:
            // 磁盘满是历史累计,归因不到当下某个进程——不硬造,正文沿用系统通知口径。
            return NemoNotchToastPayload(
                key: key(for: occurrence),
                title: "磁盘可用不足",
                body: clamp("可用 \(PulseFormat.diskCapacity(UInt64(max(0, occurrence.value)))),剩余空间紧张。", to: bodyLimit),
                icon: "sf:internaldrive",
                jumpBundleId: jumpBundleId
            )
        case .devServerIdle:
            return nil
        }
    }

    /// 持续状态卡键:种类 + 主体(系统级主体即种类本身)。同主体重发整卡替换。
    /// stableKey 含路径,须消毒契约禁用的 `::` 并钳长。
    static func key(for occurrence: AlertOccurrence) -> String {
        let raw = "alert|\(occurrence.kind.rawValue)|\(occurrence.subjectKey)"
            .replacingOccurrences(of: "::", with: "||")
        return String(raw.prefix(keyLimit))
    }

    /// 钳长(契约上限按 Swift 字符计;前置信息在前的文案截尾不伤「谁」)。
    static func clamp(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
