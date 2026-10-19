import Foundation
import Darwin

/// Live 采集源:Darwin 薄适配器,API 全集与 docs/probe.swift 一一对应。
///
/// - 列进程:`proc_listallpids`
/// - ppid / 启动时刻:`sysctl(KERN_PROC, KERN_PROC_PID)`,取 `kp_eproc.e_ppid`
///   (kp_ppid 宏不导入 Swift)与 `kp_proc.p_starttime`
/// - 可执行路径:`proc_pidpath`
/// - CPU 累计时间 / 常驻内存:`proc_pidinfo(PROC_PIDTASKINFO)`
/// - 物理足迹 / 磁盘字节 / 唤醒计数:`proc_pid_rusage(RUSAGE_INFO_V3)`——
///   全仓库唯一的全进程 rusage 循环(票 A 高2:模块排行与磁盘求和回退源
///   都吃这张心跳快照,不另起扫描)
/// - argv:`sysctl(KERN_PROCARGS2)`,解析见 `ProcArgsParser`
/// - cwd:`proc_pidinfo(PROC_PIDVNODEPATHINFO)`(`proc_vnodepathinfo` 直接导入 Swift,
///   无需手写 vnode_info_path 布局)
///
/// 降级策略:字段级查询失败 → nil / 空数组,绝不中断整轮采集;
/// 仅当 KERN_PROC 查不到该 pid(采样间隙进程退出)时静默跳过整个进程。
///
/// 性能(工单 10):常驻每进程 3 次调用(KERN_PROC + PROC_PIDTASKINFO +
/// rusage)——身份三元组(路径 / cwd / argv)经 `ProcessIdentityCache`
/// 首见读一次、60s 低频校正;首轮与校正轮 +3,平均约 3.25 次/进程/轮
/// (改动前恒为 6 次)。argv 读空(KERN_PROCARGS2 失败)不落缓存,下轮
/// 照常重读——退化不粘滞,与逐轮重读时代一致。无任何子进程调用
/// (不 /bin/ps、不 lsof);大缓冲整轮复用,~800 pid 一轮保持在毫秒级。
final class LiveProcessSource: ProcessSource, @unchecked Sendable {
    /// 缓存决策与真实读取之间的互斥:协议要求 Sendable,采样 actor 串行
    /// 调用之下锁近乎无争,仅为类型正确性兜底(与 SyntheticProcessSource 同款)。
    private let lock = NSLock()
    private var identityCache = ProcessIdentityCache()
    /// proc_pidpath 缓冲上限(libproc 的 PROC_PIDPATHINFO_MAXSIZE,宏不导入 Swift)。
    /// internal:出生扫描器(LiveBirthScanSource)复用同一批调用与缓冲上限。
    static let pathBufferSize = 4096
    /// KERN_PROCARGS2 缓冲:argc + execpath + argv + envp,1 MiB 覆盖 ARG_MAX。
    static let procArgsBufferSize = 1 << 20
    /// 进程列表缓冲(pid 数),远超实际进程数。
    private static let pidListCapacity = 16_384
    /// mach 时间基准(本机实测 125/3 ns/tick;Intel 上为 1/1,即 tick == 纳秒)。
    /// pti_total_user/system 实为 mach_absolute_time 原始 tick 而非纳秒——
    /// 工单 04 用 getrusage 基准校准发现:不换算 CPU% 会缩小 ~41.7 倍
    /// (刻度校准测试见 LiveProcessSourceSmokeTests)。
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// tick → 纳秒。整数乘除(ticks ≤ 开机时长 × 24MHz,×125 远不溢出 UInt64)。
    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    func snapshot() -> ProcessSnapshot {
        let takenAt = Date()
        let pids = Self.listPIDs()
        var processes: [RawProcess]
        processes = []
        processes.reserveCapacity(pids.count)

        // 大缓冲整轮复用,避免每进程重新分配。
        var pathBuffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        var procArgsBuffer = [CChar](repeating: 0, count: Self.procArgsBufferSize)

        lock.lock()
        defer { lock.unlock() }

        for pid in pids {
            // ppid 与启动时刻一次 sysctl 全取;查不到 = 进程已退出,静默跳过。
            guard let kinfo = Self.kernelProcessInfo(pid: pid) else { continue }
            let task = Self.taskInfo(pid: pid)
            let usage = Self.resourceUsage(pid: pid)
            let cpuTicks = task.map { $0.pti_total_user + $0.pti_total_system } ?? 0

            // 身份三元组:缓存命中(p_comm 一致 ∧ 未过校正期)零身份调用;
            // 未命中 = 新面孔 / exec / pid 复用 / 校正到期,重读整组并回填。
            let commandName = Self.commandName(from: kinfo)
            let identity: ProcessIdentity
            if let cached = identityCache.identity(pid: pid, commandName: commandName, now: takenAt) {
                identity = cached
            } else {
                let fresh = ProcessIdentity(
                    executablePath: Self.executablePath(pid: pid, buffer: &pathBuffer),
                    cwd: Self.currentWorkingDirectory(pid: pid),
                    argv: ProcArgsParser.argv(of: pid, into: &procArgsBuffer)
                )
                if !fresh.argv.isEmpty {
                    identityCache.record(
                        pid: pid, identity: fresh, commandName: commandName, at: takenAt
                    )
                }
                identity = fresh
            }

            processes.append(
                RawProcess(
                    pid: pid,
                    parentPID: kinfo.kp_eproc.e_ppid,
                    executablePath: identity.executablePath,
                    argv: identity.argv,
                    cwd: identity.cwd,
                    cpuTimeNanoseconds: Self.nanoseconds(fromTicks: cpuTicks),
                    residentMemoryBytes: task?.pti_resident_size ?? 0,
                    physicalFootprintBytes: usage?.ri_phys_footprint ?? 0,
                    diskBytesRead: usage?.ri_diskio_bytesread ?? 0,
                    diskBytesWritten: usage?.ri_diskio_byteswritten ?? 0,
                    wakeups: usage.map { $0.ri_pkg_idle_wkups &+ $0.ri_interrupt_wkups } ?? 0,
                    countersAvailable: task != nil && usage != nil,
                    startTime: Self.startTime(from: kinfo)
                )
            )
        }

        // 每轮对存活集裁剪:已消失的 pid 逐出缓存,pid 复用不背旧身份。
        identityCache.prune(keeping: Set(processes.map(\.pid)))

        return ProcessSnapshot(takenAt: takenAt, processes: processes.sorted { $0.pid < $1.pid })
    }

    // MARK: - Darwin 调用(每个都对应 docs/probe.swift 中已验证的写法)
    // 下列四个为 internal:出生扫描器(LiveBirthScanSource,评审 S1)复用同一批
    // 调用做轻量新 pid 探测——单测冒烟与缓冲上限共用一处事实。

    static func listPIDs() -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: pidListCapacity)
        let count = proc_listallpids(&buffer, Int32(buffer.count))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    static func kernelProcessInfo(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &length, nil, 0) == 0,
            info.kp_proc.p_pid == pid
        else { return nil }
        return info
    }

    private static func startTime(from info: kinfo_proc) -> Date? {
        let timeval = info.kp_proc.p_starttime
        guard timeval.tv_sec != 0 else { return nil }
        return Date(
            timeIntervalSince1970: Double(timeval.tv_sec) + Double(timeval.tv_usec) / 1_000_000
        )
    }

    /// exec 指纹(工单 10):KERN_PROC 的 p_comm,exec 即换名(截断到
    /// MAXCOMLEN-1 字符 + NUL,pid 复用也几乎必换)。零成本失配信号——
    /// 乘的是本来就要读的 KERN_PROC,不添调用。定长 C 数组按首地址读,
    /// 遇 NUL 截断(防御式:无 NUL 时取满长度),UTF-8 有损解码。
    static func commandName(from info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
    }

    static func executablePath(pid: pid_t, buffer: inout [CChar]) -> String? {
        // 本 SDK 的 proc_pidpath 缓冲长度形参是 UInt32(探针用字面量 4096 故未暴露)。
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func taskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let length = proc_pidinfo(
            pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)
        )
        return length > 0 ? info : nil
    }

    private static func resourceUsage(pid: pid_t) -> rusage_info_v3? {
        var info = rusage_info_v3()
        // proc_pid_rusage 收 rusage_info_t*(void**):探针验证的指针重绑写法。
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V3, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    static func currentWorkingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let length = proc_pidinfo(
            pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard length > 0 else { return nil }
        // vip_path 是定长 C 数组(导入为 1024 个 CChar 的元组),取首地址按 C 字符串读。
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress, base.pointee != 0 else {
                return nil
            }
            return String(cString: base)
        }
    }
}
