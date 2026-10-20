import Foundation
import Darwin
import PulseCore

// MARK: - dev server 盘点(工单 08)
//
// argv 分类器是纯函数(工单票面):直接吃现有进程快照的 argv(RawProcess 现成
// 字段,零新采集成本);只有分类命中的候选进程才做端口扫描(PROC_PIDLISTFDS +
// PROC_PIDFDINFO_SOCKET,libproc 直调);"闲置" = 最近 10 分钟 CPU≈0(观察时刻
// 由调用方注入,单测合成时间轴,与 Sampler/AlertEngine 同款纪律)。
// 词汇表:dev server / 闲置(Idle)——处置永远由人确认,这里只盘点不杀。

// MARK: - 闲置判定(注入时刻)

// MARK: - 盘点状态与编排

// MARK: - 端口扫描缝

/// libproc 薄适配器:列 fd → 逐 socket fd 查 TCP 监听状态与本地端口。
/// 只读系统账,不发包不连接;进程退出/受限查询静默降级为空。
struct LiveDevServerPortScanner: DevServerPortScanning {
    /// TCP 监听态(TSI_S_LISTEN,sys/proc_info.h 的 #define 不进 Swift,值钉死
    /// 与 netinet/tcp_fsm.h 的 TCPS_LISTEN 同值)。
    private static let tcpStateListen: Int32 = 1

    func listeningPorts(pid: pid_t) -> [UInt16] {
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        // 尺寸探测:buffersize = 0 时返回需要的字节数(失败/进程已退 → ≤0)。
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / fdStride)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, needed)
        guard written > 0 else { return [] }
        let count = Int(written) / fdStride

        var ports = Set<UInt16>()
        for index in 0..<count {
            guard fds[index].proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            var info = socket_fdinfo()
            let result = proc_pidfdinfo(
                pid, fds[index].proc_fd, PROC_PIDFDSOCKETINFO,
                &info, Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard result == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            // 只看 TCP 监听(IPv4/IPv6);UDP/Unix 域/已连接的 TCP 都不算服务口。
            guard info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == Self.tcpStateListen
            else { continue }
            // 本地端口是 int 里的网络序 16 位。
            let raw = UInt32(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
                & 0xFFFF
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
            if port != 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}
