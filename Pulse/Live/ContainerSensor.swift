import Foundation
import PulseCore

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Live 容器源(p2-sensors/07)

/// Darwin 薄适配器:docker.sock 上的 HTTP 单发(本机 = OrbStack,探针⑦实证
/// /var/run/docker.sock → ~/.orbstack/run/docker.sock)。OS 调用(socket 三件)
/// 在这里;HTTP 解析与 JSON 折算在核心包(探针四坑:Host 须 localhost、
/// Connection: close 必带、chunked 字节级去块、CRLF 字形簇——后两坑在核心包
/// 单测,前两坑钉死在请求模板)。
struct LiveContainerSource: ContainerSource {
    /// socket 候选路径:系统标准位先行,OrbStack 用户域位兜底(测试可注入假路径)。
    private let socketPaths: [String]
    /// 接收超时秒数(测试可注入短超时;默认 5s,票面口径)。
    private let recvTimeoutSeconds: Int

    init(socketPaths: [String]? = nil, recvTimeoutSeconds: Int = 5) {
        self.socketPaths = socketPaths ?? [
            "/var/run/docker.sock",
            NSString(string: "~/.orbstack/run/docker.sock").expandingTildeInPath,
        ]
        self.recvTimeoutSeconds = recvTimeoutSeconds
    }

    func read() async -> ContainersReading? {
        guard let path = socketPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return ContainersReading(engineReachable: false, containers: []) // OrbStack 未跑:安静空态
        }
        guard let listRaw = await httpGet("/containers/json?all=1", socketPath: path),
              let list = ContainerListPayload.parse(listRaw)
        else { return nil } // 引擎在但列表失败:读失败语义,不动 lastGood

        // 每容器 stats 并行单发(探针⑦实测单发 ~1s/容器,串行 7 容器 7s 不可
        // 接受);单台失败 = 该行 CPU/内存留 nil,不拖垮整表。
        let rows: [ContainerRow] = await withTaskGroup(of: ContainerRow?.self) { group in
            for row in list {
                group.addTask {
                    guard row.state == "running" else { return row } // 非运行容器无 stats 必要
                    let statsBody = await httpGet(
                        "/containers/\(row.id)/stats?stream=false",
                        socketPath: path
                    )
                    guard let statsBody else { return row }
                    let stats = ContainerStatsPayload.parse(statsBody)
                    return ContainerRow(
                        id: row.id,
                        name: row.name,
                        state: row.state,
                        image: row.image,
                        cpuPercent: stats?.cpuPercent,
                        memoryBytes: stats?.memoryBytes
                    )
                }
            }
            var collected: [ContainerRow] = []
            for await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }
        return ContainersReading(engineReachable: true, containers: rows)
    }

    /// 一发 HTTP GET:**阻塞段在全局并发队列执行**(p2-audit/02:connect/recv
    /// 至超时上限不得占用 Swift 协作线程池——引擎卡死时一个协作线程被堵满,
    /// 与传感器 tick/历史落库争池子),continuation 桥回 async。
    private func httpGet(_ path: String, socketPath: String) async -> [UInt8]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: httpGetBlocking(path, socketPath: socketPath))
            }
        }
    }

    /// 阻塞段本体(socket 短连;超时兜底防代理挂死——探针坑②的极端面)。
    /// 只许在全局队列上调用(见 httpGet)。
    private func httpGetBlocking(_ path: String, socketPath: String) -> [UInt8]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // 探针坑①②:Host 必须是合法主机名(localhost——OrbStack 代理对
        // "Host: docker" 断连),Connection: close 必须显式带(默认保活 recv 等死)。
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { pointer in
            send(fd, pointer, strlen(pointer), 0)
        }
        guard sent >= 0 else { return nil }

        // 接收超时(默认 5s):引擎卡死时本轮安静失败,不挂全局队列线程。
        var timeout = timeval(tv_sec: recvTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 {
                break
            }
            received.append(contentsOf: buffer[0 ..< n])
            if received.count > 8_000_000 {
                break
            } // 8MiB 上限防御
        }
        return UnixHTTPResponse.parse(received).flatMap { $0.status == 200 ? $0.body : nil }
    }
}

// MARK: - 容器传感器 provider(p2-sensors/07,ADR-0004)

/// 容器传感器:**页可见 30s / 不可见完全停**(spec 节奏矩阵)。socket 缺席 =
/// engineReachable false 空表(安静空态,不重试风暴——重试就是 30s 后的下一
/// 发,天然有界)。读失败保留 lastGood(ADR-0004)。
final class ContainerSensorProvider: SensorProvider {
    typealias Reading = ContainersReading

    let cadence: SensorCadence = .every(seconds: 30)

    private let source: any ContainerSource
    private let gate = SensorVisibilityGate()
    private let slot = SensorLastGoodBox<ContainersReading>()

    var lastGood: ContainersReading? {
        slot.current
    }

    init(source: any ContainerSource = LiveContainerSource()) {
        self.source = source
    }

    /// 可见性切换(弹窗在场 ∨ 主窗口容器页在场,ContainerFeature 折算下发)。
    func setVisible(_ visible: Bool) {
        _ = gate.setVisible(visible)
    }

    func snapshot() async -> ContainersReading? {
        guard gate.isVisible else { return nil } // 不可见:零请求
        guard let reading = await source.read() else { return nil }
        slot.store(reading)
        return reading
    }
}
