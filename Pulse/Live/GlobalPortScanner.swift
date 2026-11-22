import Darwin
import Foundation
import PulseCore

// MARK: - 全局端口扫描缝(工单 port-view/01)

/// libproc 批量薄适配器:全机方向的监听端口扫描。逐 pid 复用
/// `LiveDevServerPortScanner` 的单进程三步(尺寸探测 → 列 fd → 逐 socket
/// PROC_PIDFDSOCKETINFO,TCP 监听态过滤);进程退出 / 受限(root)静默降级
/// 为不写入——结果字典「未列出 = 无监听 / 受限 / 已退」,与缝协议语义一致。
///
/// 成本(port-view/01 探针实测,2026-11-22):全机 909 进程一轮 ≈2.9ms,
/// 由 PortsFeature 的可见性闸 + 10s 传感器档位约束,这里不做节流。
/// pid 枚举不走 proc_listallpids(darwin 27.2 上只回 232 个 pid,已记票面)——
/// 调用方传快照 pid 列表(采集层 KERN_PROC_ALL 全表)。
struct LiveGlobalPortScanner: GlobalPortScanning {
    private let singlePIDScanner = LiveDevServerPortScanner()

    func listeningPorts(pids: [pid_t]) -> [pid_t: [UInt16]] {
        var result: [pid_t: [UInt16]] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids {
            let ports = singlePIDScanner.listeningPorts(pid: pid)
            if !ports.isEmpty {
                result[pid] = ports
            }
        }
        return result
    }
}
