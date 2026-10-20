import Foundation
import Darwin
import PulseCore

// MARK: - 处置接缝(工单 08)

/// 真实现:kill(2) 薄适配器。errno 映射保证 root 属主 / 已退出等失败
/// 以可读原因浮出,而不是被吞掉。处置是用户确认过的破坏性动作——每次
/// 投递成败都在此留审计日志(NemoNotch Logging 规范:外部交互 info/error)。
struct LiveKillService: KillService {
    func send(signal: Int32, to pid: pid_t) -> KillSignalResult {
        if kill(pid, signal) == 0 {
            LogService.info("结束信号已投递 pid \(pid)(signal \(signal))", category: "KillService")
            return .delivered
        }
        switch errno {
        case EPERM:
            LogService.error("结束 pid \(pid) 失败:无权限(EPERM)", category: "KillService")
            return .failed(.permissionDenied)
        case ESRCH:
            LogService.warn("结束 pid \(pid) 失败:进程已退出(ESRCH)", category: "KillService")
            return .failed(.noSuchProcess)
        default:
            LogService.error("结束 pid \(pid) 失败:errno \(errno)", category: "KillService")
            return .failed(.other(errno))
        }
    }
}

// MARK: - 处置编排(工单 08)

// MARK: - 处置文案(工单 08,纯函数可单测)

