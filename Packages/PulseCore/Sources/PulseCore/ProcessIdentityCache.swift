import Foundation

/// 活链扫描的身份缓存(工单 10 采样成本优化):身份三元组(可执行路径 / cwd /
/// argv,ProcessIdentity D1)在首次见到 pid 时读一次,此后采样轮直接复用——
/// 归组引擎每轮消费的正是快照里的这份三元组,缓存值即快照值。
///
/// 失配与校正策略(工单拍板二选一:**采样轮低频校正**,不做失配检测):
/// - **exec / pid 复用即时捕获**:每轮反正要读一次进程表(resident-cost/01 3a
///   起为一趟 KERN_PROC_ALL,此前为逐 pid KERN_PROC),顺带比对 p_comm——
///   exec 即换名,内核保证;不一致立即重读整组身份,零额外系统调用。
/// - **cwd 低频校正**:chdir 没有任何免费失配信号,任何"检测"都得先读一次
///   VNODEPATHINFO,与直接重读同价——故不做检测,按 `refreshInterval`
///   低频重读。校正重读整组三元组(同一条读取路径),顺带把"同前缀改名
///   exec"这一 p_comm 残余盲区也钉进同一个可见上界。
///
/// 账目(resident-cost/01 3a 后):稳态轮每进程 2 次调用(PROC_PIDTASKINFO +
/// rusage)+ 每轮一趟 KERN_PROC_ALL 全表(ppid / p_comm / 启动时刻全在手);
/// 校正轮该进程 +3 次身份调用。纯值类型,决策可单测;宿主(LiveProcessSource)
/// 负责真实读取与加锁。
public struct ProcessIdentityCache: Sendable {
    /// 一条缓存:身份三元组 + exec 指纹 + 校准时刻。
    public struct Entry: Sendable {
        public let identity: ProcessIdentity
        /// KERN_PROC 的 p_comm(exec 即换名)。
        public let commandName: String
        /// 身份上次读取(校准)时刻,cwd 校正的时间轴。
        public let readAt: Date

        public init(identity: ProcessIdentity, commandName: String, readAt: Date) {
            self.identity = identity
            self.commandName = commandName
            self.readAt = readAt
        }
    }

    /// cwd 低频校正间隔 60s:5s 采样节奏下约每 12 轮校正一次,平均每进程
    /// +0.25 次调用/轮;cwd 漂移对归组的可见上界即 1 分钟(工单 07 新增
    /// 项目根后,已坐进根里的进程最迟 1 分钟入组)。
    public static let refreshInterval: TimeInterval = 60

    public private(set) var entries: [pid_t: Entry] = [:]

    /// 命中 = 已缓存 ∧ p_comm 一致 ∧ 未过校正期;未命中返回 nil,调用方重读。
    public func identity(pid: pid_t, commandName: String, now: Date) -> ProcessIdentity? {
        guard let entry = entries[pid],
              entry.commandName == commandName,
              now.timeIntervalSince(entry.readAt) < Self.refreshInterval
        else { return nil }
        return entry.identity
    }

    /// 记录(首次读取)或覆盖(低频校正 / exec 重读)——后写为准。
    public mutating func record(
        pid: pid_t, identity: ProcessIdentity, commandName: String, at date: Date
    ) {
        entries[pid] = Entry(identity: identity, commandName: commandName, readAt: date)
    }

    /// 逐出已消失的 pid(每轮对存活集裁剪):pid 复用前缓存必已清空,
    /// 与 p_comm 比对构成双保险。
    public mutating func prune(keeping pids: Set<pid_t>) {
        entries = entries.filter { pids.contains($0.key) }
    }

    public init(entries: [pid_t: Entry] = [:]) {
        self.entries = entries
    }
}
