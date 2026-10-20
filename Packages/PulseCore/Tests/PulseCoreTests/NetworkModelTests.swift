import Darwin
import XCTest
@testable import PulseCore
import PulseCoreTestSupport

/// p1-history/06 网络卡:核心层 NetworkModel 的合成夹具单测(spec 测试决策,调研 §2.2 逐条钉死)。
/// 三组断言:①接口选择与降级链(虚拟前缀降级 → UP+RUNNING 回退,注入假链路状态);
/// ②NET_RT_IFLIST2 回包解包(合成字节,stats 同款负例);③差分三件套(首读置零/
/// 负值钳零/重连跳变丢弃,合成计数序列,不制造真实网络流量)。入向死表回退的编排
/// 与 Live 源冒烟在 PulseTests/NetworkSensorTests。
final class NetworkModelTests: XCTestCase {
    // MARK: - 接口选择与降级(注入假链路状态)

    /// 合成一行 getifaddrs 链路状态。flags 用 SDK 字面量:UP=0x1 / LOOPBACK=0x8 /
    /// POINTOPOINT=0x10 / RUNNING=0x40;family 2 = AF_INET、30 = AF_INET6。
    private func state(
        _ name: String,
        up: Bool = true,
        running: Bool = true,
        loopback: Bool = false,
        pointToPoint: Bool = false,
        family: Int32 = 2
    ) -> NetworkInterfaceState {
        var flags: Int32 = 0
        if up { flags |= NetworkInterfaceSelector.iffUp }
        if running { flags |= NetworkInterfaceSelector.iffRunning }
        if loopback { flags |= NetworkInterfaceSelector.iffLoopback }
        if pointToPoint { flags |= NetworkInterfaceSelector.iffPointToPoint }
        return NetworkInterfaceState(name: name, flags: flags, addressFamily: family)
    }

    /// 主接口存在且非虚拟:直接用,不问候选。
    func testPhysicalPrimaryIsSelectedDirectly() {
        let candidates = [state("en1")]
        XCTAssertEqual(
            NetworkInterfaceSelector.select(primary: "en0", candidates: candidates),
            "en0"
        )
    }

    /// 虚拟主接口(utun 前缀 = VPN 隧道):降级到候选里的物理口。
    func testVirtualPrimaryDowngradesToPhysicalCandidate() {
        let candidates = [
            state("vmenet0"),
            state("en0"),
        ]
        XCTAssertEqual(
            NetworkInterfaceSelector.select(primary: "utun4", candidates: candidates),
            "en0"
        )
    }

    /// 主接口缺席(无活动网络服务):getifaddrs 回退,取第一个 UP+RUNNING 物理口。
    func testMissingPrimaryFallsBackToFirstRunningPhysical() {
        let candidates = [
            state("en0", running: false), // 链路未跑起:跳过
            state("en1"),
            state("en2"),
        ]
        XCTAssertEqual(
            NetworkInterfaceSelector.select(primary: nil, candidates: candidates),
            "en1"
        )
    }

    /// 候选过滤:loopback / pointopoint(utun、ppp 天生 p2p)/ 未 RUN / 非 IPv4
    /// (awdl0 只有 v6)/ 虚拟前缀(bridge、vmenet = OrbStack)全都不算物理口。
    func testCandidatesFilteredByFlagsFamilyAndPrefixes() {
        let candidates = [
            state("lo0", loopback: true),
            state("utun3", pointToPoint: true),
            state("en7", up: false),
            state("awdl0", family: 30),           // IPv6-only:跳过
            state("bridge100"),                    // OrbStack/共享桥:跳过
            state("vmenet2"),                      // OrbStack 虚拟网卡:跳过
            state("en5"),
        ]
        XCTAssertEqual(NetworkInterfaceSelector.select(primary: nil, candidates: candidates), "en5")
    }

    /// 全员不合格(只有 loopback 可用):返回 nil,本轮读不到占位,不硬选。
    func testNoQualifyingCandidateReturnsNil() {
        let candidates = [state("lo0", loopback: true)]
        XCTAssertNil(NetworkInterfaceSelector.select(primary: nil, candidates: candidates))
        XCTAssertNil(NetworkInterfaceSelector.select(primary: "utun1", candidates: []))
    }

    /// 虚拟前缀表:VPN/隧道/OrbStack 全命中,物理口不误伤。
    func testVirtualPrefixTable() {
        for name in ["utun0", "ipsec2", "ppp0", "tun1", "tap2", "gif0", "stf0", "wg0", "vmenet0", "bridge100"] {
            XCTAssertTrue(NetworkInterfaceSelector.isVirtual(name), "\(name) 应判虚拟")
        }
        for name in ["en0", "en5", "anpi0", "lo0"] {
            XCTAssertFalse(NetworkInterfaceSelector.isVirtual(name), "\(name) 不应判虚拟")
        }
    }

    // MARK: - NET_RT_IFLIST2 回包解包(合成字节)

    /// 合成一条 RTM_IFINFO2(if_msghdr2 + 尾部 sockaddr 填充,真机回包 len=180
    /// > 结构体 160,尾部是追加数据)。
    private func ifinfo2(
        index: UInt16,
        up: UInt64,
        down: UInt64,
        baudrate: UInt64 = 0,
        upPackets: UInt64 = 0,
        downPackets: UInt64 = 0,
        trailing: Int = 20,
        type: UInt8 = 0x12
    ) -> [UInt8] {
        var data = if_data64()
        data.ifi_obytes = up
        data.ifi_ibytes = down
        data.ifi_opackets = upPackets
        data.ifi_ipackets = downPackets
        data.ifi_baudrate = baudrate
        var message = if_msghdr2(
            ifm_msglen: UInt16(MemoryLayout<if_msghdr2>.size + trailing),
            ifm_version: 5,
            ifm_type: type,
            ifm_addrs: 0,
            ifm_flags: 0x8863,
            ifm_index: index,
            ifm_snd_len: 0,
            ifm_snd_maxlen: 0,
            ifm_snd_drops: 0,
            ifm_timer: 0,
            ifm_data: data
        )
        var bytes = withUnsafeBytes(of: &message) { Array($0) }
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: trailing))
        return bytes
    }

    /// 合成一条非 IFINFO2 消息(原始字节,只保证 msglen/version/type 可步进;
    /// 真回包里这些是 ifa/ifma_msghdr,解包器不读它们的字段)。
    private func otherMessage(length: Int, type: UInt8 = 0x13) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = UInt8(length & 0xFF)
        bytes[1] = UInt8((length >> 8) & 0xFF)
        bytes[2] = 5 // version
        bytes[3] = type
        return bytes
    }

    /// 正例:命中 RTM_IFINFO2 且 index 匹配 → 上/下行/线速解出(obytes=上,ibytes=下)。
    func testRouteRecordParsesCountersAndBaudrate() {
        let buffer = ifinfo2(
            index: 14, up: 17_070_513_416, down: 987_654_321,
            baudrate: 304_200_000, upPackets: 4_436, downPackets: 12_070
        )
        let parsed = NetworkRouteRecord.parse(buffer, expectingIndex: 14)
        XCTAssertEqual(parsed?.upBytes, 17_070_513_416)
        XCTAssertEqual(parsed?.downBytes, 987_654_321)
        XCTAssertEqual(parsed?.upPackets, 4_436)
        XCTAssertEqual(parsed?.downPackets, 12_070)
        XCTAssertEqual(parsed?.linkBaudrateBitsPerSecond, 304_200_000)
    }

    /// 真机回包形态(2026-10-16 探针):一次查询回多条消息——IFINFO2 之后跟
    /// NEWADDR/NEWMADDR2;逐条 msglen 步进,只认第一条匹配的 IFINFO2。
    func testRouteRecordStepsThroughMultiMessageReply() {
        var buffer = ifinfo2(index: 14, up: 10, down: 20, trailing: 20)
        buffer.append(contentsOf: otherMessage(length: 60, type: 0x0c))   // RTM_NEWADDR
        buffer.append(contentsOf: otherMessage(length: 76))
        buffer.append(contentsOf: otherMessage(length: 88))
        let parsed = NetworkRouteRecord.parse(buffer, expectingIndex: 14)
        XCTAssertEqual(parsed?.upBytes, 10)
        XCTAssertEqual(parsed?.downBytes, 20)
    }

    /// 非目标接口(index 不匹配):跳过继续找,找不到返回 nil。
    func testRouteRecordSkipsMismatchedIndex() {
        var buffer = ifinfo2(index: 13, up: 1, down: 2)
        buffer.append(contentsOf: ifinfo2(index: 14, up: 3, down: 4))
        XCTAssertEqual(NetworkRouteRecord.parse(buffer, expectingIndex: 14)?.upBytes, 3)
        XCTAssertNil(NetworkRouteRecord.parse(ifinfo2(index: 13, up: 1, down: 2), expectingIndex: 14))
    }

    /// 负例:截断缓冲(放不下完整 if_msghdr2)与零 msglen 都返回 nil,不越界误读。
    func testRouteRecordRejectsTruncatedAndZeroLength() {
        var full = ifinfo2(index: 14, up: 1, down: 2)
        XCTAssertNil(NetworkRouteRecord.parse(Array(full.prefix(MemoryLayout<if_msghdr>.size)), expectingIndex: 14))
        XCTAssertNil(NetworkRouteRecord.parse([], expectingIndex: 14))
        full[0] = 0
        full[1] = 0 // msglen 置 0:防御死循环
        XCTAssertNil(NetworkRouteRecord.parse(full, expectingIndex: 14))
    }

    // MARK: - 差分三件套(合成计数序列)

    /// 防护一(首读置零):无前值只立基线,不把开机以来的累计量当成本轮速率。
    func testFirstReadYieldsZeroRatesAndNoDelta() {
        let result = NetworkRateDiffer.result(
            previous: nil,
            current: NetworkFixture.counters(up: 100_000_000, down: 200_000_000, at: 5_000_000_000)
        )
        XCTAssertEqual(result.rates, .zero)
        XCTAssertEqual(result.upBytesDelta, 0)
        XCTAssertEqual(result.downBytesDelta, 0)
        XCTAssertEqual(result.interface, "en0")
    }

    /// 正常差分:Δ/elapsed;记账增量 = 整段净增(与速率同源)。
    func testRatesDivideDeltaByElapsed() {
        let result = NetworkRateDiffer.result(
            previous: NetworkFixture.counters(up: 1_000, down: 2_000, at: 0),
            current: NetworkFixture.counters(up: 6_000, down: 7_000, at: 5_000_000_000)
        )
        XCTAssertEqual(result.rates.upBytesPerSecond, 1_000, accuracy: 0.0001)
        XCTAssertEqual(result.rates.downBytesPerSecond, 1_000, accuracy: 0.0001)
        XCTAssertEqual(result.upBytesDelta, 5_000)
        XCTAssertEqual(result.downBytesDelta, 5_000)
    }

    /// 防护二(负值钳零):接口重置令计数回退 → 本轮 0(基线由调用方以本轮重立)。
    func testCounterRollbackYieldsZero() {
        let result = NetworkRateDiffer.result(
            previous: NetworkFixture.counters(up: 6_000, down: 7_000, at: 0),
            current: NetworkFixture.counters(up: 1_000, down: 7_000, at: 5_000_000_000)
        )
        XCTAssertEqual(result.rates, .zero)
        XCTAssertEqual(result.upBytesDelta, 0)
        XCTAssertEqual(result.downBytesDelta, 0)
    }

    /// 接口切换:基线属于旧口,直接作废本轮,不出跨口假速率。
    func testInterfaceSwitchYieldsZero() {
        let result = NetworkRateDiffer.result(
            previous: NetworkFixture.counters("en0", up: 1_000, down: 1_000, at: 0),
            current: NetworkFixture.counters("en1", up: 2_000, down: 2_000, at: 5_000_000_000)
        )
        XCTAssertEqual(result.rates, .zero)
        XCTAssertEqual(result.upBytesDelta, 0)
        XCTAssertEqual(result.interface, "en1")
    }

    /// 防护三(重连跳变):Δ 超过协商线速 ×1.5 ×窗口 → 丢弃本轮。
    /// 1 Gbps 链路 5 秒窗上限 = 1e9/8 × 1.5 × 5 = 937.5 MB。
    func testJumpBeyondNegotiatedLinkRateIsDropped() {
        let previous = NetworkFixture.counters(up: 0, down: 0, at: 0)
        let over = NetworkRateDiffer.result(
            previous: previous,
            current: NetworkFixture.counters(up: 937_500_001, down: 0, at: 5_000_000_000)
        )
        XCTAssertEqual(over.rates, .zero, "超线速 1.5 倍的跳变必须丢弃")

        let under = NetworkRateDiffer.result(
            previous: previous,
            current: NetworkFixture.counters(up: 937_500_000, down: 0, at: 5_000_000_000)
        )
        XCTAssertEqual(under.rates.upBytesPerSecond, 187_500_000, accuracy: 0.0001, "线速内的合法猛传不误杀")
    }

    /// 未知链路(线速读不到):按 100 Gbps 兜底上限(12.5 GB/s ×窗口)。
    func testUnknownLinkUsesHundredGigabitCap() {
        let previous = NetworkFixture.counters(up: 0, down: 0, baud: nil, at: 0)
        let over = NetworkRateDiffer.result(
            previous: previous,
            current: NetworkFixture.counters(up: 62_500_000_001, down: 0, baud: nil, at: 5_000_000_000)
        )
        XCTAssertEqual(over.rates, .zero)

        let under = NetworkRateDiffer.result(
            previous: previous,
            current: NetworkFixture.counters(up: 62_500_000_000, down: 0, baud: nil, at: 5_000_000_000)
        )
        XCTAssertEqual(under.rates.upBytesPerSecond, 12_500_000_000, accuracy: 0.0001)
    }

    /// 线速 0(隧道口 ifi_baudrate 恒 0,2026-10-16 实测)同未知:走 100 Gbps
    /// 兜底,不能按"已知 0 速链路"把每一轮都打死。
    func testZeroBaudrateIsTreatedAsUnknown() {
        let previous = NetworkFixture.counters(up: 0, down: 0, baud: 0, at: 0)
        let result = NetworkRateDiffer.result(
            previous: previous,
            current: NetworkFixture.counters(up: 100_000_000, down: 0, baud: 0, at: 5_000_000_000)
        )
        XCTAssertEqual(result.rates.upBytesPerSecond, 20_000_000, accuracy: 0.0001, "正常流量不被零线速打死")
        XCTAssertEqual(result.upBytesDelta, 100_000_000)
    }

    /// elapsed 非正(时钟异常/同刻):本轮 0。
    func testNonPositiveElapsedYieldsZero() {
        let result = NetworkRateDiffer.result(
            previous: NetworkFixture.counters(up: 1_000, down: 1_000, at: 5_000_000_000),
            current: NetworkFixture.counters(up: 2_000, down: 2_000, at: 5_000_000_000)
        )
        XCTAssertEqual(result.rates, .zero)
    }

    // MARK: - 入向死表回退(2026-10-16 本机实证:en0 入向计数冻结)

    /// 死表判定:有出无入(收包计数开机累计,双零 = 闲置链路不算死表)。
    func testInboundDeadPredicate() {
        XCTAssertTrue(
            NetworkInterfaceSelector.isInboundDead(
                NetworkFixture.counters(up: 18_617_101_300, down: 0, upPackets: 44_367_146, downPackets: 0, at: 1)
            ),
            "opackets 在走而 ipackets 恒 0 = 入向死表"
        )
        XCTAssertFalse(
            NetworkInterfaceSelector.isInboundDead(
                NetworkFixture.counters(up: 100, down: 200, upPackets: 10, downPackets: 20, at: 1)
            ),
            "双向都在走 = 健康口"
        )
        XCTAssertFalse(
            NetworkInterfaceSelector.isInboundDead(
                NetworkFixture.counters(up: 0, down: 0, upPackets: 0, downPackets: 0, at: 1)
            ),
            "双零 = 闲置链路,不是死表"
        )
    }

    // MARK: - 走势环(纯逻辑)

    /// 环容量满挤掉最旧(图表窗口固定),合计口径 = 上 + 下。
    func testTrendBufferEvictsOldestBeyondCapacity() {
        var buffer = NetworkTrendBuffer()
        for index in 0..<(NetworkTrendBuffer.capacity + 5) {
            buffer.append(NetworkRates(upBytesPerSecond: Double(index), downBytesPerSecond: 1))
        }
        let totals = buffer.totalBytesPerSecond
        XCTAssertEqual(totals.count, NetworkTrendBuffer.capacity)
        XCTAssertEqual(totals.first, 6, "注入 65 轮挤掉最旧 5 个:首个幸存序号 5,合计 5+1")
        XCTAssertEqual(totals.last, Double(NetworkTrendBuffer.capacity + 4) + 1)
    }
}
