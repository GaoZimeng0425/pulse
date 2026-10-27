import Foundation

// MARK: - 特权助手 XPC client(p3-root-mcp/03)

/// 与 pulse-helper 同形的协议(on-wire 只 NSArray/NSDictionary/NSString/NSNumber,
/// Procexp 踩坑记档)。双端各自声明(独立可执行不共享源),签名不一致 =
/// 远端无法解析,连接报错——不会静默错位。
@objc(EnergyHelperClientProtocol)
protocol EnergyHelperClientProtocol {
    func latestSamples(reply: @escaping (_ samples: [[String: Any]], _ epochMs: NSNumber) -> Void)
}

/// 特权助手拉模式 client:每分钟一次短连接(连接开销可忽略,helper 重启自愈)。
/// **超时必须**(2026-10-26 首装机实踩:helper 校验拒时连接静默断,reply 永不
/// 到达,无超时 = 首次拉取永久挂起、整条轮询死掉)。client→server 校验 v1
/// 不做(记档收窄):server 端 mach service 名由 launchd 命名空间独占且注册
/// 链路(BTM 同源验签)已保证身份;恶意 server 须先 root 劫持 launchd,已出
/// 信任边界。双向校验后续可补。@unchecked Sendable:无共享可变状态(每次
/// 调用独立短连接,全局部变量),跨 actor 调用安全。
final class EnergyHelperClient: @unchecked Sendable {
    private let machServiceName = "com.gaozimeng.pulse.helper"

    typealias Samples = [(pid: Int, name: String, impact: Double)]

    /// 拉最新一轮采样;失败(未装 / 未批准 / helper 未跑 / 5s 超时)抛错,
    /// 调用方按轮重试。
    func fetchLatest() async throws -> (samples: Samples, collectedAt: Date) {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: EnergyHelperClientProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? any EnergyHelperClientProtocol
        else {
            throw HelperClientError.connectionFailed
        }
        // 单 continuation + 锁防双 resume:XPC 应答与超时两路竞速,先到先得;
        // 败者晚到时 continuation 已消费,守卫吞掉。Swift 6 Sendable:字典数组
        // 非 Sendable,在 XPC 回调线程当场折成全 Sendable 行再跨边界(残缺行
        // 丢——helper 侧只产三键齐全的字典,防御性 compactMap)。
        return try await withCheckedThrowingContinuation { continuation in
            let finish = FinishOnce()
            proxy.latestSamples { samples, epochMs in
                let rows: EnergyHelperClient.Samples = samples.compactMap { dict in
                    guard let pid = (dict["pid"] as? NSNumber)?.intValue,
                          let name = dict["name"] as? String,
                          let impact = (dict["impact"] as? NSNumber)?.doubleValue
                    else { return nil }
                    return (pid, name, impact)
                }
                finish.complete(
                    continuation,
                    with: .success((rows, Date(timeIntervalSince1970: epochMs.doubleValue / 1000)))
                )
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(5))
                finish.complete(continuation, with: .failure(HelperClientError.timedOut))
            }
        }
    }
}

/// 双路竞速的单次完成守卫:NSLock + 一次性标记,后到者静默丢弃。
private final class FinishOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func complete(
        _ continuation: CheckedContinuation<(samples: EnergyHelperClient.Samples, collectedAt: Date), Error>,
        with result: Result<(samples: EnergyHelperClient.Samples, collectedAt: Date), Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}

enum HelperClientError: Error {
    case connectionFailed
    case timedOut
}
