import Foundation

// MARK: - 告警归因(纯):「到底是谁在吃资源」(NemoNotch toast 投递的原料)

//
// 触发时刻的组排行 + 进程 CPU 差分 → 人读摘要。归因口径 = **触发当轮**的实时
// 快照,不是告警起始时刻——告警要连续越阈多轮才发,用户收到卡片时想知道的是
// 「现在是谁在吃」,这正是当轮排行的语义。磁盘不足/dev server 闲置没有进程
// 归因(磁盘满是历史累计,不是当下某个进程吃的),返回空摘要,不硬造。
//
// 引擎喂食的是组聚合,组内进程明细在 ProcessGroup.processes 里(引擎契约:
// 进程 CPU% 降序、次键 pid 升序)——CPU 类直接取既定顺序,内存类按物理足迹
// 重排。全部纯函数,单测见 AlertOffenderTests。

/// 一名「嫌疑进程」:人读名 + 本轮 CPU% + 物理足迹。
public struct AlertOffenderEntry: Equatable, Sendable {
    /// 进程人读名(PulseFormat.processName 口径:可执行名,兜底 "pid N")。
    public let name: String
    /// 本轮 CPU%(单核 100% 累加口径)。nil = 本轮新出生、尚无差分——如实
    /// 缺席,不伪造 0(下钻同款区别:那里显示 0,这里省略百分号)。
    public let cpuPercent: Double?
    /// 物理足迹(与活动监视器"内存"列同口径),字节。
    public let memoryBytes: UInt64

    public init(name: String, cpuPercent: Double?, memoryBytes: UInt64) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// 一条告警的归因摘要:承载组 + 前几名进程。
public struct AlertOffenderSummary: Equatable, Sendable {
    /// 承载组显示名(系统级告警 = 当轮 CPU 第一名组);nil = 无归因。
    public let groupName: String?
    /// 前几名进程(CPU 类按组内既定顺序;内存类按足迹降序)。
    public let entries: [AlertOffenderEntry]

    /// 无归因(磁盘 / dev server 闲置,或组在当轮已不在场)。
    public static let none = AlertOffenderSummary(groupName: nil, entries: [])

    public init(groupName: String?, entries: [AlertOffenderEntry]) {
        self.groupName = groupName
        self.entries = entries
    }
}

/// 归因计算(纯函数,无状态):告警触发事件 × 当轮组上下文 → 摘要。
public enum AlertOffenderAttribution {
    /// 摘要里最多列出的进程数(toast 正文宽度与信息量的折中)。
    public static let entryLimit = 3

    /// 计算一条告警的归因。
    ///
    /// - systemLoad:全机 CPU 第一名组(组表引擎契约已按 CPU% 降序)+ 该组前几名;
    /// - groupCPU / newGroupMemory:按 subjectKey 命中的组(groupCPU 取组内既定
    ///   CPU 降序,newGroupMemory 按物理足迹降序重排);
    /// - diskAvailable / devServerIdle:无归因。
    public static func summarize(
        occurrence: AlertOccurrence,
        groups: [ProcessGroup],
        cpuPercentByPID: [pid_t: Double]
    ) -> AlertOffenderSummary {
        switch occurrence.kind {
        case .systemLoad:
            // groups 是当轮全部组、CPU% 降序(RoundContext 契约),first 即第一名。
            guard let top = groups.first else { return .none }
            return summary(for: top, cpuPercentByPID: cpuPercentByPID)
        case .groupCPU:
            guard let group = groups.first(where: {
                AlertEngine.subjectKey(of: $0.id) == occurrence.subjectKey
            }) else { return .none }
            return summary(for: group, cpuPercentByPID: cpuPercentByPID)
        case .newGroupMemory:
            guard let group = groups.first(where: {
                AlertEngine.subjectKey(of: $0.id) == occurrence.subjectKey
            }) else { return .none }
            // 内存告警按物理足迹排——组内既定顺序是 CPU 序,与「谁占内存」错位。
            return AlertOffenderSummary(
                groupName: group.name,
                entries: group.processes
                    .sorted { $0.physicalFootprintBytes > $1.physicalFootprintBytes }
                    .prefix(entryLimit)
                    .map { entry(for: $0, cpuPercentByPID: cpuPercentByPID) }
            )
        case .diskAvailable, .devServerIdle:
            return .none
        }
    }

    /// 组 → 摘要:进程取组内既定顺序(CPU% 降序)的前几名。
    private static func summary(
        for group: ProcessGroup, cpuPercentByPID: [pid_t: Double]
    ) -> AlertOffenderSummary {
        AlertOffenderSummary(
            groupName: group.name,
            entries: group.processes
                .prefix(entryLimit)
                .map { entry(for: $0, cpuPercentByPID: cpuPercentByPID) }
        )
    }

    private static func entry(
        for process: RawProcess, cpuPercentByPID: [pid_t: Double]
    ) -> AlertOffenderEntry {
        AlertOffenderEntry(
            name: PulseFormat.processName(
                executablePath: process.executablePath,
                argv: process.argv,
                pid: process.pid
            ),
            cpuPercent: cpuPercentByPID[process.pid],
            memoryBytes: process.physicalFootprintBytes
        )
    }
}
