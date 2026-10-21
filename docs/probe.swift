import Darwin
import Foundation

// 探针:验证 vitals-clone-tech-design.md §4 采集层的关键 API 在 Swift 下直接可用
struct Probe {
    let pid: pid_t

    func exePath() -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, 4096)
        return n > 0 ? String(cString: buf) : "<denied>"
    }

    /// 注意(工单 04 实测):pti_total_user/system 是 mach_absolute_time 原始 tick
    /// 而非纳秒(Apple Silicon timebase 125/3 ns/tick),换算见 LiveProcessSource.nanoseconds(fromTicks:)。
    func taskInfo() -> String {
        var t = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size))
        guard n > 0 else { return "taskinfo <denied rc=\(n)>" }
        return "taskinfo ok rss=\(t.pti_resident_size) cpu_user_tick=\(t.pti_total_user) cpu_sys_tick=\(t.pti_total_system)"
    }

    func rusage() -> String {
        var r = rusage_info_v3()
        let n = withUnsafeMutablePointer(to: &r) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V3, $0)
            }
        }
        guard n == 0 else { return "rusage <denied rc=\(n)>" }
        return "rusage ok disk_r=\(r.ri_diskio_bytesread) disk_w=\(r.ri_diskio_byteswritten) phys_footprint=\(r.ri_phys_footprint)"
    }

    func argv() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buf = [CChar](repeating: 0, count: 1 << 20)
        var len = buf.count
        guard sysctl(&mib, 3, &buf, &len, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        var args: [String] = []
        var i = 4
        while args.count < Int(argc), i < len {
            let start = i
            while i < len, buf[i] != 0 {
                i += 1
            }
            if i > start {
                var s = Array(buf[start ..< i])
                s.append(0)
                args.append(String(cString: s))
            }
            i += 1
        }
        return args
    }

    /// PROC_PIDVNODEPATHINFO 返回 vnode_info_path;探针阶段直接抽取缓冲区里的路径字符串
    func cwdCandidates() -> [String] {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &buf, Int32(buf.count))
        guard n > 0 else { return [] }
        var out: [String] = []
        var i = 0
        while i < n {
            while i < n, buf[i] == 0 || buf[i] < 32 || buf[i] > 126 {
                i += 1
            }
            let start = i
            while i < n, buf[i] != 0, buf[i] >= 32, buf[i] <= 126 {
                i += 1
            }
            if i - start >= 2, let s = String(bytes: buf[start ..< i], encoding: .ascii), s.hasPrefix("/") {
                out.append(s)
            }
            i += 1
        }
        return out
    }

    func ppid() -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var k = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &k, &len, nil, 0) == 0, k.kp_proc.p_pid == pid else { return nil }
        return k.kp_eproc.e_ppid
    }
}

var pidBuf = [pid_t](repeating: 0, count: 16384)
let npids = proc_listallpids(&pidBuf, Int32(pidBuf.count))
print("== proc_listallpids: \(npids > 0 ? npids : 0) processes ==")

let me = Probe(pid: getpid())
print("self exe:", me.exePath())
print("self", me.taskInfo())
print("self", me.rusage())
print("self argv:", me.argv().prefix(3))
print("self cwd:", me.cwdCandidates().prefix(3))
print("self ppid:", me.ppid() ?? -1)

// 跨进程:拉一个 cwd=/tmp、argv 带标记的子进程再查
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
p.arguments = ["-c", "sleep 20 # PROBE_MARKER_ARGV"]
p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
try p.run()
sleep(1)
let c = Probe(pid: p.processIdentifier)
print("== child \(p.processIdentifier) ==")
print("child exe:", c.exePath())
print("child", c.taskInfo())
print("child", c.rusage())
print("child argv:", c.argv())
print("child cwd:", c.cwdCandidates())
print("child ppid:", c.ppid() ?? -1)

/// root 进程(预期部分受限,符合方案"自有进程全够"的假设)
let root = Probe(pid: 1)
print("== pid1 (root-owned) ==")
print("pid1 exe:", root.exePath())
print("pid1", root.taskInfo())
print("pid1 argv:", root.argv().prefix(2))
print("pid1 cwd:", root.cwdCandidates())
p.terminate()
