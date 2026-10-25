import Darwin
import Foundation

// 网络吞吐的纯值层:计数 / 读数 / 走势环 / 接口选择 / 回包解包 / 差分三件套与源接缝。sysctl / SCDynamicStore / getifaddrs 适配器在 app target(NetworkSensor.swift)。

/// 单接口累计字节计数(NET_RT_IFLIST2 一次回包的取值;差分的输入)。
public struct NetworkCounters: Equatable, Sendable {
    /// 被统计的接口名("en0"…)——差分身份:换口 = 基线作废。
    public let interface: String
    /// ifi_obytes:累计发送。
    public let upBytes: UInt64
    /// ifi_ibytes:累计接收。
    public let downBytes: UInt64
    /// ifi_opackets:累计发包数(入向死表判定的对照信号)。
    public let upPackets: UInt64
    /// ifi_ipackets:累计收包数;为 0 而 opackets 在走 = 该口入向计数死表。
    public let downPackets: UInt64
    /// ifi_baudrate 协商线速(bit/s,探针实证);nil = 读不到(跳变防护走兜底上限)。
    public let linkBaudrateBitsPerSecond: UInt64?
    /// 采样时刻(mach 绝对时间纳秒;只用于算 elapsed,跨源不可比)。
    public let atUptimeNanos: UInt64

    public init(
        interface: String,
        upBytes: UInt64,
        downBytes: UInt64,
        upPackets: UInt64,
        downPackets: UInt64,
        linkBaudrateBitsPerSecond: UInt64? = nil,
        atUptimeNanos: UInt64
    ) {
        self.interface = interface
        self.upBytes = upBytes
        self.downBytes = downBytes
        self.upPackets = upPackets
        self.downPackets = downPackets
        self.linkBaudrateBitsPerSecond = linkBaudrateBitsPerSecond
        self.atUptimeNanos = atUptimeNanos
    }
}

/// 一轮差分出的上下行速率(字节/秒)。
public struct NetworkRates: Equatable, Sendable {
    public let upBytesPerSecond: Double
    public let downBytesPerSecond: Double

    public static let zero = NetworkRates(upBytesPerSecond: 0, downBytesPerSecond: 0)

    public init(upBytesPerSecond: Double, downBytesPerSecond: Double) {
        self.upBytesPerSecond = upBytesPerSecond
        self.downBytesPerSecond = downBytesPerSecond
    }
}

/// 一轮差分结果:速率 + 记账增量(Today/7 天累计 = 对增量逐轮求和落库)。
/// 丢弃轮(首读/负值/跳变/换口)速率为 0、增量为 0;基线一律以本轮计数重立。
public struct NetworkRoundResult: Equatable, Sendable {
    /// 本轮统计的接口(展示用;differ 只在计数在场时被调,恒有名)。
    public let interface: String
    public let rates: NetworkRates
    public let upBytesDelta: UInt64
    public let downBytesDelta: UInt64

    /// 丢弃轮形状(接口仍如实带出)。
    public static func dropped(interface: String) -> NetworkRoundResult {
        NetworkRoundResult(
            interface: interface,
            rates: .zero,
            upBytesDelta: 0,
            downBytesDelta: 0
        )
    }

    public init(interface: String, rates: NetworkRates, upBytesDelta: UInt64, downBytesDelta: UInt64) {
        self.interface = interface
        self.rates = rates
        self.upBytesDelta = upBytesDelta
        self.downBytesDelta = downBytesDelta
    }
}

/// 网络速率读数(UI 形状):当前速率 + 被统计的物理口名。
public struct NetworkRatesReading: Equatable, Sendable {
    public let rates: NetworkRates
    /// 接口名;nil = 未知(展示占位)。
    public let interfaceName: String?

    public init(rates: NetworkRates, interfaceName: String? = nil) {
        self.rates = rates
        self.interfaceName = interfaceName
    }
}

/// 网络 Today/7 天累计(工单 06;历史库 SQL 聚合的读回形状)。
/// rx = 接收 = 下行,tx = 发送 = 上行(与 system_min/system_hour 列名同源)。
public struct NetworkTotalsReading: Equatable, Sendable {
    public let todayDownBytes: UInt64
    public let todayUpBytes: UInt64
    public let weekDownBytes: UInt64
    public let weekUpBytes: UInt64

    public init(todayDownBytes: UInt64, todayUpBytes: UInt64, weekDownBytes: UInt64, weekUpBytes: UInt64) {
        self.todayDownBytes = todayDownBytes
        self.todayUpBytes = todayUpBytes
        self.weekDownBytes = weekDownBytes
        self.weekUpBytes = weekUpBytes
    }
}

/// 网络速率走势环(纯逻辑):心跳轮结果逐轮追加,容量满挤掉最旧——
/// 网络页面积图的数据源。形状与 SampleHistoryStore 同款(内存,永不落盘)。
public struct NetworkTrendBuffer: Equatable, Sendable {
    /// 环容量:与走势图宽(56 点)同级,略留余量。
    public static let capacity = 60

    /// 走势环收编(p2-review/06):窗口语义住在核心 TrendRing,本类型只承载
    /// 网络速率值与图表口径。
    private var ring = TrendRing<NetworkRates>(limit: NetworkTrendBuffer.capacity)

    /// 追加一轮速率(丢弃轮的 0 也入环——图表如实画谷底,不跳点)。
    public mutating func append(_ rates: NetworkRates) {
        ring.append(rates)
    }

    /// 图表口径:上 + 下合计流量(与磁盘卡"读写合计"同款惯例)。
    public var totalBytesPerSecond: [Double] {
        ring.values.map { $0.upBytesPerSecond + $0.downBytesPerSecond }
    }

    public init() {}
}

/// 一行 getifaddrs 链路状态(选择器的输入;测试注入假链路状态的载体)。
public struct NetworkInterfaceState: Equatable, Sendable {
    public let name: String
    /// ifa_flags 原样(IFF_* 位组合)。
    public let flags: Int32
    /// 该行地址族(AF_INET=2 / AF_INET6=30 / 无地址 = 0)。
    public let addressFamily: Int32

    public init(name: String, flags: Int32, addressFamily: Int32) {
        self.name = name
        self.flags = flags
        self.addressFamily = addressFamily
    }
}

/// 接口选择降级链(stats readers.swift:111-165 的纯逻辑半边):
/// SCDynamicStore 主接口非虚拟 → 直接用;虚拟(VPN/隧道在前)或缺席 →
/// getifaddrs 候选里找物理口。OrbStack/corplink 机器上这层降级是刚需。
public enum NetworkInterfaceSelector {
    /// sys/net/if.h 的 IFF_* 是 C 宏不进 Swift,照 SDK 头手抄(DiskSensor 常量同款纪律)。
    public static let iffUp: Int32 = 0x1
    public static let iffLoopback: Int32 = 0x8
    public static let iffPointToPoint: Int32 = 0x10
    public static let iffRunning: Int32 = 0x40

    /// 虚拟接口前缀(stats virtualInterfacePrefixes,readers.swift:117 原样)
    /// + "vmenet"/"bridge"(OrbStack 虚拟网卡与桥——工单明示 OrbStack 用户,
    /// 候选回退时不得把 VM 流量当物理口;主接口路径不受影响,SCDynamicStore
    /// 的 PrimaryInterface 不会落在这些口上)。
    public static let virtualPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg", "vmenet", "bridge"]

    public static func isVirtual(_ name: String) -> Bool {
        virtualPrefixes.contains { name.hasPrefix($0) }
    }

    /// 降级链主入口:primary = SCDynamicStore 主接口名(缺席为 nil)。
    /// 找不到可用物理口返回 nil(本轮占位,不硬选)。
    public static func select(primary: String?, candidates: [NetworkInterfaceState]) -> String? {
        if let primary, !isVirtual(primary) {
            return primary
        }
        // 降级(stats physicalInterface 的 getifaddrs 半边):UP+RUNNING、
        // 非 loopback、非 pointopoint、有 IPv4 地址、非虚拟前缀,首个命中。
        for candidate in candidates where isPhysicalCandidate(candidate) {
            return candidate.name
        }
        return nil
    }

    /// 候选资格(stats readers.swift:150-161 同款过滤)。
    public static func isPhysicalCandidate(_ candidate: NetworkInterfaceState) -> Bool {
        candidate.flags & iffUp != 0
            && candidate.flags & iffRunning != 0
            && candidate.flags & iffLoopback == 0
            && candidate.flags & iffPointToPoint == 0
            && candidate.addressFamily == Int32(AF_INET)
            && !isVirtual(candidate.name)
    }

    /// 回退候选资格(入向死表回退用):UP + RUNNING、非 loopback 即可——
    /// **不滤虚拟前缀与 p2p**(要找的恰是承载真实流量的隧道口),死表口自身除外。
    public static func isLiveCandidate(_ candidate: NetworkInterfaceState) -> Bool {
        candidate.flags & iffUp != 0
            && candidate.flags & iffRunning != 0
            && candidate.flags & iffLoopback == 0
    }

    /// 入向计数死表(纯判定):ifi_ipackets 恒 0 而 ifi_opackets 在走——
    /// 收包计数是开机累计,有出无入只能是驱动没维护入向(2026-10-16 本机
    /// en0 实证,netstat -ib 同证)。双零 = 闲置链路,不算死表。
    public static func isInboundDead(_ counters: NetworkCounters) -> Bool {
        counters.downPackets == 0 && counters.upPackets > 0
    }
}

/// NET_RT_IFLIST2 回包解析(stats getBytesInfo,readers.swift:714-736):
/// 缓冲内逐条消息按 ifm_msglen 步进(一次查询会回 IFINFO2/NEWADDR/NEWMADDR2
/// 多条,探针实证),只认 RTM_IFINFO2 的 if_msghdr2 并校验 ifm_index;命中取
/// ifi_obytes/ifi_ibytes/ifi_baudrate。
public enum NetworkRouteRecord {
    /// C 宏不进 Swift,照 SDK 头手抄(net/route.h:RTM_IFINFO2、sys/socket.h:NET_RT_IFLIST2)。
    public static let rtmIfInfo2: Int32 = 0x12
    public static let netRtIfList2: Int32 = 6

    public struct Parsed: Equatable, Sendable {
        public let upBytes: UInt64
        public let downBytes: UInt64
        public let upPackets: UInt64
        public let downPackets: UInt64
        public let linkBaudrateBitsPerSecond: UInt64

        public init(
            upBytes: UInt64,
            downBytes: UInt64,
            upPackets: UInt64,
            downPackets: UInt64,
            linkBaudrateBitsPerSecond: UInt64
        ) {
            self.upBytes = upBytes
            self.downBytes = downBytes
            self.upPackets = upPackets
            self.downPackets = downPackets
            self.linkBaudrateBitsPerSecond = linkBaudrateBitsPerSecond
        }
    }

    /// 解析整个回包,返回第一条匹配 IFINFO2 记录;截断/零长消息/index 不匹配
    /// 返回 nil(不越界误读,stats 同款负例口径)。
    public static func parse(_ buffer: [UInt8], expectingIndex index: UInt32) -> Parsed? {
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= buffer.count {
            let header = buffer.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            }
            guard header.ifm_msglen > 0 else { return nil }
            // IFINFO2 的结构体可能短于消息全长(尾部是 sockaddr 填充):只读结构体范围。
            if Int32(header.ifm_type) == rtmIfInfo2,
               offset + MemoryLayout<if_msghdr2>.size <= buffer.count {
                let full = buffer.withUnsafeBytes { raw in
                    raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                }
                if UInt32(full.ifm_index) == index {
                    return Parsed(
                        upBytes: full.ifm_data.ifi_obytes,
                        downBytes: full.ifm_data.ifi_ibytes,
                        upPackets: full.ifm_data.ifi_opackets,
                        downPackets: full.ifm_data.ifi_ipackets,
                        linkBaudrateBitsPerSecond: full.ifm_data.ifi_baudrate
                    )
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return nil
    }
}

/// 心跳轮差分(stats read() 的 readInterfaceBandwidth 段,readers.swift:304-323
/// 翻译):首读置零(只立基线)→ 换口作废 → 计数回退钳零 → elapsed 有限 →
/// 跳变超过"线速 ×1.5(未知按 100 Gbps)×窗口"丢弃;丢弃轮速率与增量皆 0。
/// 基线重立由调用方负责(与磁盘 Accumulator 同口径:无论成败都以本轮计数为准)。
public enum NetworkRateDiffer {
    /// 未知链路的跳变上限:100 Gbps(stats 同款兜底,bit/s → 字节/s)。
    public static let unknownLinkCapBytesPerSecond: Double = 12_500_000_000

    public static func result(previous: NetworkCounters?, current: NetworkCounters) -> NetworkRoundResult {
        guard let previous else { return .dropped(interface: current.interface) } // 首读:立基线
        guard previous.interface == current.interface else {
            return .dropped(interface: current.interface) // 换口:旧基线不跨口比较
        }
        // 计数回退(接口重置/重连清零)→ 本轮 0。
        guard current.upBytes >= previous.upBytes,
              current.downBytes >= previous.downBytes, current.atUptimeNanos > previous.atUptimeNanos else {
            return .dropped(interface: current.interface)
        }
        let elapsed = Double(current.atUptimeNanos - previous.atUptimeNanos) / 1_000_000_000
        guard elapsed > 0, elapsed.isFinite else { return .dropped(interface: current.interface) }

        let upDelta = current.upBytes - previous.upBytes
        let downDelta = current.downBytes - previous.downBytes

        // 跳变防护:双向各不得超"协商线速 ×1.5"(50% headroom,stats 同款);
        // 线速未知按 100 Gbps 兜底。0 同样按未知算(隧道口 ifi_baudrate 恒 0,
        // 2026-10-16 实测——按"已知 0 速链路"算上限会把每一轮都打死)。
        let capBytesPerSecond: Double = if let baudrate = current.linkBaudrateBitsPerSecond, baudrate > 0 {
            Double(baudrate) / 8 * 1.5
        } else {
            unknownLinkCapBytesPerSecond
        }
        let capBytes = capBytesPerSecond * elapsed
        if Double(upDelta) > capBytes || Double(downDelta) > capBytes {
            return .dropped(interface: current.interface)
        }

        let up = Double(upDelta) / elapsed
        let down = Double(downDelta) / elapsed
        guard up.isFinite, down.isFinite else { return .dropped(interface: current.interface) }
        return NetworkRoundResult(
            interface: current.interface,
            rates: NetworkRates(upBytesPerSecond: up, downBytesPerSecond: down),
            upBytesDelta: upDelta,
            downBytesDelta: downDelta
        )
    }
}

/// 主接口名源(SCDynamicStore 半边)。
public protocol NetworkPrimaryInterfaceSource: Sendable {
    /// nil = 无活动主接口(SCDynamicStore 读不到 / 无 PrimaryInterface)。
    func primaryInterfaceName() -> String?
}

/// 接口链路状态源(getifaddrs 半边)。
public protocol NetworkInterfaceListSource: Sendable {
    func interfaces() -> [NetworkInterfaceState]
}

/// 网络计数源接缝(spec"网络计数源"):一次 sample 取"选定接口的累计计数"。
/// 心跳型(spec):住 Sampler 循环,每轮一次 sysctl。nil = 本轮读不到
/// (无可用接口 / sysctl 失败),差分保留旧基线等下一轮。
public protocol NetworkCountersSource: Sendable {
    func sample() -> NetworkCounters?
}

/// 合成计数源(测试与 SwiftUI 预览的确定性地基,ProcessSource 同款口径):
/// 按调用顺序吐出注入的计数序列(元素可为 nil = 模拟读缺失),耗尽后停在
/// 末个。线程安全,可跨并发域持有。
public final class ScriptedNetworkCountersSource: NetworkCountersSource, @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [NetworkCounters?]
    private var nextIndex = 0

    public init(samples: [NetworkCounters?]) {
        precondition(!samples.isEmpty, "ScriptedNetworkCountersSource 需要至少一个样本")
        self.samples = samples
    }

    public func sample() -> NetworkCounters? {
        lock.lock()
        defer { lock.unlock() }
        let current = samples[min(nextIndex, samples.count - 1)]
        nextIndex += 1
        return current
    }
}
