@testable import Pulse
@testable import PulseCore
import XCTest

/// p1-history/06 网络卡的 app 侧:LiveNetworkCountersSource 的入向死表回退编排(注入假
/// 主接口 / 候选列表 / 读数)与 Live 源构造冒烟。纯逻辑在核心包 NetworkModelTests。
final class NetworkSensorTests: XCTestCase {
    // MARK: - 回退编排夹具(注入假链路状态 + 假读数)

    /// 假主接口 / 假候选列表(钉死 LiveNetworkCountersSource 的回退编排)。
    private struct FixedPrimarySource: NetworkPrimaryInterfaceSource {
        let name: String?
        func primaryInterfaceName() -> String? {
            name
        }
    }

    private struct FixedListSource: NetworkInterfaceListSource {
        let states: [NetworkInterfaceState]
        func interfaces() -> [NetworkInterfaceState] {
            states
        }
    }

    private func fakeSource(
        primary: String?,
        candidates: [NetworkInterfaceState],
        table: [String: NetworkCounters]
    ) -> LiveNetworkCountersSource {
        LiveNetworkCountersSource(
            primarySource: FixedPrimarySource(name: primary),
            listSource: FixedListSource(states: candidates),
            read: { table[$0] }
        )
    }

    private func state(_ name: String, running: Bool = true) -> NetworkInterfaceState {
        var flags: Int32 = NetworkInterfaceSelector.iffUp
        if running {
            flags |= NetworkInterfaceSelector.iffRunning
        }
        return NetworkInterfaceState(name: name, flags: flags, addressFamily: 2)
    }

    /// 物理口入向死表 + 隧道口活:回退到入向在场者(不翻倍不归零的关键)。
    func testDeadInboundFallsBackToLiveTunnel() {
        let source = fakeSource(
            primary: "en0",
            candidates: [state("en0"), state("utun4")],
            table: [
                "en0": NetworkFixture.counters("en0", up: 9000, down: 0, upPackets: 44000, downPackets: 0, at: 1),
                "utun4": NetworkFixture.counters(
                    "utun4",
                    up: 500,
                    down: 4000,
                    upPackets: 700,
                    downPackets: 2100,
                    at: 1
                ),
            ]
        )
        let sampled = source.sample()
        XCTAssertEqual(sampled?.interface, "utun4")
        XCTAssertEqual(sampled?.downBytes, 4000)
    }

    /// 多个活口取累计入向字节最多者(闲置 utun 的历史零星包抢不走主隧道)。
    func testDeadInboundPicksHighestInboundCandidate() {
        let source = fakeSource(
            primary: "en0",
            candidates: [state("en0"), state("utun0"), state("utun4")],
            table: [
                "en0": NetworkFixture.counters("en0", up: 9000, down: 0, upPackets: 44000, downPackets: 0, at: 1),
                "utun0": NetworkFixture.counters("utun0", up: 0, down: 300, upPackets: 2, downPackets: 3, at: 1),
                "utun4": NetworkFixture.counters(
                    "utun4",
                    up: 500,
                    down: 1_900_000_000,
                    upPackets: 700,
                    downPackets: 2_100_000,
                    at: 1
                ),
            ]
        )
        XCTAssertEqual(source.sample()?.interface, "utun4")
    }

    /// 物理口死表但无任何活口(corplink 关 + 本机 en0 冻结):保持物理口,
    /// down = 0 是内核真相,不硬造。
    func testDeadInboundKeepsPhysicalWhenNoLiveCandidate() {
        let source = fakeSource(
            primary: "en0",
            candidates: [state("en0"), state("lo0", running: true)],
            table: [
                "en0": NetworkFixture.counters("en0", up: 9000, down: 0, upPackets: 44000, downPackets: 0, at: 1),
            ]
        )
        let sampled = source.sample()
        XCTAssertEqual(sampled?.interface, "en0")
        XCTAssertEqual(sampled?.downBytes, 0)
    }

    /// 物理口健康(双向都在走):不触发回退,读数原样交付。
    func testHealthyPhysicalSkipsFallback() {
        let source = fakeSource(
            primary: "en0",
            candidates: [state("en0"), state("utun4")],
            table: [
                "en0": NetworkFixture.counters("en0", up: 100, down: 200, upPackets: 10, downPackets: 20, at: 1),
                "utun4": NetworkFixture.counters("utun4", up: 0, down: 9999, upPackets: 0, downPackets: 99, at: 1),
            ]
        )
        let sampled = source.sample()
        XCTAssertEqual(sampled?.interface, "en0")
        XCTAssertEqual(sampled?.downBytes, 200)
    }

    // MARK: - Live 源冒烟(OS 边界不做语义断言,DiskSensor 同款)

    func testLiveSourceSamplesWithoutCrash() {
        let source = LiveNetworkCountersSource()
        if let counters = source.sample() {
            XCTAssertFalse(counters.interface.isEmpty)
            XCTAssertGreaterThan(counters.atUptimeNanos, 0)
        }
    }
}
