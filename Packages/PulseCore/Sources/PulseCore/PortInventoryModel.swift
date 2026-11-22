import Foundation

// MARK: - 全局端口盘点(监听端口卡,工单 port-view/01)

//
// 口径(GLOSSARY「监听端口」):全机正在等待连入的 TCP 端口及占用进程;
// 仅 TCP 监听态(UDP 与已连接的 TCP 不算),root 进程的端口受系统限制读不到、
// 如实缺行——UI 卡脚一行小字如实注明,不伪造。词汇纪律:不造「孤儿端口」
// (GLOSSARY「孤儿进程」已占用「孤儿」);dev server 占口以闲置标注呈现。
// 处置永远由人确认(行「结束」→ KillRequestFlow 同款关口),这里只盘点不杀。

/// 端口行的占用者:pid + 显示名 + dev server 标注(非 dev server 标注为 nil)。
public struct PortHolder: Equatable, Sendable, Identifiable {
    public let pid: pid_t
    /// 显示名,与处置目标同口径(可执行 basename → argv[0] → "pid N");
    /// 扫描见到但快照尚无身份的进程兜底为 "pid N"。
    public let name: String
    /// dev server 种类;非 dev server 为 nil。
    public let devServerKind: DevServerKind?
    /// dev server 闲置时长;非 dev server 为 nil。
    public let idleSeconds: TimeInterval?

    public var id: pid_t {
        pid
    }

    public init(pid: pid_t, name: String, devServerKind: DevServerKind? = nil, idleSeconds: TimeInterval? = nil) {
        self.pid = pid
        self.name = name
        self.devServerKind = devServerKind
        self.idleSeconds = idleSeconds
    }

    /// 处置目标:行「结束」按钮的输入(确认单点名用,与全 app 处置同单元)。
    public var killTarget: KillTarget {
        KillTarget(pid: pid, name: name)
    }
}

/// 一个监听端口:同一端口被多个进程共占(SO_REUSEPORT / worker 组)时如实并列,
/// 行级「结束」一次处置全部持有者。
public struct PortEntry: Equatable, Sendable, Identifiable {
    public let port: UInt16
    /// 占用进程,pid 升序(稳定展示序)。
    public let holders: [PortHolder]

    public var id: UInt16 {
        port
    }

    public init(port: UInt16, holders: [PortHolder]) {
        self.port = port
        self.holders = holders
    }
}

/// 全机监听端口盘点:端口号升序,默认视图截断前 limit 行(totalCount 保全量)。
public struct PortInventory: Equatable, Sendable {
    /// 展示行(≤ limit,端口号升序)。
    public let entries: [PortEntry]
    /// 全部监听端口数(含被截断的)。
    public let totalCount: Int

    public init(allEntries: [PortEntry], limit: Int) {
        let sorted = allEntries.sorted { $0.port < $1.port }
        totalCount = sorted.count
        entries = Array(sorted.prefix(max(0, limit)))
    }

    public var isTruncated: Bool {
        totalCount > entries.count
    }
}

/// 端口扫描接缝(批量方向,ADR-0004 薄缝):真实现 libproc 直调(拷
/// LiveDevServerPortScanner 三步,改吃 pid 列表),单测注入假实现合成端口表。
/// 与单 pid 的 `DevServerPortScanning`(只扫 argv 命中的候选)相对,
/// 这是全机方向——成本由功能模块的可见性闸 + 传感器档位约束。
public protocol GlobalPortScanning: Sendable {
    /// 每个进程监听中的 TCP 端口(升序去重);未列出的 pid = 无监听 / 受限 / 已退。
    func listeningPorts(pids: [pid_t]) -> [pid_t: [UInt16]]
}

/// 监听端口卡的版面数值单一出处(port-view/01;DESIGN.md 令牌
/// `{layout.port-row-limit}`——先补表再写码的规矩,此处是与令牌对齐的代码侧)。
public enum PortsCardMetrics {
    /// 默认展示行上限:超出末行「显示全部」展开收起(排行截断同款交互)。
    public static let rowLimit = 20
}

/// 盘点纯逻辑:扫描结果 × 快照进程身份 × dev server 盘点 → 端口行。
/// 无自有状态(扫描由功能模块的传感器驱动),纯函数可直接复入。
public struct PortInventoryFinder: Sendable {
    public init() {}

    /// 合成一轮盘点。scan 里的 pid 不在快照(扫描与快照的时间差窗口)时
    /// 名字兜底 "pid N",不丢行——端口在就该看见。
    public func inventory(
        scan: [pid_t: [UInt16]],
        snapshot: ProcessSnapshot,
        devServers: [DevServerStatus],
        limit: Int
    ) -> PortInventory {
        let processes = snapshot.processesByPID
        let servers = Dictionary(devServers.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        // 端口 → 持有者聚合:展开每 pid 的端口集,同口多 pid 并列一行。
        var byPort: [UInt16: [PortHolder]] = [:]
        for (pid, ports) in scan {
            let process = processes[pid]
            let server = servers[pid]
            let holder = PortHolder(
                pid: pid,
                name: process?.killTarget.name ?? "pid \(pid)",
                devServerKind: server?.kind,
                idleSeconds: server?.idleSeconds
            )
            for port in Set(ports) where port != 0 {
                byPort[port, default: []].append(holder)
            }
        }
        let entries = byPort.map { port, holders in
            PortEntry(port: port, holders: holders.sorted { $0.pid < $1.pid })
        }
        return PortInventory(allEntries: entries, limit: limit)
    }
}
