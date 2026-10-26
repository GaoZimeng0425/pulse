// 探针 09 宿主 app —— 按命令行参数分派:
//   无参/register:SMAppService.daemon register(),结果落文件后退出(首次注册路径)
//   status:只查状态(验证 app 重签重装后注册是否仍在)
//   unregister:注销(复原路径)
// 无 UI(LSUIElement):open 启动 → didFinishLaunching → 写结果 → terminate。
// open 传参:open /Applications/PulseProbe.app --args <mode>
import AppKit
import ServiceManagement

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let plistName = "com.pulse.probe.daemon.plist"
    let resultPath = "/tmp/pulse-probe-register-result.txt"
    let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "register"

    func applicationDidFinishLaunching(_ note: Notification) {
        var lines = ["mode: \(mode)"]
        let sm = SMAppService.daemon(plistName: plistName)
        lines.append("status before: \(describe(sm.status))")
        switch mode {
        case "status":
            break
        case "unregister":
            do {
                try sm.unregister()
                lines.append("unregister: OK")
            } catch {
                lines.append("unregister: FAILED — \(error)")
            }
        default:
            do {
                try sm.register()
                lines.append("register: OK")
            } catch {
                lines.append("register: FAILED — \(error)")
            }
        }
        lines.append("status after: \(describe(sm.status))")
        try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
