@testable import Pulse
@testable import PulseCore
import XCTest

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
