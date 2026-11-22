@testable import Pulse
import PulseCore
import XCTest

/// 全局端口扫描 Live 冒烟(port-view/01):本进程内开真实 TCP 监听 socket,
/// 批量扫描应把同一端口记在本 pid 名下——钉死批量缝路径、网络序换算与
/// 「无监听进程不写入结果」的语义。纯合成归并逻辑见 PortInventoryFinderTests
/// (PulseCore);真扫描不进自动化重负载(测试负载最小化纪律)。
final class GlobalPortScannerTests: XCTestCase {
    func testBatchScanReadsRealListeningSocketAndOmitsSilentPIDs() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return XCTFail("socket() 失败 errno \(errno)") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // 绑随机端口,读回实际值
        addr.sin_addr = in_addr(s_addr: in_addr_t(0)) // INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            return XCTFail("bind/listen 失败 errno \(errno)")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { return XCTFail("getsockname 失败 errno \(errno)") }
        let port = UInt16(bigEndian: bound.sin_port)
        guard port != 0 else { return XCTFail("绑定到端口 0") }

        // 批量口径:本进程(listen 中)+ pid 1(launchd,本会话读不到监听 socket 的
        // 典型沉默者)。launchd 恰有监听口也不破坏断言——只断言自家端口在、
        // 无监听的 pid 不出现。
        let selfPID = getpid()
        let scan = LiveGlobalPortScanner().listeningPorts(pids: [selfPID, 1])
        XCTAssertEqual(scan[selfPID], scan[selfPID]?.sorted())
        XCTAssertTrue(
            scan[selfPID]?.contains(port) == true,
            "批量扫描应读到本进程监听端口 \(port),实际 \(scan[selfPID] ?? [])"
        )
        // launchd 的 fd 本会话读不到,典型应无读数(未写入);若恰读到可读监听口
        // (罕见),只验「写入即非空」契约——launchd 占什么口不在本测试管辖。
        if let launchdPorts = scan[1] {
            XCTAssertFalse(launchdPorts.isEmpty, "写入结果的 pid 必带非空监听口")
        }
    }
}
