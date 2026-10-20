import AppKit
import CocoaLumberjackSwift
import Foundation
import PulseCore

/// 日志门面(2026-10-16,流程参考 NemoNotch):CocoaLumberjack 双通道——
/// 控制台(桥系统统一日志)+ 文件(`~/.Pulse/logs/`)。用法与 NemoNotch 同形:
/// `LogService.info("…", category: "模块名")`,category 跟模块走便于过滤。
///
/// 移植时保留对方踩坑后沉淀的教训(见其 AGENTS.md Logging 节):
/// ① 文件时间戳必须本地时区——CocoaLumberjack 默认格式化器硬编码 UTC,
///   日志会比崩溃报告 / ps / Console 早 8 小时,排查时极易把"刚写的日志"
///   误读成"进程几小时前就停了";
/// ② 留存要诚实——每日轮转 ≠ N 天留存,1MB 单文件上限先触发;14 个文件
///   给出更宽的实际窗口,需长期审计的东西另落专属文件;
/// ③ 轮询循环只记状态迁移,不记每一跳(对方真实事故:每 2s 一条的轮询日志
///   占到全部日志量 96%,把有用日志全部挤出留存窗口)。
final class LogService {
    /// 日志目录唯一来源(GeneralSettingsView 的"打开日志文件夹"共用)。
    static let logDirectory = NSHomeDirectory() + "/.Pulse/logs"

    nonisolated(unsafe) static let shared = LogService()

    /// 是否运行在 xctest 宿主进程(单元测试托管在 app 内,TEST_HOST 同进程)。
    /// 测试夹具会走真实 AlertCenter 路径发告警,若文件日志照常落
    /// ~/.Pulse/logs,夹具读数(磁盘 19 GiB、负载 80% 等)会混进生产日志,
    /// 与真实"启动"埋点同排——2026-10-19"冷启动磁盘告警 20.4GB"误报即
    /// 源于此(实际磁盘可用 190GB,告警从未在 app 内触发过)。测试进程不装
    /// 文件日志,生产日志只反映真实运行;环境表可注入,判定本身可单测。
    static func isRunningTests(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    private init() {
        DDLog.add(DDOSLogger.sharedInstance)

        guard !Self.isRunningTests() else { return }
        let logDir = LogService.logDirectory

        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        let logFileManager = DDLogFileManagerDefault(logsDirectory: logDir)
        logFileManager.maximumNumberOfLogFiles = 14
        let fileLogger = DDFileLogger(logFileManager: logFileManager)
        fileLogger.rollingFrequency = 60 * 60 * 24
        // 本地时区格式化器(教训 ①),格式与默认实现保持一致。
        let localTimestamp = DateFormatter()
        localTimestamp.dateFormat = "yyyy/MM/dd HH:mm:ss:SSS"
        localTimestamp.timeZone = .current
        fileLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: localTimestamp)
        DDLog.add(fileLogger)

        #if DEBUG
            dynamicLogLevel = .all
        #else
            dynamicLogLevel = .info
        #endif

        // 退出留痕:确认对话框的"退出"走 NSApp.terminate,不经任何视图回调——
        // 在门面里观察 willTerminate,日志里的进程生灭才是完整闭环。
        // 观察者存活到进程终止,无需 removeObserver(与门面同生命周期)。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            LogService.info("Pulse 退出", category: "App")
        }

        // 核心层(PulseCore)的日志出口接到这里:历史库、传感器调度器等的日志照常进同一份
        // 文件日志(arch-review-2026-10-18/05)。
        CoreLog.install { level, message, category in
            switch level {
            case .info: LogService.info(message, category: category)
            case .warn: LogService.warn(message, category: category)
            case .error: LogService.error(message, category: category)
            }
        }
    }
}

extension LogService {
    nonisolated static func debug(_ message: String, category: String = "App") {
        DDLogDebug("[\(category)] \(message)")
    }

    nonisolated static func info(_ message: String, category: String = "App") {
        DDLogInfo("[\(category)] \(message)")
    }

    nonisolated static func warn(_ message: String, category: String = "App") {
        DDLogWarn("[\(category)] \(message)")
    }

    nonisolated static func error(_ message: String, category: String = "App") {
        DDLogError("[\(category)] \(message)")
    }
}
