import Foundation
import PulseCore

// MARK: - NemoNotch toast 发送缝(spec 六缝同款:薄适配器,缝上无业务逻辑)

//
// 契约:每次发送前重读 `~/.NemoNotch/hook-port`(缺失回落 45831)与
// `hook-token`(整文件为令牌;读不到静默跳过本次)。连接被拒/超时 → 重读端口
// 再试一次;仍失败或拿到 4xx → 记日志后放弃。任何失败都不影响宿主主流程
// (发送一律 async,调用方 fire-and-forget)——NemoNotch 未运行是常态,不是错误。
//
// 端点发现拆成吃目录 URL 的纯函数(单测注入临时目录);HTTP 走 URLSession
// 瞬时会话、3 秒请求超时。回路地址不受 ATS 限制,无需 Info.plist 例外。

/// 发送缝:AlertCenter 只认此协议;单测注入假 sender 记录调用。
protocol NemoNotchToastSending: Sendable {
    /// 发一条 toast(fire-and-forget:实现保证不抛、不阻塞调用方)。
    func send(_ payload: NemoNotchToastPayload) async
}

/// Darwin 薄适配器(与 LiveAlertNotificationSender 同一角色)。
struct LiveNemoNotchToastSender: NemoNotchToastSending {
    /// 端点三件套:NemoNotch 契约的运行时发现结果。
    struct Endpoint {
        let port: Int
        /// 令牌;nil = 文件缺失,契约规定静默跳过。
        let token: String?
    }

    /// 端口文件缺失时的契约回落值。
    static let fallbackPort = 45831
    /// 令牌缺失/连接失败时的请求超时(秒)——发不出去就放弃,不拖主流程。
    static let requestTimeout: TimeInterval = 3

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        session = URLSession(configuration: configuration)
    }

    func send(_ payload: NemoNotchToastPayload) async {
        // 令牌缺失 → 本次静默跳过(契约第 2 节;NemoNotch 未装/未跑是常态)。
        var endpoint = Self.readEndpoint()
        guard let token = endpoint.token else { return }
        if await post(payload, endpoint: endpoint, token: token) {
            return
        }
        // 连接层失败才重读端点再试一次(端口可能刚因占用回落而变化);4xx 已在
        // post 内记日志并返回 true,不会走到这里二次重试(契约:载荷错误不要原样重试)。
        endpoint = Self.readEndpoint()
        if let token = endpoint.token, await post(payload, endpoint: endpoint, token: token) {
            return
        }
        LogService.info("NemoNotch toast 未送达(重试一次后放弃)", category: "Alert")
    }

    // MARK: - 端点发现(纯函数,单测注入目录)

    /// 读端口与令牌文件。端口文件缺失/非数字 → 回落 45831;令牌整文件读入后
    /// 去首尾空白(等价契约 shell 示例的 `$(cat ...)`,HTTP 头不容换行)。
    static func readEndpoint(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".NemoNotch", isDirectory: true)) -> Endpoint {
        let portText = (try? String(contentsOf: directory.appendingPathComponent("hook-port"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = portText.flatMap { Int($0) } ?? fallbackPort
        let token = (try? String(contentsOf: directory.appendingPathComponent("hook-token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyToken = (token?.isEmpty == false) ? token : nil
        return Endpoint(port: port, token: nonEmptyToken)
    }

    // MARK: - HTTP(连接层失败返回 false 供重试;4xx 记日志后返回 true = 不重试)

    private func post(_ payload: NemoNotchToastPayload, endpoint: Endpoint, token: String) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/v1/toast")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-NemoNotch-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 请求体封套在 PulseCore(契约键名单测钉死);编码失败 = 本地 bug,不重试。
        guard let data = try? JSONEncoder().encode(payload.envelope) else { return true }
        request.httpBody = data

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                // 400 = 载荷不合约(本地 bug 信号,记载荷标题排查);401 = 令牌失配
                // (不记令牌本身)。两者都不重试。
                LogService.info(
                    "NemoNotch toast 被拒(HTTP \(http.statusCode),title=\(payload.title))",
                    category: "Alert"
                )
            }
            return true
        } catch {
            // 连接被拒/超时:NemoNotch 未运行或端口变了 → 返回 false 交上层重读端口。
            return false
        }
    }
}

// MARK: - 惰性替身(预览 / 单测缺省)

/// 什么都不发的假 sender(预览与 Inert 装配缺省;断言型替身在各自测试文件里)。
struct InertNemoNotchToastSender: NemoNotchToastSending {
    func send(_ payload: NemoNotchToastPayload) async {}
}
