import Foundation
import ServiceManagement

// MARK: - 特权助手 XPC client(p3-root-mcp/03)

/// 与 pulse-helper 同形的协议(on-wire 只 NSArray/NSDictionary/NSString/NSNumber,
/// Procexp 踩坑记档)。双端各自声明(独立可执行不共享源),签名不一致 =
/// 远端无法解析,连接报错——不会静默错位。
@objc(EnergyHelperClientProtocol)
protocol EnergyHelperClientProtocol {
    func latestSamples(reply: @escaping (_ samples: [[String: Any]], _ epochMs: NSNumber) -> Void)
}

/// 特权助手拉模式 client:每分钟一次短连接(连接开销可忽略,helper 重启自愈)。
/// 连接要求 helper 满足本 app 的 designated requirement(运行时从自身签名取,
/// 自签身份无 Team ID,以证书指纹 DR 表达——与 helper 侧 PeerValidator 对称,
/// 双向校验)。@unchecked Sendable:无共享可变状态(每次调用独立短连接,
/// 全局部变量),跨 actor 调用安全。
final class EnergyHelperClient: @unchecked Sendable {
    private let machServiceName = "com.gaozimeng.pulse.helper"

    /// 拉最新一轮采样;失败(未装 / 未批准 / helper 未跑 / 校验拒)抛错。
    func fetchLatest() async throws -> (samples: [(pid: Int, name: String, impact: Double)], collectedAt: Date) {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        if let requirement = Self.ownDesignatedRequirementString() {
            connection.setCodeSigningRequirement(requirement)
        } else {
            // 拿不到自身 DR = 无法建立信任锚,fail-closed(与 helper 侧同纪律)。
            throw HelperClientError.validationUnavailable
        }
        connection.remoteObjectInterface = NSXPCInterface(with: EnergyHelperClientProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? any EnergyHelperClientProtocol
        else {
            throw HelperClientError.connectionFailed
        }
        // Swift 6 Sendable:字典数组非 Sendable,在 XPC 回调线程当场折成
        // 全 Sendable 行再跨 continuation 边界(残缺行丢——helper 侧只产
        // 三键齐全的字典,防御性 compactMap)。
        return try await withCheckedThrowingContinuation { continuation in
            proxy.latestSamples { samples, epochMs in
                let rows: [(pid: Int, name: String, impact: Double)] = samples.compactMap { dict in
                    guard let pid = (dict["pid"] as? NSNumber)?.intValue,
                          let name = dict["name"] as? String,
                          let impact = (dict["impact"] as? NSNumber)?.doubleValue
                    else { return nil }
                    return (pid, name, impact)
                }
                continuation.resume(
                    returning: (rows, Date(timeIntervalSince1970: epochMs.doubleValue / 1000))
                )
            }
        }
    }

    /// 自身 designated requirement 的字符串形(setCodeSigningRequirement 入参);
    /// 取不到返回 nil(fail-closed 由调用方处理)。
    private static func ownDesignatedRequirementString() -> String? {
        var selfRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfRef) == errSecSuccess, let own = selfRef else { return nil }
        let ownPath = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/Pulse")
        var staticRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(ownPath as CFURL, SecCSFlags(), &staticRef) == errSecSuccess,
              let staticCode = staticRef
        else { return nil }
        var requirementRef: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirementRef) == errSecSuccess,
              let requirement = requirementRef
        else { return nil }
        var requirementString: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &requirementString) == errSecSuccess,
              let string = requirementString as String?
        else { return nil }
        return string
    }
}

enum HelperClientError: Error {
    case validationUnavailable
    case connectionFailed
}
