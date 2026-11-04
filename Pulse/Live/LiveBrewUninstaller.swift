import Foundation
import PulseCore

// MARK: - Live brew 卸载(p4-uninstaller/03)与永久删除(ADR-0010 的执行器)

/// brew 卸载子进程:仅 `uninstall --cask [--zap]` 两条命令形态、120s 超时、
/// 失败原样上报(stderr 尾部人话),不解析 brew 其他输出(Q11:解释性,不装懂)。
/// brew 路径双候选(Apple Silicon / Intel);都不在 = brewMissing。
struct LiveBrewUninstaller: Sendable {
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// 网络问题不背锅:卸载是本地操作,但 cask 可能带 uninstall 脚本,给足余量。
    static let timeout: TimeInterval = 120

    private func brewPath() -> String? {
        let fileManager = FileManager.default
        return Self.brewCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    func uninstall(cask: String, zap: Bool) async -> BrewUninstallResult {
        guard let brew = brewPath() else {
            return .brewMissing
        }
        var arguments = ["uninstall", "--cask"]
        if zap {
            arguments.append("--zap")
        }
        arguments.append(cask)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        // brew 子命令依赖 HOME 定位 Caskroom 与缓存;PATH 带上常用位以防空壳环境。
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(environment["PATH"] ?? "")"
        process.environment = environment
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe() // 丢弃;失败信息走 stderr

        do {
            try process.run()
        } catch {
            return .failed(message: "无法启动 brew:\(error.localizedDescription)")
        }
        // 超时强杀:waiting 阻塞在后台线程,主流程不挂。
        let timedOut = TimeoutBox()
        let watchdog = Task.detached(priority: .utility) { [weak process = process, timedOut] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            if process?.isRunning == true {
                timedOut.mark()
                process?.terminate()
            }
        }
        process.waitUntilExit()
        watchdog.cancel()

        guard !timedOut.isMarked() else {
            return .failed(message: "brew 超过 \(Int(Self.timeout)) 秒未完成,已终止")
        }
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let tail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last
            return .failed(message: tail.flatMap(String.init) ?? "brew 退出码 \(process.terminationStatus)")
        }
        return .success
    }
}

/// 超时标记(进程被 terminate 后区分「超时杀」与「自己失败」)。
private final class TimeoutBox: @unchecked Sendable {
    /// @unchecked Sendable 前提:单一 Bool,仅在 watchdog 任务写、等待线程读,
    /// 时序上写先于 waitUntilExit 返回,无交错窗口。
    private var flagged = false

    func mark() {
        flagged = true
    }

    func isMarked() -> Bool {
        flagged
    }
}

/// 永久删除执行器(p4-uninstaller/03;唯一第三删除模式,只挂卸载域调用链——
/// p4-cleaner/08 剩余部分重开时按 ADR-0010 调整其「仅两种模式」断言口径)。
/// 逐项 FileManager.removeItem;失败项 localizedDescription 如实上报,不静默。
struct LiveCleanPermanentDeleter: Sendable {
    func deletePermanently(_ paths: [String]) async -> PermanentDeletionOutcome {
        let fileManager = FileManager.default
        var outcome = PermanentDeletionOutcome()
        for path in paths {
            do {
                try fileManager.removeItem(atPath: path)
                outcome.deleted.insert(path)
            } catch {
                outcome.failures[path] = error.localizedDescription
            }
        }
        return outcome
    }
}
