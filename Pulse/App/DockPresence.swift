import AppKit

/// Dock 图标随主窗口出没(2026-11-05 用户拍板,取代 11-03 的「Dock 常驻」):
/// Info.plist 仍是 LSUIElement(启动无 Dock 图标);主窗口成为 key 时切 `.regular`
/// 现身 Dock,主窗口关闭时切回 `.accessory` 隐去。设置窗不参与——只认主窗口。
@MainActor
enum DockPresence {
    /// 窗口事件 → 目标激活策略;nil = 不动。纯函数,可测。
    enum WindowEvent {
        case becameKey
        case willClose
    }

    static func policy(
        for event: WindowEvent,
        isMainWindow: Bool,
        alphaValue: CGFloat
    ) -> NSApplication.ActivationPolicy? {
        guard isMainWindow else { return nil }
        switch event {
        case .becameKey:
            // 启动即藏的那一帧(LaunchHiddenWindow 置 alpha 0)不算「打开」,否则 Dock 闪一下。
            return alphaValue > 0 ? .regular : nil
        case .willClose:
            return .accessory
        }
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == MainWindowSceneID.value || window.title == "Pulse"
    }

    /// app 拉起时调用一次;观察者随进程常驻。
    static func install() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            // NSWindow 是 @MainActor 类型(Sendable),先取出再进隔离域;Notification 本身不可发送。
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { handle(window, event: .becameKey) }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { handle(window, event: .willClose) }
        }
    }

    private static func handle(_ window: NSWindow, event: WindowEvent) {
        guard let target = policy(for: event, isMainWindow: isMainWindow(window), alphaValue: window.alphaValue),
              NSApp.activationPolicy() != target
        else { return }
        NSApp.setActivationPolicy(target)
        // 切到 .regular 后需再激活一次,菜单栏才换成 Pulse 的菜单、窗口留在前台。
        if target == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        LogService.info("Dock 图标\(target == .regular ? "显示" : "隐藏")", category: "App")
    }
}
