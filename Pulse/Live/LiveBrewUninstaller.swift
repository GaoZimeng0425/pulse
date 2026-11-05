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

    /// 测试注入:替身可执行文件(不传 = 按双候选找真 brew)。
    var executableOverride: String?
    var timeout: TimeInterval = Self.timeout

    private func brewPath() -> String? {
        if let executableOverride {
            return executableOverride
        }
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
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // 两路输出都必须边跑边读:管道缓冲(~64KB)写满后 brew 阻塞在 write,永远
        // 等不到退出,只能被超时强杀(cleaner-hardening/03)。stdout 读了即丢,stderr 留尾部。
        let stderrBuffer = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        // 超时强杀:watchdog 只负责 terminate,等待走 terminationHandler 续体——
        // 不在协作线程池里同步 waitUntilExit 占线程。
        let timedOut = TimeoutBox()
        let timeout = timeout
        let watchdog = Task.detached(priority: .utility) { [weak process = process, timedOut] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process?.isRunning == true {
                timedOut.mark()
                process?.terminate()
            }
        }
        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            watchdog.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failed(message: "无法启动 brew:\(error.localizedDescription)")
        }
        watchdog.cancel()
        // 先摘回调再收尾巴:同一 FileHandle 不许回调与同步读并发。
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        guard !timedOut.isMarked() else {
            return .failed(message: "brew 超过 \(Int(timeout)) 秒未完成,已终止")
        }
        guard status == 0 else {
            let tail = String(data: stderrBuffer.data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last
            return .failed(message: tail.flatMap(String.init) ?? "brew 退出码 \(status)")
        }
        return .success
    }
}

/// stderr 累积(readabilityHandler 在 FileHandle 私有队列回调,与等待方跨线程)。
private final class OutputBuffer: @unchecked Sendable {
    /// @unchecked Sendable 前提:全部读写经 lock 串行。
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { bytes.append(chunk) }
    }

    func data() -> Data {
        lock.withLock { bytes }
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
