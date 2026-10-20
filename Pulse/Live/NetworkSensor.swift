import Darwin
import Foundation
import SystemConfiguration
import PulseCore

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

