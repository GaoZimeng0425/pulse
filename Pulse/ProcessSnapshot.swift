import Foundation

/// 归属判定三元组(P0 评审 D1 收拢,工单 00):可执行路径 / 工作目录 / argv
/// ——归组引擎与出生登记判定归属时总是结伴消费的三个字段,存储与传递只有这一份
/// (此前在 `RawProcess` 与 `LineageRegistry.Entry` 各平铺一份)。
struct ProcessIdentity: Equatable, Sendable {
    /// 可执行路径(proc_pidpath);受限 / 查不到 → nil。
    let executablePath: String?
    /// 工作目录(PROC_PIDVNODEPATHINFO);受限 → nil。
    let cwd: String?
    /// 完整 argv(KERN_PROCARGS2,已跳过 execpath);受限 → 空数组。
    let argv: [String]

    init(executablePath: String? = nil, cwd: String? = nil, argv: [String] = []) {
        self.executablePath = executablePath
        self.cwd = cwd
        self.argv = argv
    }
}

/// 原始进程:采集层对单个进程采到的全部字段,快照的组成单元。
/// 纯 Swift 值类型;受限查询的字段静默降级为 nil / 空数组,绝不因此丢弃字段以外的信息。
struct RawProcess: Identifiable, Equatable, Sendable {
    /// 进程 ID,同时是稳定身份(pid 存活期间不变)。
    let pid: pid_t
    /// 父进程 ID;launchd(pid 1)的父为 0。父链上溯归组的依据。
    let parentPID: pid_t
    /// 归属判定三元组(D1):路径 / cwd / argv 存储只有这一份。
    let identity: ProcessIdentity
    /// 累计 CPU 时间(user + system,纳秒)。CPU% 由相邻快照差分得出(后续工单)。
    let cpuTimeNanoseconds: UInt64
    /// 常驻内存(pti_resident_size),字节。
    let residentMemoryBytes: UInt64
    /// 物理足迹(ri_phys_footprint),字节,与活动监视器"内存"列同口径。
    let physicalFootprintBytes: UInt64
    /// 累计磁盘读字节(ri_diskio_bytesread)。
    let diskBytesRead: UInt64
    /// 累计磁盘写字节(ri_diskio_byteswritten)。
    let diskBytesWritten: UInt64
    /// 启动时刻(KERN_PROC 的 p_starttime);查不到 → nil。
    let startTime: Date?

    var id: pid_t { pid }

    /// 可执行路径(身份三元组的直读视图,采集与展示层的既有通道)。
    var executablePath: String? { identity.executablePath }
    /// 完整 argv(身份三元组的直读视图)。
    var argv: [String] { identity.argv }
    /// 工作目录(身份三元组的直读视图)。
    var cwd: String? { identity.cwd }

    /// 采集层构造口径不变:字段平铺入参,内部归拢进 ProcessIdentity。
    init(
        pid: pid_t,
        parentPID: pid_t,
        executablePath: String? = nil,
        argv: [String] = [],
        cwd: String? = nil,
        cpuTimeNanoseconds: UInt64 = 0,
        residentMemoryBytes: UInt64 = 0,
        physicalFootprintBytes: UInt64 = 0,
        diskBytesRead: UInt64 = 0,
        diskBytesWritten: UInt64 = 0,
        startTime: Date? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.identity = ProcessIdentity(
            executablePath: executablePath,
            cwd: cwd,
            argv: argv
        )
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.startTime = startTime
    }
}

/// 快照(GLOSSARY):一次采样得到的全部进程原始数据,归组引擎的输入。
struct ProcessSnapshot: Equatable, Sendable {
    /// 采样发起时刻,CPU 差分与出生登记的时间轴依据。
    let takenAt: Date
    /// 采集到的全部进程。Live 源按 pid 升序;Synthetic 源原样保留注入顺序。
    let processes: [RawProcess]

    init(takenAt: Date = Date(), processes: [RawProcess]) {
        self.takenAt = takenAt
        self.processes = processes
    }

    /// pid → 进程映射(评审 T4,共享构建;重复 pid 保留首个)——
    /// 归组引擎的父链上溯与父链面包屑查询(ParentChainQuery)共用,
    /// 此前两处各写一份。
    var processesByPID: [pid_t: RawProcess] {
        Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
