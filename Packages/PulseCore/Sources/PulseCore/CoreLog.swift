import Foundation

// MARK: - 核心层日志出口(arch-review-2026-10-18/05)

/// 核心层的日志级别。
public enum CoreLogLevel: Sendable {
    case info
    case warn
    case error
}

/// 核心层日志出口:PulseCore 不依赖 CocoaLumberjack / AppKit,日志经这里交给宿主——
/// app 启动时 `CoreLog.install` 接到 LogService;未安装(单测、`swift test`)时静默丢弃。
/// 锁保护的微小盒子(核心层日志从多个并发域写入)。
public enum CoreLog {
    public typealias Handler = @Sendable (_ level: CoreLogLevel, _ message: String, _ category: String) -> Void

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: Handler?

        func set(_ handler: Handler?) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
        }

        var current: Handler? {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
    }

    private static let box = Box()

    /// 宿主安装日志去向(app 启动时调一次)。
    public static func install(_ handler: @escaping Handler) {
        box.set(handler)
    }

    public static func info(_ message: String, category: String) {
        box.current?(.info, message, category)
    }

    public static func warn(_ message: String, category: String) {
        box.current?(.warn, message, category)
    }

    public static func error(_ message: String, category: String) {
        box.current?(.error, message, category)
    }
}
