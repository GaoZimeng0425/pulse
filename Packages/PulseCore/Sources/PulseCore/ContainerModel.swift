import Foundation

// MARK: - 容器家族(p2-sensors/07,ADR-0004 SensorProvider 接缝)

// 数据路 = docker.sock 上的手写 HTTP 单发(docs/probes/07 四坑实证:Host 须
// localhost、Connection: close 必带、docker 29.8.2 对 1.0 也回 chunked 且须
// 字节级去块、CRLF 聚字形簇)。OS 调用(socket)在 Live,HTTP 解析与 JSON
// 折算全在本文件——探针踩掉的坑全部进合成单测。

// MARK: - Unix socket 上的 HTTP 响应解析(纯逻辑)

/// 一条 HTTP/1.1 响应的解析产物(字节级;不聚字符串,块边界切多字节 UTF-8
/// 不坏——探针坑③)。
public struct UnixHTTPResponse: Equatable, Sendable {
    public let status: Int
    /// 头区小写全文(判 chunked 用)。
    public let headerText: String
    /// 去块后的响应体。
    public let body: [UInt8]

    /// 解析:找 CRLFCRLF 分界(字节级)→ 状态行取码 → chunked 则去块。
    /// 解不出(残包/非 HTTP)= nil,调用方安静当读失败。
    public static func parse(_ raw: [UInt8]) -> UnixHTTPResponse? {
        guard let headerEnd = firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A], in: raw) else {
            return nil
        }
        let headerBytes = Array(raw[0 ..< headerEnd])
        let header = String(decoding: headerBytes, as: UTF8.self)
        // 状态行切分不按 "\n" 找(CRLF 在 Swift 聚成单字形簇,firstIndex 恒 nil
        // ——探针坑④):直接在字节流里找首个 LF。
        let statusLineBytes = headerBytes.prefix { $0 != 0x0A }
        let statusLine = String(decoding: statusLineBytes, as: UTF8.self)
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]) else { return nil }

        var body = Array(raw[(headerEnd + 4)...])
        if header.lowercased().contains("transfer-encoding: chunked") {
            body = dechunk(body)
        }
        return UnixHTTPResponse(status: status, headerText: header.lowercased(), body: body)
    }

    /// chunked 去块(字节级,探针坑③):块大小行是十六进制**字节数**,块体原样
    /// 搬运——多字节 UTF-8 跨块边界不坏。0 块 = 结束;解不出块大小行 = 停在
    /// 已收部分(防御,不抛)。
    public static func dechunk(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            guard let lineEnd = firstRange(of: [0x0D, 0x0A], in: input, from: index) else { break }
            let sizeLine = String(decoding: input[index ..< (index + lineEnd)], as: UTF8.self)
            guard let size = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            index += lineEnd + 2
            if size == 0 {
                break
            }
            let end = min(index + size, input.count)
            out.append(contentsOf: input[index ..< end])
            index = end + 2 // 跳过块尾 CRLF
            if index > input.count {
                break
            }
        }
        return out
    }

    static func firstRange(of needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        guard hay.count - from >= needle.count else { return nil }
        for i in from ... (hay.count - needle.count) where Array(hay[i ..< i + needle.count]) == needle {
            return i - from
        }
        return nil
    }
}

// MARK: - 容器读数(纯值)

/// 一台容器的展示行(列表 + stats 合一)。
public struct ContainerRow: Equatable, Identifiable, Sendable {
    public let id: String
    /// 首名去掉前导 `/`(docker Names 惯例 `[/redis]`)。
    public let name: String
    /// docker State 原样(running / exited / paused / created / dead)。
    public let state: String
    public let image: String
    /// 单发 stats 折算的 CPU%(docker 口径:可超 100 = 多核满载;读不到 = nil)。
    public let cpuPercent: Double?
    /// 内存用字节数(读不到 = nil)。
    public let memoryBytes: UInt64?

    public init(
        id: String,
        name: String,
        state: String,
        image: String,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.image = image
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    /// "运行中"的唯一判定(p2-review/03 收口:此前 Live 源 stats 门与卡片状态点 /
    /// 计数三处各比一次字符串)。只认 docker `running`;paused 进程冻结、不出 stats。
    public var isRunning: Bool {
        state == "running"
    }
}

/// 一轮容器读数:引擎可达性 + 容器表。socket 缺席(OrbStack 未跑)=
/// `engineReachable = false` 的空表,不重试风暴由 cadence/门控保证(30s 一发)。
public struct ContainersReading: Equatable, Sendable {
    public let engineReachable: Bool
    /// 行序是读数的不变量(构造即排好):运行中置顶,组内按名称(自然序、不分大小写),
    /// 同名再按 id 定序。凭什么在这里排:Live 源 stats 并行单发、按 TaskGroup 完成序
    /// 收集,不排则每轮行序乱跳(p2-review/03)。
    public let containers: [ContainerRow]

    public init(engineReachable: Bool, containers: [ContainerRow]) {
        self.engineReachable = engineReachable
        self.containers = containers.sorted(by: Self.displayOrder)
    }

    private static func displayOrder(_ lhs: ContainerRow, _ rhs: ContainerRow) -> Bool {
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning
        }
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }
}

// MARK: - JSON 折算(纯逻辑,容错解析)

/// docker `/containers/json?all=1` 响应 → 容器行(无 stats)。字段缺席容错:
/// Id/Names 缺 → 跳过该条;State/Image 缺 → "?"(列表有形比崩了好)。
public enum ContainerListPayload {
    public static func parse(_ body: [UInt8]) -> [ContainerRow]? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body)) as? [[String: Any]] else {
            return nil
        }
        return json.compactMap { entry in
            guard let id = entry["Id"] as? String else { return nil }
            let names = (entry["Names"] as? [String]) ?? []
            let rawName = names.first ?? id.prefix(12).description
            let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
            return ContainerRow(
                id: id,
                name: name,
                state: entry["State"] as? String ?? "?",
                image: entry["Image"] as? String ?? "?",
                cpuPercent: nil,
                memoryBytes: nil
            )
        }
    }
}

/// docker `/containers/{id}/stats?stream=false` 响应 → (CPU%, 内存字节)。
/// CPU% = 单发口径(响应里带 precpu_stats,docker 服务端已采好差分基线):
/// (cpu.total − precpu.total) ÷ (system − presystem) × onlineCPUs × 100;
/// CPU 四字段任一缺失 = 读不到、Δsystem ≤ 0 = docker 侧首读无基线——两者都没有
/// 差分,CPU% 为 nil 占位(CODING_STANDARDS 差分三防御,p2-review/01;原口径照搬
/// docker stats 出 0%)。用量负差(计数器回绕)仍钳 0%:有差分、口径钳位。
public enum ContainerStatsPayload {
    public static func parse(_ body: [UInt8]) -> (cpuPercent: Double?, memoryBytes: UInt64?)? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            return nil
        }
        let cpu = json["cpu_stats"] as? [String: Any] ?? [:]
        let precpu = json["precpu_stats"] as? [String: Any] ?? [:]
        let memory = json["memory_stats"] as? [String: Any] ?? [:]

        let total = nested(cpu, "cpu_usage", "total_usage")
        let preTotal = nested(precpu, "cpu_usage", "total_usage")
        let system = (cpu["system_cpu_usage"] as? NSNumber)?.uint64Value
        let preSystem = (precpu["system_cpu_usage"] as? NSNumber)?.uint64Value
        let onlineCPUs = (cpu["online_cpus"] as? NSNumber)?.intValue
            ?? nested(precpu, "cpu_usage", "percpu_usage", asCount: true)

        var cpuPercent: Double?
        if let total, let preTotal, let system, let preSystem {
            // 计数器回绕(precpu > cpu)按 0%(docker stats 同款安静口径),
            // 不输出负百分比——2026-10-23 审计⑤。
            let usageDelta = max(0, Double(total) - Double(preTotal))
            let systemDelta = Double(system) - Double(preSystem)
            if systemDelta > 0 {
                cpuPercent = usageDelta / systemDelta * Double(max(onlineCPUs ?? 1, 1)) * 100
            }
        }
        // 内存读不到 = nil(与 ContainerRow.memoryBytes 文档一致,不折叠成 0)。
        let memoryBytes = (memory["usage"] as? NSNumber)?.uint64Value
        return (cpuPercent, memoryBytes)
    }

    private static func nested(_ dict: [String: Any], _ key: String, _ inner: String, asCount: Bool = false) -> Int? {
        guard let innerDict = dict[key] as? [String: Any] else { return nil }
        if asCount {
            return ((innerDict[inner] as? [Any])?.count)
        }
        return (innerDict[inner] as? NSNumber)?.intValue
    }
}

// MARK: - 容器源协议(编译期测试接缝,ADR-0003 澄清条款同款)

/// 容器源(ADR-0004 接缝):产品运行期唯一真实现 = app 的 Live 适配器
/// (docker.sock HTTP 单发),测试注入假源;缝上全部纯逻辑(本文件的解析折算)。
public protocol ContainerSource: Sendable {
    /// 引擎可达性 + 容器行(含每容器 stats 并行单发折算)。socket 缺席 =
    /// engineReachable false 空表;引擎在但列表失败 = nil(读失败,不动 lastGood)。
    func read() async -> ContainersReading?
}
