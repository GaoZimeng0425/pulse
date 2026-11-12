import Foundation
import Observation
import PulseCore

/// AI 助手会话功能模块(智能体 tab,agent-tab/01;ADR-0003 MonitorFeature):薄壳 +
/// 纯值内核 AgentSessionCatalog(注册表 / jsonl 尾读 / 用量快照 / ZCode metadata 的
/// 解析与节流,单测见 PulseCoreTests.AgentSessionModelTests)。每轮心跳推进:文件读
/// 按 catalog 内部节流(≥5s 一轮),节流轮只按 pid 存活过滤缓存并重算时长;实例
/// 退出 ≤1 轮内下榜。智能体 tab 卡片直读 `snapshot`。
@Observable
@MainActor
final class AgentSessionFeature: MonitorFeature {
    /// 本轮聚合:Claude 实例行 / 订阅用量 / ZCode 会话行;无会话为空集。
    private(set) var snapshot: AgentSnapshot = .empty

    @ObservationIgnored private let reader: any AgentSessionReading
    @ObservationIgnored private var catalog = AgentSessionCatalog()

    init(reader: any AgentSessionReading) {
        self.reader = reader
    }

    /// 盘点时刻与快照同一时间轴(不另取钟)。
    func onRound(_ context: RoundContext) {
        let alivePids = Set(context.update.snapshot.processes.map(\.pid))
        let next = catalog.update(reader: reader, alivePids: alivePids, now: context.takenAt)
        if next != snapshot {
            snapshot = next
        }
    }
}
