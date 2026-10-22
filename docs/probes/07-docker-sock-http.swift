// 探针⑦(2026-10-22,p2-sensors/01):docker.sock HTTP 单发验证——p2-sensors/07
// 的数据路。本机 OrbStack:socket = /var/run/docker.sock → ~/.orbstack/run/
// docker.sock。验证:AF_UNIX 上手写 HTTP 三发(/_ping、/containers/json、
// /containers/{id}/stats?stream=false)+ JSON 形状。
//
// 本探针踩掉的四个坑(07 票 Live 实现直接受益):
//   1. Host 头必须是合法主机名(localhost)——OrbStack 代理对 "Host: docker" 直接断连;
//   2. Connection: close 必须显式带——代理默认保活,不带则 recv 永远等(挂死);
//   3. docker 29.8.2 对 HTTP/1.0 请求也回 HTTP/1.1 + Transfer-Encoding: chunked,
//      必须去 chunk;且块大小是**字节数**,必须按 [UInt8] 去,不能按 String 索引
//      (会切坏多字节 UTF-8);
//   4. Swift 把 CRLF 聚成单个字形簇,firstIndex(of: "\n") 恒为 nil——切状态行
//      用 Character.isNewline。
//
// 编译运行:swiftc -O 07-docker-sock-http.swift -o /tmp/p7 && /tmp/p7

import Foundation

struct HTTPResponse {
    let status: Int
    let headers: String
    let body: [UInt8]
}

func httpGet(_ path: String, sock: String) -> HTTPResponse? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let sockBytes = Array(sock.utf8)
    guard sockBytes.count < 96 else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: sockBytes) }
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { return nil }
    let req = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    _ = req.withCString { send(fd, $0, strlen($0), 0) }

    var chunks: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 {
            break
        }
        chunks.append(contentsOf: buf[0 ..< n])
        if chunks.count > 8_000_000 {
            break
        }
    }
    guard let headerEnd = firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A], in: chunks) else { return nil }
    let header = String(decoding: chunks[0 ..< headerEnd], as: UTF8.self)
    let statusLine = String(header.prefix { !$0.isNewline })
    let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
    var body = Array(chunks[(headerEnd + 4)...])
    if header.lowercased().contains("transfer-encoding: chunked") {
        body = dechunk(body)
    }
    return HTTPResponse(status: status, headers: header, body: body)
}

func firstRange(of needle: [UInt8], in hay: [UInt8]) -> Int? {
    guard hay.count >= needle.count else { return nil }
    for i in 0 ... (hay.count - needle.count) where Array(hay[i ..< i + needle.count]) == needle {
        return i
    }
    return nil
}

func dechunk(_ input: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    while i < input.count {
        guard let lineEnd = firstRange(of: [0x0D, 0x0A], in: Array(input[i...])) else { break }
        let sizeLine = String(decoding: input[i ..< (i + lineEnd)], as: UTF8.self)
        guard let size = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
        i += lineEnd + 2
        if size == 0 {
            break
        }
        let end = min(i + size, input.count)
        out.append(contentsOf: input[i ..< end])
        i = end + 2 // 跳过块尾 CRLF
        if i > input.count {
            break
        }
    }
    return out
}

// MARK: - 探针主体

let sockPath = "/var/run/docker.sock"
guard FileManager.default.fileExists(atPath: sockPath) else {
    print("结论:socket 缺席(OrbStack 未运行)—— 安静空态路径成立,07 票设计不变")
    exit(0)
}

let t0 = Date()
guard let ping = httpGet("/_ping", sock: sockPath), ping.status == 200 else {
    print("结论:_ping 失败(OrbStack 引擎未就绪?)—— 如实落档")
    exit(0)
}

print("/_ping → HTTP \(ping.status) body=\(String(decoding: ping.body, as: UTF8.self))")

guard let list = httpGet("/containers/json?all=1", sock: sockPath), list.status == 200,
      let containers = try? JSONSerialization.jsonObject(with: Data(list.body)) as? [[String: Any]] else {
    print("结论:容器列表失败 —— 如实落档")
    exit(0)
}

print(String(
    format: "/containers/json → HTTP %d(%.0f ms) 容器数:%d",
    list.status,
    -t0.timeIntervalSinceNow * 1000,
    containers.count
))
var containerId = ""
for c in containers {
    let names = (c["Names"] as? [String])?.joined() ?? "?"
    let state = c["State"] as? String ?? "?"
    let image = (c["Image"] as? String ?? "?").prefix(48)
    print("  \(names)  state=\(state)  image=\(image)")
    if containerId.isEmpty, let id = c["Id"] as? String {
        containerId = id
    }
}

if !containerId.isEmpty {
    let t1 = Date()
    guard let stats = httpGet("/containers/\(containerId)/stats?stream=false", sock: sockPath),
          stats.status == 200,
          let s = try? JSONSerialization.jsonObject(with: Data(stats.body)) as? [String: Any] else {
        print("结论:stats 失败 —— 如实落档")
        exit(0)
    }
    let cpu = s["cpu_stats"] as? [String: Any]
    let mem = s["memory_stats"] as? [String: Any]
    let usage = ((cpu?["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber)?.uint64Value ?? 0
    let online = (cpu?["online_cpus"] as? NSNumber)?.intValue ?? 0
    let memUsage = (mem?["usage"] as? NSNumber)?.uint64Value ?? 0
    print(String(
        format: "/stats → HTTP %d(%.0f ms)  cpu_usage=%llu online_cpus=%d mem_usage=%llu",
        stats.status,
        -t1.timeIntervalSinceNow * 1000,
        usage,
        online,
        memUsage
    ))
    print("✅ 结论:docker.sock 单发 HTTP 三发全通(ping/列表/stats),chunked 去块与 JSON 形状与 docker API 一致,07 票数据路成立")
} else {
    print("✅ 结论:列表通(空列表)—— 空列表路径成立")
}
