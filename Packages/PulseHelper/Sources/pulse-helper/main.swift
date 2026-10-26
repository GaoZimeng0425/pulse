// pulse-helper —— Pulse 特权助手 daemon(p3-root-mcp/03,探针 09 安装组合)。
// root 运行:60s 循环 `powermetrics -n 1 --show-process-energy` 单发采样,
// 解析 per-process Energy Impact 缓存最新一轮;app 经 XPC 拉取(mach service
// = launchd label)。app 不在跑 = 没人拉 = 数据自然丢弃(与历史库空段纪律
// 同构)。对端校验:连接方必须与本 daemon 同证书签名(anchor SHA-256),
// Procexp PeerValidation 路数——无 Team ID 的自签身份用证书指纹表达。
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
    /// 连接方(app)与本 daemon 是否同一签名体系:对端必须满足本 daemon 的
    /// designated requirement(探针 09 组合 = app 与 helper 同自签身份 → 同 DR)。
    /// 拿不到签名信息 = 拒(fail-closed)。pid 取自 NSXPCConnection.processIdentifier
    /// (auditToken 未向 Swift 桥接)——pid 复用竞态为既知局限,采集只读数据
    /// 面上可接受(Procexp 同路)。
    static func connectionIsTrusted(_ connection: NSXPCConnection) -> Bool {
        var peerCode: SecCode?
        let pid = NSNumber(value: Int(connection.processIdentifier))
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &peerCode) == errSecSuccess,
              let peer = peerCode
        else { return false }
        var selfRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfRef) == errSecSuccess else { return false }
        // 自身的 designated requirement 走静态码 API(公开转换缺失,从自身
        // 可执行路径创建——daemon 由 launchd 按 bundle 内绝对路径拉起,
        // arguments[0] 即真实路径)。
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var ownStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(ownPath as CFURL, SecCSFlags(), &ownStatic) == errSecSuccess,
              let staticCode = ownStatic
        else { return false }
        var requirementRef: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirementRef) == errSecSuccess,
              let requirement = requirementRef
        else { return false }
        return SecCodeCheckValidity(peer, SecCSFlags(), requirement) == errSecSuccess
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
        guard PeerValidator.connectionIsTrusted(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: EnergyHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func run() {
        collector.collect() // 首轮立即(注册批准后 RunAtLoad 拉起即有数)
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
