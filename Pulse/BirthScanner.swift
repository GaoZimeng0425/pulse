import Foundation
import Darwin
import PulseCore

// MARK: - 出生扫描源(评审 S1)

/// Darwin 薄适配器:复用采集层(LiveProcessSource)的同一批已验证调用——
/// ppid:sysctl KERN_PROC;路径:proc_pidpath;argv:KERN_PROCARGS2;
/// cwd:PROC_PIDVNODEPATHINFO。只用于新 pid,量级为"每轮一撮"。
struct LiveBirthScanSource: BirthScanSource {
    func pids() -> [pid_t] {
        LiveProcessSource.listPIDs()
    }

    func birthInfo(for pid: pid_t) -> LineageRegistry.Entry? {
        // KERN_PROC 查不到 = 进程已退出(与采集层同口径:静默跳过)。
        guard let kinfo = LiveProcessSource.kernelProcessInfo(pid: pid) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: LiveProcessSource.pathBufferSize)
        var argsBuffer = [CChar](repeating: 0, count: LiveProcessSource.procArgsBufferSize)
        return LineageRegistry.Entry(
            parentPID: kinfo.kp_eproc.e_ppid,
            identity: ProcessIdentity(
                executablePath: LiveProcessSource.executablePath(pid: pid, buffer: &pathBuffer),
                cwd: LiveProcessSource.currentWorkingDirectory(pid: pid),
                argv: ProcArgsParser.argv(of: pid, into: &argsBuffer)
            )
        )
    }
}

