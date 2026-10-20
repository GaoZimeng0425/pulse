import Foundation

// MARK: - 下钻状态(工单 06):最近一轮采样留给下钻 UI 的只读输入

/// 下钻状态:一次采样落地时由 SystemMonitor 构建、之后只读。
/// 组卡展开 / 进程详情全部从这里取数——**下钻绝不触发额外采集**(spec),
/// 展开只是读最近一轮采样的既有数据。
public struct DrilldownState: Equatable, Sendable {
    /// 最近一张快照:活链父进程与进程原始记录(cwd / argv / 启动时刻)的来源。
    public let snapshot: ProcessSnapshot
    /// 截至最近一轮采样累计的出生登记表:断链面包屑的来源。
    public let lineage: LineageRegistry
    /// 最近差分的进程 CPU%(单核 100% 口径);新出生(nil)与缺条目按 0 计——
    /// 与组 CPU 聚合同口径。
    private let cpuPercentByPID: [pid_t: Double]

    public init(snapshot: ProcessSnapshot, lineage: LineageRegistry, processCPU: [ProcessCPU]) {
        self.snapshot = snapshot
        self.lineage = lineage
        self.cpuPercentByPID = processCPU.cpuPercentByPID
    }

    /// 组内进程行(展开列表):保持组的既定顺序(引擎契约:进程 CPU% 降序、次键 pid 升序)。
    public func rows(for group: ProcessGroup) -> [ProcessRowModel] {
        group.processes.map { process in
            ProcessRowModel(
                pid: process.pid,
                name: PulseFormat.processName(
                    executablePath: process.executablePath,
                    argv: process.argv,
                    pid: process.pid
                ),
                cpuPercent: cpuPercentByPID[process.pid] ?? 0,
                memoryBytes: process.physicalFootprintBytes
            )
        }
    }

    /// 进程详情(点进程行后的展开块):原始记录 + 父链面包屑。
    /// pid 已不在最近采样(下钻期间退出)→ nil,由 UI 安静收起。
    public func detail(for pid: pid_t) -> ProcessDetailModel? {
        guard let process = snapshot.processes.first(where: { $0.pid == pid }) else {
            return nil
        }
        return ProcessDetailModel(
            process: process,
            parentChainNames: ParentChainQuery.breadcrumbNames(
                for: pid,
                in: snapshot,
                lineage: lineage
            )
        )
    }
}

// MARK: - 视图模型

/// 进程行视图模型:名字 / pid / CPU% / 内存——展开列表的行内四要素。
public struct ProcessRowModel: Equatable, Sendable, Identifiable {
    public let pid: pid_t
    public let name: String
    /// 单核 100% 口径(可超 100),与组 CPU% 同源差分。
    public let cpuPercent: Double
    /// 物理足迹字节(活动监视器"内存"列口径)。
    public let memoryBytes: UInt64

    public var id: pid_t { pid }

    public init(pid: pid_t, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// 进程详情视图模型:原始记录 + 父链面包屑原料。
public struct ProcessDetailModel: Equatable, Sendable {
    /// cwd / 完整 argv / 启动时刻的直接来源。
    public let process: RawProcess
    /// 父链显示名,自身在前、有归属的祖先殿后("rustc ← cargo ← node ← Zcode" 的原料)。
    public let parentChainNames: [String]

    /// 面包屑一行文案:名与名之间以 " ← " 连接。
    public var parentChainText: String {
        parentChainNames.joined(separator: " ← ")
    }

    public init(process: RawProcess, parentChainNames: [String]) {
        self.process = process
        self.parentChainNames = parentChainNames
    }
}
