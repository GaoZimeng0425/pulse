// pulse-helper —— Pulse 特权助手 daemon(p3-root-mcp/03,探针 09 安装组合)。
// root 运行:60s 循环 `powermetrics -n 1 --show-process-energy` 单发采样,
// 解析 per-process Energy Impact 缓存最新一轮;app 经 XPC 拉取(mach service
// = launchd label)。app 不在跑 = 没人拉 = 数据自然丢弃(与历史库空段纪律
// 同构)。对端校验:连接方必须与本 daemon 同证书签名(anchor SHA-256),
// Procexp PeerValidation 路数——无 Team ID 的自签身份用证书指纹表达。
import CryptoKit
import Foundation
import PulseHelperCore
import ServiceManagement

let label = "com.gaozimeng.pulse.helper"

// MARK: - XPC 协议(on-wire 只用 NSArray/NSDictionary/NSString/NSNumber,

// Procexp 踩坑记档:.privileged 传输只序列化这四类)

@objc(EnergyHelperProtocol)
protocol EnergyHelperProtocol {
    /// 最新一轮采样:[[name, pid, impact]] 的字典数组;从未采到过返回空数组。
    /// epochMs = 采样完成时刻(调用方判断数据年龄)。
    func latestSamples(reply: @escaping (_ samples: [[String: Any]], _ epochMs: NSNumber) -> Void)
}

// MARK: - powermetrics 解析(固定 flag 集 → 固定列形;单测钉口径)

// MARK: - 对端校验(证书 anchor SHA-256;Procexp PeerValidation 路数)

enum PeerValidator {
    /// 连接方(app)与本 daemon 是否**同一签名证书**:比对双侧代码签名的
    /// 叶证书 SHA-256(证书链 leaf)。不走"对端满足我的 designated
    /// requirement"——DR 含 identifier(本 daemon = pulse-helper),app 的
    /// identifier 不同必然被拒(2026-10-26 首装机实踩:校验永拒 → 数据
    /// 断流)。同证书 = 探针 09 组合的双端同身份签名;拿不到签名信息 =
    /// 拒(fail-closed)。
    static func connectionIsTrusted(_ connection: NSXPCConnection) -> Bool {
        // pid → 可执行路径 → 静态码:SecCodeCopySigningInformation 只收
        // SecStaticCode,而 pid 侧没有公开的 SecCode 转换,统一走路径创建。
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(connection.processIdentifier), &path, UInt32(path.count)) > 0 else { return false }
        let executablePath = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard let own = Self.leafCertificateSHA256(ofExecutableAt: ownPath),
              let peer = Self.leafCertificateSHA256(ofExecutableAt: executablePath)
        else { return false }
        return own == peer
    }

    /// 可执行文件的叶证书(签名链第 0 张)DER 数据 SHA-256。
    private static func leafCertificateSHA256(ofExecutableAt url: URL) -> Data? {
        var staticRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticRef) == errSecSuccess,
              let code = staticRef
        else { return nil }
        var infoDict: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &infoDict) == errSecSuccess,
              let info = infoDict as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Data(SHA256.hash(data: der))
    }
}

// MARK: - 服务

final class HelperService: NSObject, EnergyHelperProtocol, NSXPCListenerDelegate {
    private let collector = EnergyCollector()
    private var timer: Timer?

    func latestSamples(
        reply: @escaping (_ samples: [[String: Any]], _ epochMs: NSNumber) -> Void
    ) {
        let payload: [[String: Any]] = collector.samples.map { sample in
            [
                "pid": NSNumber(value: sample.pid),
                "name": sample.name as NSString,
                "impact": NSNumber(value: sample.impact),
            ]
        }
        reply(payload, NSNumber(value: Int(collector.collectedAt.timeIntervalSince1970 * 1000)))
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let trusted = PeerValidator.connectionIsTrusted(newConnection)
        PowermetricsParser.debugLog("XPC 连接 pid=\(newConnection.processIdentifier) 判定=\(trusted)")
        guard trusted else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func run() {
        PowermetricsParser.debugLog("启动:首轮采集开始")
        collector.collect() // 首轮立即(注册批准后 RunAtLoad 拉起即有数)
        PowermetricsParser.debugLog("启动:首轮采集完成,\(collector.samples.count) 行")
        let listener = NSXPCListener(machServiceName: label)
        listener.delegate = self
        listener.resume()
        let queue = DispatchQueue(label: "pulse-helper.collect")
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 60, repeating: 60)
        source.setEventHandler { [collector] in collector.collect() }
        source.resume()
        dispatchMain()
    }
}

HelperService().run()
