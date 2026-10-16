import Darwin
import Foundation
import SystemConfiguration

// 网络计数与接口选择算法移植自 stats(MIT)Modules/Net/readers.swift(调研
// docs/research/sensor-impl-comparison.md §2.2 逐条钉死;依 spec 移植代码纪律
// 注明来源):
//   单接口字节计数 = sysctl mib [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, index]
//   两段式调用(readers.swift:704-712);解包逐 if_msghdr 以 msglen 步进,只认
//   RTM_IFINFO2 的 if_msghdr2 并校验 ifm_index(readers.swift:714-736);取
//   ifi_obytes(上行)/ifi_ibytes(下行)。
//   差分防坑三件套(readers.swift:304-323):首读不产速率 / 负值钳零 / 重连
//   跳变超过"协商线速 ×1.5 ×窗口"(未知按 100 Gbps)丢弃本轮。
//   接口选择(readers.swift:111-165):SCDynamicStore 主接口,utun/ipsec/ppp/
//   tun/tap/gif/stf/wg 等虚拟前缀降级找物理口;回退用 getifaddrs 过滤
//   UP+RUNNING+非 loopback+非 pointopoint。
// 不抄的部分:stats 的 VPN"带宽除二"启发式(readers.swift:330-333)——我们
// 锁定物理口后单接口计数即真值,不需要补丁;公网 IP 查询违反"全程本地无网络"
// 边界,不做。
// 2026-10-16 真机探针(工单 06 临时脚本)钉死三件事:if_msghdr2 在 Swift 可见、
// 一次回包含 IFINFO2/NEWADDR/NEWMADDR2 多条消息(步进解析必要)、ifi_baudrate
// 单位为 bit/s(en0 协商 304.2 Mbps)。
// 同日对照发现本机 en0 入向计数死表(netstat -ib 同证:Ipkts/Ibytes 恒 0 而
// Opkts 在走,corplink 开关两态一致——驱动级冻结,Stats/活动监视器读同源
// 计数同样失明);下载实测入向流量被折叠进 en0 的 Obytes(方向不可拆)。
// corplink 开启时公网流量实际走 utun4,其双向计数健全。据此加"入向死表
// 回退"(LiveNetworkCountersSource):物理口入向死表且存在入向在场的
// UP+RUNNING 口(典型:隧道口)时改读后者——单一接口计数,不翻倍不归零;
// 无活口(如 corplink 关 + 本机 en0 死表)保持物理口,down 显示 0 是内核
// 真相,不伪造。

// MARK: - 计数与读数(纯值)

/// 单接口累计字节计数(NET_RT_IFLIST2 一次回包的取值;差分的输入)。
struct NetworkCounters: Equatable, Sendable {
    /// 被统计的接口名("en0"…)——差分身份:换口 = 基线作废。
    let interface: String
    /// ifi_obytes:累计发送。
    let upBytes: UInt64
    /// ifi_ibytes:累计接收。
    let downBytes: UInt64
    /// ifi_opackets:累计发包数(入向死表判定的对照信号)。
    let upPackets: UInt64
    /// ifi_ipackets:累计收包数;为 0 而 opackets 在走 = 该口入向计数死表。
    let downPackets: UInt64
    /// ifi_baudrate 协商线速(bit/s,探针实证);nil = 读不到(跳变防护走兜底上限)。
    let linkBaudrateBitsPerSecond: UInt64?
    /// 采样时刻(mach 绝对时间纳秒;只用于算 elapsed,跨源不可比)。
    let atUptimeNanos: UInt64
}

/// 一轮差分出的上下行速率(字节/秒)。
struct NetworkRates: Equatable, Sendable {
    let upBytesPerSecond: Double
    let downBytesPerSecond: Double

    static let zero = NetworkRates(upBytesPerSecond: 0, downBytesPerSecond: 0)
}

/// 一轮差分结果:速率 + 记账增量(Today/7 天累计 = 对增量逐轮求和落库)。
/// 丢弃轮(首读/负值/跳变/换口)速率为 0、增量为 0;基线一律以本轮计数重立。
struct NetworkRoundResult: Equatable, Sendable {
    /// 本轮统计的接口(展示用;differ 只在计数在场时被调,恒有名)。
    let interface: String
    let rates: NetworkRates
    let upBytesDelta: UInt64
    let downBytesDelta: UInt64

    /// 丢弃轮形状(接口仍如实带出)。
    static func dropped(interface: String) -> NetworkRoundResult {
        NetworkRoundResult(
            interface: interface,
            rates: .zero,
            upBytesDelta: 0,
            downBytesDelta: 0
        )
    }
}

/// 网络速率读数(UI 形状):当前速率 + 被统计的物理口名。
struct NetworkRatesReading: Equatable, Sendable {
    let rates: NetworkRates
    /// 接口名;nil = 未知(展示占位)。
    let interfaceName: String?
}

/// 网络 Today/7 天累计(工单 06;历史库 SQL 聚合的读回形状)。
/// rx = 接收 = 下行,tx = 发送 = 上行(与 system_min/system_hour 列名同源)。
struct NetworkTotalsReading: Equatable, Sendable {
    let todayDownBytes: UInt64
    let todayUpBytes: UInt64
    let weekDownBytes: UInt64
    let weekUpBytes: UInt64
}

// MARK: - 速率走势环(纯逻辑)

/// 网络速率走势环(纯逻辑):心跳轮结果逐轮追加,容量满挤掉最旧——
/// 网络页面积图的数据源。形状与 SampleHistoryStore 同款(内存,永不落盘)。
struct NetworkTrendBuffer: Equatable, Sendable {
    /// 环容量:与走势图宽(56 点)同级,略留余量。
    static let capacity = 60

    private var values: [NetworkRates] = []

    /// 追加一轮速率(丢弃轮的 0 也入环——图表如实画谷底,不跳点)。
    mutating func append(_ rates: NetworkRates) {
        values.append(rates)
        if values.count > Self.capacity {
            values.removeFirst(values.count - Self.capacity)
        }
    }

    /// 图表口径:上 + 下合计流量(与磁盘卡"读写合计"同款惯例)。
    var totalBytesPerSecond: [Double] {
        values.map { $0.upBytesPerSecond + $0.downBytesPerSecond }
    }
}

// MARK: - 接口选择与降级(纯逻辑)

/// 一行 getifaddrs 链路状态(选择器的输入;测试注入假链路状态的载体)。
struct NetworkInterfaceState: Equatable, Sendable {
    let name: String
    /// ifa_flags 原样(IFF_* 位组合)。
    let flags: Int32
    /// 该行地址族(AF_INET=2 / AF_INET6=30 / 无地址 = 0)。
    let addressFamily: Int32
}

/// 接口选择降级链(stats readers.swift:111-165 的纯逻辑半边):
/// SCDynamicStore 主接口非虚拟 → 直接用;虚拟(VPN/隧道在前)或缺席 →
/// getifaddrs 候选里找物理口。OrbStack/corplink 机器上这层降级是刚需。
enum NetworkInterfaceSelector {
    /// sys/net/if.h 的 IFF_* 是 C 宏不进 Swift,照 SDK 头手抄(DiskSensor 常量同款纪律)。
    static let iffUp: Int32 = 0x1
    static let iffLoopback: Int32 = 0x8
    static let iffPointToPoint: Int32 = 0x10
    static let iffRunning: Int32 = 0x40

    /// 虚拟接口前缀(stats virtualInterfacePrefixes,readers.swift:117 原样)
    /// + "vmenet"/"bridge"(OrbStack 虚拟网卡与桥——工单明示 OrbStack 用户,
    /// 候选回退时不得把 VM 流量当物理口;主接口路径不受影响,SCDynamicStore
    /// 的 PrimaryInterface 不会落在这些口上)。
    static let virtualPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg", "vmenet", "bridge"]

    static func isVirtual(_ name: String) -> Bool {
        virtualPrefixes.contains { name.hasPrefix($0) }
    }

    /// 降级链主入口:primary = SCDynamicStore 主接口名(缺席为 nil)。
    /// 找不到可用物理口返回 nil(本轮占位,不硬选)。
    static func select(primary: String?, candidates: [NetworkInterfaceState]) -> String? {
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
    static func isPhysicalCandidate(_ candidate: NetworkInterfaceState) -> Bool {
        candidate.flags & iffUp != 0
            && candidate.flags & iffRunning != 0
            && candidate.flags & iffLoopback == 0
            && candidate.flags & iffPointToPoint == 0
            && candidate.addressFamily == Int32(AF_INET)
            && !isVirtual(candidate.name)
    }

    /// 回退候选资格(入向死表回退用):UP + RUNNING、非 loopback 即可——
    /// **不滤虚拟前缀与 p2p**(要找的恰是承载真实流量的隧道口),死表口自身除外。
    static func isLiveCandidate(_ candidate: NetworkInterfaceState) -> Bool {
        candidate.flags & iffUp != 0
            && candidate.flags & iffRunning != 0
            && candidate.flags & iffLoopback == 0
    }

    /// 入向计数死表(纯判定):ifi_ipackets 恒 0 而 ifi_opackets 在走——
    /// 收包计数是开机累计,有出无入只能是驱动没维护入向(2026-10-16 本机
    /// en0 实证,netstat -ib 同证)。双零 = 闲置链路,不算死表。
    static func isInboundDead(_ counters: NetworkCounters) -> Bool {
        counters.downPackets == 0 && counters.upPackets > 0
    }
}

// MARK: - 回包解包(纯逻辑)

/// NET_RT_IFLIST2 回包解析(stats getBytesInfo,readers.swift:714-736):
/// 缓冲内逐条消息按 ifm_msglen 步进(一次查询会回 IFINFO2/NEWADDR/NEWMADDR2
/// 多条,探针实证),只认 RTM_IFINFO2 的 if_msghdr2 并校验 ifm_index;命中取
/// ifi_obytes/ifi_ibytes/ifi_baudrate。
enum NetworkRouteRecord {
    /// C 宏不进 Swift,照 SDK 头手抄(net/route.h:RTM_IFINFO2、sys/socket.h:NET_RT_IFLIST2)。
    static let rtmIfInfo2: Int32 = 0x12
    static let netRtIfList2: Int32 = 6

    struct Parsed: Equatable, Sendable {
        let upBytes: UInt64
        let downBytes: UInt64
        let upPackets: UInt64
        let downPackets: UInt64
        let linkBaudrateBitsPerSecond: UInt64
    }

    /// 解析整个回包,返回第一条匹配 IFINFO2 记录;截断/零长消息/index 不匹配
    /// 返回 nil(不越界误读,stats 同款负例口径)。
    static func parse(_ buffer: [UInt8], expectingIndex index: UInt32) -> Parsed? {
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

// MARK: - 差分三件套(纯逻辑)

/// 心跳轮差分(stats read() 的 readInterfaceBandwidth 段,readers.swift:304-323
/// 翻译):首读置零(只立基线)→ 换口作废 → 计数回退钳零 → elapsed 有限 →
/// 跳变超过"线速 ×1.5(未知按 100 Gbps)×窗口"丢弃;丢弃轮速率与增量皆 0。
/// 基线重立由调用方负责(与磁盘 Accumulator 同口径:无论成败都以本轮计数为准)。
enum NetworkRateDiffer {
    /// 未知链路的跳变上限:100 Gbps(stats 同款兜底,bit/s → 字节/s)。
    static let unknownLinkCapBytesPerSecond: Double = 12_500_000_000

    static func result(previous: NetworkCounters?, current: NetworkCounters) -> NetworkRoundResult {
        guard let previous else { return .dropped(interface: current.interface) } // 首读:立基线
        guard previous.interface == current.interface else {
            return .dropped(interface: current.interface) // 换口:旧基线不跨口比较
        }
        // 计数回退(接口重置/重连清零)→ 本轮 0。
        guard current.upBytes >= previous.upBytes,
            current.downBytes >= previous.downBytes
        else { return .dropped(interface: current.interface) }
        guard current.atUptimeNanos > previous.atUptimeNanos else {
            return .dropped(interface: current.interface)
        }
        let elapsed = Double(current.atUptimeNanos - previous.atUptimeNanos) / 1_000_000_000
        guard elapsed > 0, elapsed.isFinite else { return .dropped(interface: current.interface) }

        let upDelta = current.upBytes - previous.upBytes
        let downDelta = current.downBytes - previous.downBytes

        // 跳变防护:双向各不得超"协商线速 ×1.5"(50% headroom,stats 同款);
        // 线速未知按 100 Gbps 兜底。0 同样按未知算(隧道口 ifi_baudrate 恒 0,
        // 2026-10-16 实测——按"已知 0 速链路"算上限会把每一轮都打死)。
        let capBytesPerSecond: Double
        if let baudrate = current.linkBaudrateBitsPerSecond, baudrate > 0 {
            capBytesPerSecond = Double(baudrate) / 8 * 1.5
        } else {
            capBytesPerSecond = unknownLinkCapBytesPerSecond
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

// MARK: - 源缝协议(OS 边界,spec 六缝之网络计数源)

/// 主接口名源(SCDynamicStore 半边)。
protocol NetworkPrimaryInterfaceSource: Sendable {
    /// nil = 无活动主接口(SCDynamicStore 读不到 / 无 PrimaryInterface)。
    func primaryInterfaceName() -> String?
}

/// 接口链路状态源(getifaddrs 半边)。
protocol NetworkInterfaceListSource: Sendable {
    func interfaces() -> [NetworkInterfaceState]
}

/// 网络计数源接缝(spec"网络计数源"):一次 sample 取"选定接口的累计计数"。
/// 心跳型(spec):住 Sampler 循环,每轮一次 sysctl。nil = 本轮读不到
/// (无可用接口 / sysctl 失败),差分保留旧基线等下一轮。
protocol NetworkCountersSource: Sendable {
    func sample() -> NetworkCounters?
}

// MARK: - Live 源

/// SCDynamicStore 主接口(stats readers.swift:112-117):State:/Network/Global/IPv4
/// 的 PrimaryInterface;拿不到返回 nil。
struct SCDynamicStorePrimaryInterfaceSource: NetworkPrimaryInterfaceSource {
    func primaryInterfaceName() -> String? {
        guard
            let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString),
            let dictionary = global as? [String: Any],
            let name = dictionary["PrimaryInterface"] as? String
        else { return nil }
        return name
    }
}

/// getifaddrs 全表(stats readers.swift:146-165 同款遍历):每行取接口名 /
/// 链路旗标 / 地址族;无地址行 family 记 0(选择器过滤)。
struct GetifaddrsInterfaceListSource: NetworkInterfaceListSource {
    func interfaces() -> [NetworkInterfaceState] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return [] }
        defer { freeifaddrs(addresses) }

        var states: [NetworkInterfaceState] = []
        var cursor = addresses
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            var family: Int32 = 0
            if let address = current.pointee.ifa_addr {
                family = Int32(address.pointee.sa_family)
            }
            states.append(
                NetworkInterfaceState(
                    name: String(cString: current.pointee.ifa_name),
                    flags: Int32(current.pointee.ifa_flags),
                    addressFamily: family
                )
            )
        }
        return states
    }
}

/// 单接口计数读取(if_nametoindex + sysctl 两段式,stats readers.swift:704-736
/// 翻译):mib [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, index],先问尺寸再读
/// 全量,解析交给纯逻辑 NetworkRouteRecord。
enum NetworkCountersReader {
    static func read(interface name: String) -> NetworkCounters? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NetworkRouteRecord.netRtIfList2, Int32(index)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        guard
            let parsed = NetworkRouteRecord.parse(Array(buffer.prefix(Int(size))), expectingIndex: index)
        else { return nil }
        return NetworkCounters(
            interface: name,
            upBytes: parsed.upBytes,
            downBytes: parsed.downBytes,
            upPackets: parsed.upPackets,
            downPackets: parsed.downPackets,
            linkBaudrateBitsPerSecond: parsed.linkBaudrateBitsPerSecond,
            atUptimeNanos: DispatchTime.now().uptimeNanoseconds
        )
    }
}

/// Live 计数源:降级链(纯逻辑)选定物理口 → NET_RT_IFLIST2 读计数;入向
/// 死表回退(2026-10-16 本机实证,见文件头)——物理口收包计数恒 0 时改读
/// "入向真正在场的活口"(典型:corplink 分流后的 utun4,双向计数健全)。
/// 活口取 UP+RUNNING 候选里累计入向字节最多者(闲置 utun 有历史零星包,
/// 不能按 >0 挑);无活口保持物理口(down = 0 是内核真相,不伪造)。接口
/// 每次现选(VPN 连断/网线插拔下一轮即跟随,不做缓存)——每轮 sysctl 数次,
/// 成本可忽略。
struct LiveNetworkCountersSource: NetworkCountersSource {
    private let primarySource: any NetworkPrimaryInterfaceSource
    private let listSource: any NetworkInterfaceListSource
    /// 计数读取缝(默认真 sysctl;测试注入假读数钉死回退编排)。
    private let read: @Sendable (String) -> NetworkCounters?

    init(
        primarySource: any NetworkPrimaryInterfaceSource = SCDynamicStorePrimaryInterfaceSource(),
        listSource: any NetworkInterfaceListSource = GetifaddrsInterfaceListSource(),
        read: @escaping @Sendable (String) -> NetworkCounters? = NetworkCountersReader.read(interface:)
    ) {
        self.primarySource = primarySource
        self.listSource = listSource
        self.read = read
    }

    func sample() -> NetworkCounters? {
        let candidates = listSource.interfaces()
        let name = NetworkInterfaceSelector.select(
            primary: primarySource.primaryInterfaceName(),
            candidates: candidates
        )
        guard let name, let counters = read(name) else { return nil }
        guard NetworkInterfaceSelector.isInboundDead(counters) else { return counters }

        // 入向死表回退:活口 = UP+RUNNING、非 loopback、非死表口自身,入向
        // 包数在场;取累计入向字节最多者(宁多读几口 sysctl,仍是便宜路径)。
        var best: NetworkCounters?
        for candidate in candidates
        where NetworkInterfaceSelector.isLiveCandidate(candidate) && candidate.name != name {
            guard let candidateCounters = read(candidate.name),
                candidateCounters.downPackets > 0
            else { continue }
            if best == nil || candidateCounters.downBytes > best?.downBytes ?? 0 {
                best = candidateCounters
            }
        }
        return best ?? counters
    }
}

/// 合成计数源(测试与 SwiftUI 预览的确定性地基,ProcessSource 同款口径):
/// 按调用顺序吐出注入的计数序列(元素可为 nil = 模拟读缺失),耗尽后停在
/// 末个。线程安全,可跨并发域持有。
final class ScriptedNetworkCountersSource: NetworkCountersSource, @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [NetworkCounters?]
    private var nextIndex = 0

    init(samples: [NetworkCounters?]) {
        precondition(!samples.isEmpty, "ScriptedNetworkCountersSource 需要至少一个样本")
        self.samples = samples
    }

    func sample() -> NetworkCounters? {
        lock.lock()
        defer { lock.unlock() }
        let current = samples[min(nextIndex, samples.count - 1)]
        nextIndex += 1
        return current
    }
}
