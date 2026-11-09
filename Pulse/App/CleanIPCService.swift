import AppKit
import Foundation
import Network
import PulseCore

// MARK: - mcp-clean/01:app 内 127.0.0.1 极简 HTTP JSON 服务(只服务 pulse-mcp)

//
// 安全边界:仅回环监听 + X-Pulse-Token 校验(令牌在 0600 端点文件里,同用户
// 可读 = 同信任域);真正的删除闸是 app 里那张用户确认单,这里不做权限哲学。
// 并发纪律:所有连接 I/O 收敛在 `queue` 上(接收回调和写回同队);业务计算
// 跳 @MainActor 桥接器。@unchecked Sendable + nonisolated(unsafe) 捕获是
// 刻意的——NWConnection 非 Sendable,而它的全部触点已被队列约束。
// HTTP 实现刻意最小(解析是纯函数,单测不碰 socket);不支持 keep-alive,
// 响应即关连接。

final class CleanIPCService: @unchecked Sendable {
    /// 解析结果(纯数据,测试直接喂字节)。
    struct ParsedRequest: Equatable {
        let method: String
        let path: String
        let token: String?
        let body: Data
    }

    private let queue = DispatchQueue(label: "pulse.mcp-clean.ipc")
    private var listener: NWListener?
    private let token: String
    private let endpointURL: URL
    private let handleCleanable: @MainActor () async -> McpCleanableListResponse
    private let handleClean: @MainActor ([String]) async -> McpCleanRunResponse
    /// 请求体上限(路径列表撑不到这量级;超了按恶意断开)。internal:解析测试要引用。
    static let maxBodyBytes = 1_000_000

    init?(
        directory: URL,
        handleCleanable: @escaping @MainActor () async -> McpCleanableListResponse,
        handleClean: @escaping @MainActor ([String]) async -> McpCleanRunResponse
    ) {
        self.handleCleanable = handleCleanable
        self.handleClean = handleClean
        endpointURL = McpCleanEndpoint.url(directory: directory)
        token = Self.makeToken()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
    }

    deinit {
        listener?.cancel()
    }

    func start() {
        guard let listener else { return }
        let token = token
        let endpointURL = endpointURL
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, token: token)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port else { return }
                let endpoint = McpCleanEndpoint(
                    port: port.rawValue,
                    token: token,
                    pid: ProcessInfo.processInfo.processIdentifier
                )
                do {
                    try endpoint.save(to: endpointURL)
                    LogService.info("mcp-clean IPC 就绪:127.0.0.1:\(port)", category: "McpClean")
                } catch {
                    LogService.error("mcp-clean 端点文件写入失败,AI 清理不可用:\(error)", category: "McpClean")
                }
            case let .failed(error):
                LogService.error("mcp-clean IPC 监听失败:\(error)", category: "McpClean")
                stop()
            default:
                break
            }
        }
        listener.start(queue: queue)

        // 退出清端点文件(死文件会让 MCP 端多一次连接失败才知道 app 不在;顺手清干净)。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [endpointURL] _ in
            try? FileManager.default.removeItem(at: endpointURL)
        }
    }

    func stop() {
        let listener = listener
        queue.async {
            listener?.cancel()
        }
        self.listener = nil
        try? FileManager.default.removeItem(at: endpointURL)
    }

    // MARK: 连接处理(全在 queue 上)

    private func handle(connection: NWConnection, token: String) {
        connection.start(queue: queue)
        receiveLoop(connection: connection, token: token, buffer: Data())
    }

    private func receiveLoop(connection: NWConnection, token: String, buffer: Data) {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if error != nil {
                    connection.cancel()
                    return
                }
                // 头未齐继续收;头齐且 body 到位(或无 body)→ 处理。
                if let request = Self.parseRequest(buffer) {
                    route(request: request, expectedToken: token, connection: connection)
                } else if isComplete {
                    // 头都没收齐就断——直接关。
                    connection.cancel()
                } else if buffer.count > Self.maxBodyBytes + 8192 {
                    connection.cancel()
                } else {
                    receiveLoop(connection: connection, token: token, buffer: buffer)
                }
            }
    }

    private func route(
        request: ParsedRequest,
        expectedToken: String,
        connection: NWConnection
    ) {
        guard request.token == expectedToken else {
            respond(connection: connection, status: 403, json: Self.errorJSON("令牌不符"))
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(connection: connection, status: 200, json: Self.okJSON)
        case ("GET", "/cleanable"):
            nonisolated(unsafe) let connection = connection
            let service = self
            Task { @MainActor in
                let list = await service.handleCleanable()
                let json = Self.encode(list) ?? Self.errorJSON("编码失败")
                service.respond(connection: connection, status: 200, json: json)
            }
        case ("POST", "/clean"):
            guard let decoded = try? JSONDecoder().decode(McpCleanRequest.self, from: request.body) else {
                respond(connection: connection, status: 400, json: Self.errorJSON("请求体不是合法 JSON(需要 {\"paths\":[…]})"))
                return
            }
            nonisolated(unsafe) let connection = connection
            let service = self
            Task { @MainActor in
                let result = await service.handleClean(decoded.paths)
                let json = Self.encode(result) ?? Self.errorJSON("编码失败")
                service.respond(connection: connection, status: 200, json: json)
            }
        default:
            respond(connection: connection, status: 404, json: Self.errorJSON("未知路径"))
        }
    }

    /// 写回:跳回专属队列再发(与接收同队,免数据竞争),发完即关。
    private func respond(connection: NWConnection, status: Int, json: Data) {
        nonisolated(unsafe) let connection = connection
        queue.async {
            Self.respond(connection: connection, status: status, json: json)
        }
    }

    // MARK: 纯函数(解析/序列化,单测直喂)

    /// 从原始字节解出头与方法/令牌/body。头未收齐或 Content-Length 未满足 → nil
    /// (调用方继续收)。头部上限 8KB,请求体上限 1MB。
    static func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex ..< headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8),
              headerText.utf8.count <= 8192,
              let firstLine = headerText.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        var token: String?
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            } else if name == "x-pulse-token" {
                token = value
            }
        }
        guard contentLength >= 0, contentLength <= maxBodyBytes else { return nil }
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart ..< data.index(bodyStart, offsetBy: contentLength))
        return ParsedRequest(method: method, path: path, token: token, body: body)
    }

    static func respond(connection: NWConnection, status: Int, json: Data) {
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(json.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(json)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func encode(_ value: some Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static let okJSON = Data(#"{"ok":true}"#.utf8)

    private static func errorJSON(_ message: String) -> Data {
        let obj: [String: String] = ["error": message]
        return (try? JSONEncoder().encode(obj)) ?? Data("{}".utf8)
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        default: "Error"
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            // 系统熵失效是极端场景;退双 UUID 拼接(仍 256 位级别),绝不静默空令牌。
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
