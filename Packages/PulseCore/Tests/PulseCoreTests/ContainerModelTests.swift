@testable import PulseCore
import XCTest

/// 接缝:容器家族解析与折算(p2-sensors/07,纯逻辑)。探针⑦踩掉的四个坑
/// (Host/Connection 由 Live 层请求模板负责,CRLF 字形簇与字节级去块在这里):
/// 好测试 = 合成载荷覆盖防御分支,不起 docker、不占真机。
final class ContainerModelTests: XCTestCase {
    // MARK: - HTTP 解析(探针坑③④)

    func testResponseParsingSplitsHeadersAndBody() {
        let raw = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":1}".utf8)
        let response = UnixHTTPResponse.parse(raw)
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(response?.body, Array("{\"ok\":1}".utf8))
    }

    func testChunkedBodyIsDechunkedAtByteLevel() {
        // 探针坑③:块大小是字节数,多字节 UTF-8 可跨块边界——按字节搬运不坏。
        let payload = Array("容器名-🚢-多字节跨块".utf8)
        let mid = payload.count / 2
        var chunked: [UInt8] = []
        chunked.append(contentsOf: Array(String(format: "%x\r\n", mid).utf8))
        chunked.append(contentsOf: payload[0 ..< mid])
        chunked.append(contentsOf: [0x0D, 0x0A])
        chunked.append(contentsOf: Array(String(format: "%x\r\n", payload.count - mid).utf8))
        chunked.append(contentsOf: payload[mid...])
        chunked.append(contentsOf: [0x0D, 0x0A])
        chunked.append(contentsOf: Array("0\r\n\r\n".utf8))
        XCTAssertEqual(UnixHTTPResponse.dechunk(chunked), Array(payload))

        // 完整响应带 chunked 头:解析链路端到端。
        let response = UnixHTTPResponse.parse(
            Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + chunked
        )
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(response?.body, Array(payload))
    }

    func testCRLFClusterDoesNotBreakStatusLine() {
        // 探针坑④:CRLF 在 Swift 聚单字形簇——状态行切分走字节级 LF,不按 "\n" 找。
        let raw = Array("HTTP/1.1 404 not found\r\n\r\n".utf8)
        XCTAssertEqual(UnixHTTPResponse.parse(raw)?.status, 404)
        XCTAssertNil(UnixHTTPResponse.parse(Array("garbage".utf8)))
    }

    // MARK: - 列表 JSON 容错

    func testListParsingStripsLeadingSlashAndToleratesMissingFields() {
        let json = #"""
        [
          {"Id": "abc123", "Names": ["/redis-prod"], "State": "running", "Image": "redis:7"},
          {"Id": "def456", "Names": [], "State": "exited"},
          {"State": "running"}
        ]
        """#
        let rows = ContainerListPayload.parse(Array(json.utf8))
        XCTAssertEqual(rows?.count, 2, "无 Id 条目跳过")
        XCTAssertEqual(rows?[0].name, "redis-prod", "Names 首项去前导斜杠")
        XCTAssertEqual(rows?[1].name, "def456", "无名回落 Id 前 12 位")
        XCTAssertEqual(rows?[1].state, "exited")
        XCTAssertEqual(rows?[1].image, "?", "Image 缺 = ?")
        XCTAssertNil(ContainerListPayload.parse(Array("not json".utf8)))
        XCTAssertEqual(ContainerListPayload.parse(Array("[]".utf8)), [])
    }

    // MARK: - stats 折算(单发差分口径)

    private func statsBody(
        total: UInt64, preTotal: UInt64, system: UInt64, preSystem: UInt64,
        onlineCPUs: Int, memory: UInt64
    ) -> [UInt8] {
        let json = #"""
        {"cpu_stats": {"cpu_usage": {"total_usage": \#(total)}, "system_cpu_usage": \#(system), "online_cpus": \#(onlineCPUs)},
         "precpu_stats": {"cpu_usage": {"total_usage": \#(preTotal)}, "system_cpu_usage": \#(preSystem)},
         "memory_stats": {"usage": \#(memory)}}
        """#
        return Array(json.utf8)
    }

    func testCpuPercentSingleShotDeltaFormula() {
        // docker 单发口径:Δcpu ÷ Δsystem × onlineCPUs × 100(可超 100 = 多核)。
        let body = statsBody(
            total: 2_000_000_000, preTotal: 1_000_000_000,
            system: 10_000_000_000, preSystem: 8_000_000_000,
            onlineCPUs: 4, memory: 512 * 1024 * 1024
        )
        let stats = ContainerStatsPayload.parse(body)
        // Δcpu/Δsystem = 0.5,× 4 核 × 100 = 200(docker 口径:四核各半载 = 200%)。
        XCTAssertEqual(stats?.cpuPercent ?? -1, 200.0, accuracy: 0.001)
        XCTAssertEqual(stats?.memoryBytes, 512 * 1024 * 1024)
    }

    func testZeroOrNegativeSystemDeltaYieldsZeroPercent() {
        // 首读/回绕:Δsystem ≤ 0 → 0%(docker stats 同款安静口径),内存照常。
        let body = statsBody(
            total: 100, preTotal: 50,
            system: 500, preSystem: 500, // Δsystem = 0
            onlineCPUs: 2, memory: 1024
        )
        let stats = ContainerStatsPayload.parse(body)
        XCTAssertEqual(stats?.cpuPercent, 0)
        XCTAssertEqual(stats?.memoryBytes, 1024)
    }

    func testNegativeCpuDeltaClampsToZero() {
        // 计数器回绕(precpu > cpu):按 0% 不出负数(审计⑤)。
        let body = statsBody(
            total: 100, preTotal: 900,
            system: 500, preSystem: 100,
            onlineCPUs: 2, memory: 1024
        )
        let stats = ContainerStatsPayload.parse(body)
        XCTAssertEqual(stats?.cpuPercent, 0)
        XCTAssertEqual(stats?.memoryBytes, 1024)
    }

    func testMissingStatsFieldsDegradeQuietly() {
        let stats = ContainerStatsPayload.parse(Array(#"{"cpu_stats": {}}"#.utf8))
        XCTAssertEqual(stats?.cpuPercent, 0)
        XCTAssertNil(stats?.memoryBytes, "内存读不到 = nil,不折叠成 0(审计⑤)")
        XCTAssertNil(ContainerStatsPayload.parse(Array("garbage".utf8)))
    }
}
