import Foundation
import PulseCore

// MARK: - Live 系统级条目移进废纸篓(p7-cleaner/05;ADR-0012)

//
// `CleanSystemTrashExecutor` 的真实现:经系统脚本的管理员授权,以 root 身份运行随包分发的
// 复核脚本(Pulse/Resources/SystemTrash/pulse-system-trash.sh)。
// 流程:建废纸篓专属子目录 → 写清单文件(一行一个路径,仅本人可读写)→ osascript
// 「do shell script … with administrator privileges」跑脚本 → 解析逐项结果行 → 删清单文件。
// 密码框可以一直开着等用户:不设超时。授权只在这一批动作发生时借一次,不常驻。
// 提权一侧自己复核每一条(登记的路径形状 / 属主 / 年龄),这里的判断只是不把明显发不出去
// 的请求送过去。
// 真实提权路径不进自动化测试;离线钉住的是清单写法、命令行拼法、结果解析,外加「不带
// 管理员授权」跑一遍真脚本(不弹密码框)。

struct LiveCleanSystemTrashExecutor: CleanSystemTrashExecutor {
    func moveSystemItems(_ request: SystemTrashRequest) async -> SystemTrashOutcome {
        await Self.run(
            request,
            scriptPath: Self.bundledScriptPath,
            privileged: true,
            environment: [:],
            trashRoot: NSHomeDirectory() + "/.Trash",
            temporaryDirectory: NSTemporaryDirectory()
        )
    }

    /// 随包分发的复核脚本;取不到 = 应用包不完整。
    static var bundledScriptPath: String? {
        Bundle.main.url(forResource: "pulse-system-trash", withExtension: "sh")?.path
    }

    /// 专属子目录在废纸篓里的上一级。
    static let trashSubdirectory = "Pulse 系统级"

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// 一次子进程的收场。
    struct Termination: Sendable, Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    // MARK: 整条通道

    /// - Parameters:
    ///   - scriptPath: 复核脚本的路径(生产 = 应用包里的那份)。
    ///   - privileged: 带不带「with administrator privileges」。生产恒 true;测试用 false 跑
    ///     同一条命令但不弹密码框。
    ///   - environment: 追加给子进程的环境变量(生产为空;测试用它传自测开关)。
    ///   - trashRoot / temporaryDirectory: 生产 = 用户的废纸篓与临时目录;测试指向临时目录。
    static func run(
        _ request: SystemTrashRequest,
        scriptPath: String?,
        privileged: Bool,
        environment: [String: String],
        trashRoot: String,
        temporaryDirectory: String
    ) async -> SystemTrashOutcome {
        guard let scriptPath else {
            return .channelUnavailable(reason: "复核脚本缺失(应用包不完整)")
        }
        guard request.paths.allSatisfy(isEncodableInManifest) else {
            return .channelUnavailable(reason: "有条目的路径含换行或制表符,没法写进清单文件")
        }
        let target = trashRoot + "/" + trashSubdirectory + "/" + stampFormatter.string(from: Date())
        do {
            try FileManager.default.createDirectory(
                atPath: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .channelUnavailable(reason: "废纸篓里建不了目标目录:\(error.localizedDescription)")
        }
        // 没移走任何东西时,别在废纸篓里留空文件夹。
        defer { discardIfEmpty(target) }
        let manifest: String
        do {
            manifest = try writeManifest(for: request.paths, in: temporaryDirectory)
        } catch {
            return .channelUnavailable(reason: "清单文件写不了:\(error.localizedDescription)")
        }
        // 用完即清:删的是本通道刚建的临时清单文件,不是用户数据,不属于 ADR-0008 管的
        // 删除出口(那两处删的是用户的东西)——所以在这里显式放行并写明理由。
        // swiftlint:disable:next no_remove_item_outside_deletion_gates
        defer { try? FileManager.default.removeItem(atPath: manifest) }

        // 路径不拼进命令之外的地方:三个路径各自整体单引号引用,用户 id 是数字。
        let command = [
            "/bin/sh", shellQuoted(scriptPath), shellQuoted(manifest),
            String(request.requesterUID), shellQuoted(target),
        ].joined(separator: " ")
        let termination = await launch(
            "/usr/bin/osascript",
            arguments: ["-e", appleScript(command, privileged: privileged)],
            environment: environment
        )
        return outcome(for: termination)
    }

    // MARK: 清单文件

    /// 清单一行一个绝对路径;含换行或制表符的没法表达(结果行也是制表符分隔的)。
    static func isEncodableInManifest(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\n") && !path.contains("\r") && !path.contains("\t")
    }

    /// 写清单文件并返回路径。仅本人可读写(0600):复核脚本按「属主 = 调用者」核对它。
    /// 权限在建好后显式设——按普通方式建出来是 0644,别的人也读得到。
    static func writeManifest(for paths: [String], in directory: String) throws -> String {
        let path = (directory as NSString).appendingPathComponent("pulse-system-trash-\(UUID().uuidString).manifest")
        let data = Data((paths.joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(atPath: path, contents: data) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    // MARK: 命令行

    /// 给 /bin/sh 用:整体单引号引用,里面的单引号写成 '\''。
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 给 AppleScript 字符串字面量用:反斜杠与双引号各加一个反斜杠。
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 整句 AppleScript:系统脚本那一句,带不带管理员授权只差最后那个短语。
    static func appleScript(_ command: String, privileged: Bool) -> String {
        "do shell script " + appleScriptString(command) + (privileged ? " with administrator privileges" : "")
    }

    /// 跑子进程并收回两路输出。两路都边跑边读(管道写满会卡住子进程);等待走
    /// terminationHandler 续体,不在协作线程池里同步等。
    private static func launch(
        _ executable: String,
        arguments: [String],
        environment: [String: String]
    ) async -> Termination {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, injected in injected }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = OutputBuffer()
        let stderr = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
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
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return Termination(status: -1, stdout: "", stderr: "无法启动系统脚本:\(error.localizedDescription)")
        }
        // 先摘回调再收尾巴:同一 FileHandle 不许回调与同步读并发。
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        return Termination(
            status: status,
            stdout: String(decoding: stdout.data(), as: UTF8.self),
            stderr: String(decoding: stderr.data(), as: UTF8.self)
        )
    }

    // MARK: 结果与失败

    /// 退出码 0 = 走完;用户取消 = 系统脚本的错误号 -128;其余按通道不可用,原因如实带出。
    static func outcome(for termination: Termination) -> SystemTrashOutcome {
        if termination.status == 0 {
            return .completed(parse(termination.stdout))
        }
        if termination.stderr.contains("-128") {
            return .authorizationCancelled
        }
        return .channelUnavailable(reason: failureReason(for: termination))
    }

    private static func failureReason(for termination: Termination) -> String {
        let lines = termination.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let declared = lines.first(where: { $0.hasPrefix("channel-unavailable: ") }) {
            return String(declared.dropFirst("channel-unavailable: ".count))
        }
        if let first = lines.first {
            return first
        }
        return "系统脚本退出码 \(termination.status)"
    }

    /// 结果行三段、制表符分隔:MOVED 原→新,SKIPPED 原→原因代码(翻成人话)。坏行忽略——
    /// 没有回执的条目由执行编排按失败记。换行按「任意换行」认:系统脚本通道把标准输出
    /// 的换行回传成回车(系统脚本以回车分行),别只认 \n。
    static func parse(_ stdout: String) -> TrashRecycleOutcome {
        var outcome = TrashRecycleOutcome()
        for line in stdout.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            switch fields[0] {
            case "MOVED":
                outcome.recycled[fields[1]] = fields[2]
            case "SKIPPED":
                outcome.failures[fields[1]] = reasonText(fields[2])
            default:
                continue
            }
        }
        return outcome
    }

    /// 复核脚本的原因代码 → 人话。代码是脚本的固定词表,没见过的照实报出来。
    static func reasonText(_ code: String) -> String {
        switch code {
        case "not-absolute": "路径不是绝对路径"
        case "contains-dotdot": "路径含 .."
        case "outside-registered-directory": "不在登记的系统目录里"
        case "not-direct-child": "不在系统目录的直接下面"
        case "hidden-file": "隐藏文件"
        case "symlink": "是符号链接"
        case "not-a-regular-file": "已不在原处,或不是普通文件"
        case "owner-not-system": "属主不是 root 或系统用户"
        case "too-young": "还没满 7 天(移动前又核了一次)"
        case "move-failed": "移动失败"
        default: "复核未通过(\(code))"
        }
    }

    /// 目录空就收掉;它的上一级(专属子目录)也空就一并收掉。复核脚本在一个都没移走时
    /// 自己会收掉目标目录,所以某一级已经不在了不算事,接着看上一级。
    /// 用 rmdir:它只收得下空目录,结构上删不了任何内容(比「先查空再删」还少一道竞态),
    /// 不是 ADR-0008 管的删除出口。非空或不存在时它自己失败,忽略即可。
    private static func discardIfEmpty(_ directory: String) {
        for path in [directory, (directory as NSString).deletingLastPathComponent] {
            _ = rmdir(path)
        }
    }
}
