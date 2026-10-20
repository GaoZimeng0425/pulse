import AppKit
import PulseCore

/// 设置窗窗口修饰(参考 NemoNotch 同名 Helpers,实测结论原样保留):
/// SwiftUI Settings 场景的窗口默认**不可缩放**,双栏形态需要可缩放;
/// 而 `NavigationSplitView` 装侧栏工具栏触发的异步窗口重配置会重建
/// styleMask 并把刚插上的 .resizable 剥掉——重配置尘埃落定(450ms)后
/// 补插一次。幂等:已可缩放则不动。
enum SettingsWindowChrome {
    /// SwiftUI Settings 场景窗口的 frame autosave 名(实测常量,由它写入
    /// UserDefaults)。用它认窗口是确定性的:按标题匹配在真机上会扑空
    /// (title 在 onAppear 时未必就位)。
    private static let settingsAutosaveName = "com_apple_SwiftUI_Settings_window"

    @MainActor static func install(retries: Int = 8) {
        guard let window = NSApp.windows.first(where: {
            $0.frameAutosaveName == settingsAutosaveName
        }) else {
            // 场景的窗口元数据晚于内容出现:此刻找不到就短暂重试。
            guard retries > 0 else {
                LogService.warn(
                    "设置窗可缩放修补放弃:未找到窗口",
                    category: "Settings"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                install(retries: retries - 1)
            }
            return
        }
        guard !window.styleMask.contains(.resizable) else { return }
        window.styleMask.insert(.resizable)
        LogService.info("设置窗已可缩放", category: "Settings")
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let window, !window.styleMask.contains(.resizable) else { return }
            window.styleMask.insert(.resizable)
            LogService.info("设置窗在工具栏重配置后补插可缩放", category: "Settings")
        }
    }
}
