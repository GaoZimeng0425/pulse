import AppKit
import Foundation
import PulseCore

// MARK: - Live 运行中应用采集(p7-cleaner/02)

//
// 通用发现「所属应用在运行就不出现」的输入;判定是纯值,在 PulseCore `GenericDiscovery`。
// 来源 = 系统工作区的应用列表:带应用包的进程全在(界面应用、菜单栏工具、助手),不含
// 命令行进程——CLI 工具的缓存在不在用,归在用保护的进程活动源。
// 同步、只读,主线程调(清理模型读清单时)。本机实测两百来个应用约 2 毫秒,调用侧一秒
// 内的重复读共用一份(`RunningAppsReading`)。
// NSRunningApplication 线程安全(头文件明载;属性原子返回),同 LiveInstalledAppInventory。

enum LiveRunningApps {
    static func collect() -> [RunningAppIdentity] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningAppIdentity(bundleID: app.bundleIdentifier, names: names(of: app))
        }
    }

    /// 应用名的两种写法:界面显示名(可能是本地化名)与应用包文件名去掉 .app。
    /// 缓存目录按哪种起名都有,给全了对得上。
    private static func names(of app: NSRunningApplication) -> [String] {
        var names: [String] = []
        if let localized = app.localizedName {
            names.append(localized)
        }
        if let bundleName = app.bundleURL?.lastPathComponent {
            names.append(bundleName.hasSuffix(".app") ? String(bundleName.dropLast(4)) : bundleName)
        }
        return names
    }
}
