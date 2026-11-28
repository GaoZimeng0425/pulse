import Foundation
import PulseCore

// MARK: - Live 系统级条目移进废纸篓(p7-cleaner/05;ADR-0012)

//
// `CleanSystemTrashExecutor` 的真实现,分两段:
//   第一段(root):写清单文件(一行一个路径,仅本人可读写)→ osascript
//     「do shell script … with administrator privileges」跑随包分发的复核脚本
//     (Pulse/Resources/SystemTrash/pulse-system-trash.sh)→ 脚本把条目移进它私有的暂存目录、
//     在那里逐条复核并改归属,再把暂存目录交给调用者。
//   第二段(以调用者身份):把暂存目录里的文件挪进废纸篓的专属子目录。
// root 不往任何用户可控的目录里写、不按那里的路径改归属(登记目录对某个用户组可写,
// 用户能把 root 文件的硬链接放进去;废纸篓归用户所有,目录能被换成链接)——所以进废纸篓
// 这一步由用户自己做。
// 密码框可以一直开着等用户:不设超时。授权只在这一批动作发生时借一次,不常驻。
// 提权一侧自己复核每一条(登记的路径形状 / 链接数 / 属主 / 年龄),这里的判断只是不把
// 明显发不出去的请求送过去。
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

    /// 复核脚本放暂存目录的地方与名字前缀(与 pulse-system-trash.sh 保持一致)。
    static let stagingParent = "/var/tmp"
    static let stagingDirectoryPrefix = "pulse-system-trash."

    /// 专属子目录里同一个名字最多排到第几号;再往后按「挪不进废纸篓」如实报,绝不覆盖。
    private static let maximumNameSequence = 9999

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

    /// 复核脚本的回执(第一段的结果)。
    struct Handoff: Sendable, Equatable {
        /// 暂存目录;一条都没移走时为 nil。
        let staging: String?
        /// 已移走的 原→暂存目录里的路径;没动的 原→原因(人话)。
        let receipt: TrashRecycleOutcome
    }

    /// 第一段(root 脚本)怎么收场。
    enum ScriptTermination: Equatable {
        case completed(Handoff)
        case authorizationCancelled
        case channelUnavailable(reason: String)
    }

    // MARK: 整条通道

    /// - Parameters:
    ///   - scriptPath: 复核脚本的路径(生产 = 应用包里的那份)。
    ///   - privileged: 带不带「with administrator privileges」。生产恒 true;测试用 false 跑
    ///     同一条命令但不弹密码框。
    ///   - environment: 追加给子进程的环境变量(生产为空;测试用它传自测开关)。
    ///   - trashRoot / temporaryDirectory / stagingParent: 生产 = 用户的废纸篓、临时目录与脚本的
    ///     暂存目录所在;测试指向临时目录。
    static func run(
        _ request: SystemTrashRequest,
        scriptPath: String?,
        privileged: Bool,
        environment: [String: String],
        trashRoot: String,
        temporaryDirectory: String,
        stagingParent: String = stagingParent
    ) async -> SystemTrashOutcome {
        guard let scriptPath else {
            return .channelUnavailable(reason: "复核脚本缺失(应用包不完整)")
        }
        guard request.paths.allSatisfy(isEncodableInManifest) else {
            return .channelUnavailable(reason: "有条目的路径含换行或制表符,没法写进清单文件")
        }
        // 废纸篓进不去就不必让用户输密码:这一批的专属子目录先建出来,建不出来 = 通道不可用。
        let target = trashRoot + "/" + trashSubdirectory + "/" + stampDirectoryName(for: Date())
        do {
            try FileManager.default.createDirectory(
                atPath: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .channelUnavailable(reason: "废纸篓里建不了目标目录:\(error.localizedDescription)")
        }
        // 一条都没进废纸篓时,别留空文件夹。
        defer { discardIfEmpty(target) }
        let recovered = recoverLeftoverStaging(in: stagingParent, trashRoot: trashRoot)
        if recovered > 0 {
            LogService.info(
                "系统级清理:上次没来得及进废纸篓的 \(recovered) 个文件已收进「\(trashSubdirectory)」",
                category: "Cleaner"
            )
        }
        let manifest = (temporaryDirectory as NSString).appendingPathComponent(
            "pulse-system-trash-\(UUID().uuidString).manifest"
        )
        // 用完即清:删的是本通道刚建的临时清单文件,不是用户数据,不属于 ADR-0008 管的
        // 删除出口(那两处删的是用户的东西)——所以在这里显式放行并写明理由。
        // swiftlint:disable:next no_remove_item_outside_deletion_gates
        defer { try? FileManager.default.removeItem(atPath: manifest) }
        do {
            try writeManifest(to: manifest, paths: request.paths)
        } catch {
            return .channelUnavailable(reason: "清单文件写不了:\(error.localizedDescription)")
        }

        // 路径不拼进命令之外的地方:两个路径各自整体单引号引用,用户 id 是数字。
        let command = [
            "/bin/sh", shellQuoted(scriptPath), shellQuoted(manifest), String(request.requesterUID),
        ].joined(separator: " ")
        let termination = await launch(
            "/usr/bin/osascript",
            arguments: ["-e", appleScript(command, privileged: privileged)],
            environment: environment
        )
        switch outcome(for: termination) {
        case .authorizationCancelled:
            return .authorizationCancelled
        case let .channelUnavailable(reason):
            return .channelUnavailable(reason: reason)
        case let .completed(handoff):
            return .completed(relocate(handoff, target: target))
        }
    }

    /// 收走上次没来得及进废纸篓的暂存目录:app 在脚本交接之后、挪进废纸篓之前被杀,文件就
    /// 留在脚本的暂存目录里。它们是用户已经授权移走的,这次补挪进废纸篓(暂存目录名当
    /// 批次名,免得和这一批混)。只认属于当前用户的目录(交接过的);没交接的归脚本自己
    /// 在下一次运行时放回原处。返回收走的文件数。
    static func recoverLeftoverStaging(in stagingParent: String, trashRoot: String) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: stagingParent) else { return 0 }
        var recovered = 0
        for name in names where name.hasPrefix(stagingDirectoryPrefix) {
            let leftover = (stagingParent as NSString).appendingPathComponent(name)
            guard isDirectoryOwnedByCurrentUser(leftover) else { continue }
            let destination = trashRoot + "/" + trashSubdirectory + "/" + name
            do {
                try manager.createDirectory(
                    atPath: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
            } catch {
                continue // 这一个收不了,原样留着
            }
            guard let entries = try? manager.contentsOfDirectory(atPath: leftover) else {
                discardIfEmpty(destination)
                continue
            }
            var remaining = false
            for entry in entries {
                do {
                    try manager.moveItem(
                        atPath: (leftover as NSString).appendingPathComponent(entry),
                        toPath: (destination as NSString).appendingPathComponent(entry)
                    )
                    recovered += 1
                } catch {
                    remaining = true
                }
            }
            if remaining {
                discardIfEmpty(destination)
            } else {
                _ = rmdir(leftover)
            }
        }
        return recovered
    }

    private static func isDirectoryOwnedByCurrentUser(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR && status.st_uid == getuid()
    }

    // MARK: 第二段:进废纸篓(以调用者身份)

    /// 把暂存目录里的文件挪进废纸篓的专属子目录(目标目录由调用方在要授权之前建好)。挪不动
    /// 的留在暂存目录(已是调用者的文件),原因里写明在哪,下次运行时收走;都挪走了才收掉
    /// 空的暂存目录。
    /// - Parameter target: 这一批在废纸篓里的专属子目录(已存在)。
    static func relocate(_ handoff: Handoff, target: String) -> TrashRecycleOutcome {
        var outcome = TrashRecycleOutcome(failures: handoff.receipt.failures)
        guard let staging = handoff.staging else {
            // 没交接 = 一条都没移走;脚本这时候不该报「已移走」,报了也不认。
            for source in handoff.receipt.recycled.keys {
                outcome.failures[source] = "复核脚本说已移走,却没有交出暂存目录"
            }
            return outcome
        }
        for (source, staged) in handoff.receipt.recycled.sorted(by: { $0.key < $1.key }) {
            let name = (staged as NSString).lastPathComponent
            guard let destination = availableDestination(for: name, in: target) else {
                outcome.failures[source] = "废纸篓子目录里同名文件太多,暂存在 \(staged)"
                continue
            }
            do {
                try FileManager.default.moveItem(atPath: staged, toPath: destination)
                outcome.recycled[source] = destination
            } catch {
                outcome.failures[source] = "已移出原处,暂存在 \(staged),没能放进废纸篓:\(error.localizedDescription)"
            }
        }
        if outcome.recycled.isEmpty {
            discardIfEmpty(target)
        }
        if handoff.receipt.recycled.allSatisfy({ outcome.recycled[$0.key] != nil }) {
            _ = rmdir(staging)
        }
        return outcome
    }

    /// 专属子目录里一批一个时间戳目录(查找与清点都按这个形状认)。
    static func stampDirectoryName(for date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// 专属子目录里还没被占用的去向:先是原名,被占了加序号。排到上限还没空位 = nil。
    private static func availableDestination(for name: String, in directory: String) -> String? {
        let base = (directory as NSString).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: base) {
            return base
        }
        for sequence in 1 ... maximumNameSequence {
            let candidate = base + "." + String(sequence)
            if !FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// 目录空就收掉;它的上一级(专属子目录)也空就一并收掉。
    /// 用 rmdir:它只收得下空目录,结构上删不了任何内容(比「先查空再删」还少一道竞态),
    /// 不是 ADR-0008 管的删除出口。非空或不存在时它自己失败,忽略即可。
    private static func discardIfEmpty(_ directory: String) {
        for path in [directory, (directory as NSString).deletingLastPathComponent] {
            _ = rmdir(path)
        }
    }

    // MARK: 清单文件

    /// 清单一行一个绝对路径;含换行或制表符的没法表达(结果行也是制表符分隔的)。
    static func isEncodableInManifest(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\n") && !path.contains("\r") && !path.contains("\t")
    }

    /// 写清单文件。建文件的那一刻起就只有本人可读写(0600),不走「先建成 0644 再改权限」
    /// 那条缝;复核脚本按「属主 = 调用者」核对它。文件已存在时不覆盖。
    static func writeManifest(to path: String, paths: [String]) throws {
        let data = Data((paths.joined(separator: "\n") + "\n").utf8)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { write(descriptor, $0, buffer.count) } ?? 0
        }
        guard written == data.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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

    /// 退出码 0 = 走完;用户取消 = 系统脚本的错误号 -128(通道原样带着它,认原始输出);
    /// 其余按通道不可用,原因如实带出。
    static func outcome(for termination: Termination) -> ScriptTermination {
        if termination.status == 0 {
            return .completed(parse(termination.stdout))
        }
        let rawLines = termination.stderr.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        if rawLines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("(-128)") }) {
            return .authorizationCancelled
        }
        return .channelUnavailable(reason: failureReason(for: termination))
    }

    private static func stderrLines(_ termination: Termination) -> [String] {
        termination.stderr.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(unwrapped)
    }

    /// 系统脚本通道会把脚本的错误输出包一层:「<位置>: execution error: <脚本写到标准错误的
    /// 内容> (<脚本退出码>)」。脚本自己说了原因就取那一句;没说就取系统的第一句。
    private static func failureReason(for termination: Termination) -> String {
        let lines = stderrLines(termination)
        for line in lines {
            if let range = line.range(of: "channel-unavailable: ") {
                return String(line[range.upperBound...])
            }
        }
        return lines.first ?? "系统脚本退出码 \(termination.status)"
    }

    /// 去掉通道包的那一层:前缀「<位置>: execution error: 」与尾部的「 (<退出码>)」。
    private static func unwrapped(_ line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "execution error: ") {
            text = String(text[range.upperBound...])
        }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "("), open > text.startIndex,
           text[text.index(before: open)] == " ",
           text[text.index(after: open)...].dropLast().allSatisfy({ $0 == "-" || $0.isNumber }) {
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// 结果行制表符分隔:SKIPPED / MOVED 三段,STAGING 两段(交接成功才有)。SKIPPED 的原因
    /// 代码翻成人话;坏行忽略——没有回执的条目由执行编排按失败记。换行按「任意换行」认:
    /// 系统脚本通道把标准输出的换行回传成回车(系统脚本以回车分行),别只认 \n。
    static func parse(_ stdout: String) -> Handoff {
        var receipt = TrashRecycleOutcome()
        var staging: String?
        for line in stdout.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "STAGING" where fields.count == 2:
                staging = fields[1]
            case "MOVED" where fields.count == 3:
                receipt.recycled[fields[1]] = fields[2]
            case "SKIPPED" where fields.count == 3:
                receipt.failures[fields[1]] = reasonText(fields[2])
            default:
                continue
            }
        }
        return Handoff(staging: staging, receipt: receipt)
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
        case "stat-failed": "读不到文件的状态,没动"
        case "hard-linked": "和别的路径是同一个文件的硬链接,没动"
        case "owner-not-system": "属主不是 root 或系统用户"
        case "too-young": "还没满 7 天(移动前又核了一次)"
        case "ownership-not-changed": "归属改不成当前用户,已放回原处"
        case "duplicate": "同一个条目在清单里出现了不止一次,第二次没动"
        case "not-restored": "没能放回原处(原处又出现了同名条目);文件暂时留在暂存目录,下次运行时收进废纸篓"
        default: "复核未通过(\(code))"
        }
    }
}
