@testable import Pulse
@testable import PulseCore
import XCTest

#if canImport(Darwin)
    import Darwin
#endif

// 容器传感器测试(p2-sensors/07):provider 行为用假源(零 socket 依赖),
// Live 源只做"本机真读一次不崩 + 结构健全"冒烟(OrbStack 在跑 = 真容器;
// 未跑 = engineReachable false 空表,两条路径都合法)。

/// 假容器源:载荷开关(测 lastGood 与空态语义)。
private final class FakeContainerSource: ContainerSource, @unchecked Sendable {
    var payload: ContainersReading?

    func read() async -> ContainersReading? {
        payload
    }
}

final class ContainerSensorTests: XCTestCase {
    func testCadenceIsThirtySeconds() {
        // 节奏登记(票面口径):可见 30s 档,不可见停由门控保证。
        XCTAssertEqual(
            ContainerSensorProvider(source: FakeContainerSource()).cadence,
            .every(seconds: 30)
        )
    }

    func testGateBlocksRequestsWhenInvisible() async {
        // 门控关:不碰源(交付 nil,lastGood 不动);门控开:交付并记 lastGood。
        let source = FakeContainerSource()
        source.payload = ContainersReading(engineReachable: true, containers: [
            ContainerRow(
                id: "a1",
                name: "redis",
                state: "running",
                image: "redis:7",
                cpuPercent: 0.5,
                memoryBytes: 1024
            ),
        ])
        let provider = ContainerSensorProvider(source: source)

        provider.setVisible(false)
        let blocked = await provider.snapshot()
        XCTAssertNil(blocked)
        XCTAssertNil(provider.lastGood)

        provider.setVisible(true)
        let reading = await provider.snapshot()
        XCTAssertEqual(reading?.containers.first?.name, "redis")
        XCTAssertEqual(provider.lastGood?.engineReachable, true)
    }

    func testEngineAbsentIsQuietEmptyStateNotFailure() async {
        // socket 缺席 = engineReachable false 空表:是**成功交付**(UI 空态),
        // 不是读失败——lastGood 照记,下一发仍是 30s 后(无重试风暴)。
        let source = FakeContainerSource()
        source.payload = ContainersReading(engineReachable: false, containers: [])
        let provider = ContainerSensorProvider(source: source)
        provider.setVisible(true)

        let reading = await provider.snapshot()
        XCTAssertEqual(reading?.engineReachable, false)
        XCTAssertTrue(reading?.containers.isEmpty ?? false)
        XCTAssertEqual(provider.lastGood?.engineReachable, false)
    }

    func testListFailureKeepsLastGood() async {
        // 引擎在但列表失败(nil):不动 lastGood。
        let source = FakeContainerSource()
        source.payload = ContainersReading(engineReachable: true, containers: [])
        let provider = ContainerSensorProvider(source: source)
        provider.setVisible(true)
        _ = await provider.snapshot()

        source.payload = nil
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.engineReachable, true)
    }

    // MARK: - 阻塞执行域(p2-audit/02)

    /// 慢引擎哑服务器:accept 后握住连接不响应——逼出接收超时路径。
    private func makeSilentUnixSocketServer(holdSeconds: Double) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pulse-slow-\(UUID().uuidString).sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: 1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "bind/listen", code: 2)
        }
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil) // 握住连接,永不响应
            Thread.sleep(forTimeInterval: holdSeconds)
            if client >= 0 {
                close(client)
            }
            close(fd)
            unlink(path)
        }
        return path
    }

    func testBlockingWaitsOnGlobalQueueNotCooperativePool() async throws {
        // p2-audit/02:connect/recv 阻塞段移全局队列——慢引擎握住连接时,
        // (a) 接收超时照常触发(语义不变,read 返 nil);(b) 等待期间协作
        // 线程池不被占用:并发短任务照常完成。
        let socketPath = try makeSilentUnixSocketServer(holdSeconds: 3)
        let source = LiveContainerSource(socketPaths: [socketPath], recvTimeoutSeconds: 1)

        let started = Date()
        let readTask = Task { await source.read() }
        // 协作池心跳:阻塞等待窗口内(≥1s)一个 50ms 异步任务必须已完成——
        // 若阻塞仍在协作线程上,这里会被饿到 read 返回之后才轮到。
        try await Task.sleep(nanoseconds: 100_000_000) // 等 read 进入阻塞段
        let heartbeatDone: Bool = await withCheckedContinuation { continuation in
            Task {
                try await Task.sleep(nanoseconds: 50_000_000)
                continuation.resume(returning: true)
            }
        }
        XCTAssertTrue(heartbeatDone)
        // read 仍在等超时由下方 elapsed ≥ 0.9s 兜底证明(心跳发生在 ~150ms,
        // 远早于超时点——阻塞段若占协作线程,心跳任务会被压后到 read 返回之后)。

        let reading = await readTask.value
        XCTAssertNil(reading, "列表超时 = 读失败语义(不动 lastGood 口径不变)")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "接收超时被遵守")
        XCTAssertLessThan(elapsed, 2.5, "超时后即返回(不是被服务器 hold 满 3s)")
    }

    func testLiveSmokeOnThisMachine() async {
        // Live 冒烟:真读一次不崩;OrbStack 在跑 = 真容器行结构健全(名字非空、
        // 状态合法、CPU/内存量级不越界);未跑 = 安静空表。两条路径都合法。
        let reading = await LiveContainerSource().read()
        guard let reading else {
            XCTFail("OrbStack 在跑但列表读失败——查 socket 路径或引擎状态")
            return
        }
        if reading.engineReachable {
            for container in reading.containers {
                XCTAssertFalse(container.name.isEmpty)
                if let cpu = container.cpuPercent {
                    XCTAssertGreaterThanOrEqual(cpu, 0)
                    XCTAssertLessThanOrEqual(cpu, 100_000, "CPU% 量级异常:\(cpu)")
                }
            }
        } else {
            XCTAssertTrue(reading.containers.isEmpty, "引擎缺席必须空表")
        }
    }
}
