import Foundation
import PulseCore

/// 会话 git 状态的 Live 采集(工单 agent-git-status/01):分支 = 纯文件读
/// (主 checkout `<cwd>/.git/HEAD`;worktree 经 `.git` 文件重定向解析,零子进程);
/// 未提交 = `/usr/bin/git status --porcelain` 子进程(全库首例 git shell-out,
/// 结构沿用 NettopSource.runOnce:管道并行排空 + 看门狗兜底)。只在
/// AgentSessionFeature 的 utility 任务里单飞调用,不上主线程。
struct LiveSessionGitStatusReader: SessionGitStatusReading {
    func gitHeadFile(cwd: String) -> Data? {
        let dotGit = (cwd as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return readFile((dotGit as NSString).appendingPathComponent("HEAD"))
        }
        // worktree:`.git` 是文件,内容 "gitdir: <路径>",HEAD 在该目录下。
        guard
            let redirect = readFile(dotGit),
            let gitdir = GitWorktreeRedirect.gitdir(redirect)
        else { return nil }
        return readFile((gitdir as NSString).appendingPathComponent("HEAD"))
    }

    func gitStatusOutput(cwd: String) -> Data? {
        let process = Process()
        // 绝对路径:不依赖 PATH(agent 会话的环境不可控);--no-optional-locks
        // 不抢 index 机会锁——会话 agent 自己也在跑 git,别打架。
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "--no-optional-locks", "status", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = GitCommandWatchdog(process)
        watchdog.arm(termAfter: 2, killGrace: 0.5)
        // 读端阻塞到 EOF(与子进程写端并行排空);EOF 由正常退出或看门狗逼出。
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()
        // 被信号收尾 / 非零退出:半截输出不可信(判脏要整份 porcelain),整体作废。
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return nil
        }
        return data
    }

    private func readFile(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}

/// git 子进程看门狗(NettopWatchdog 两级同款、单进程版):到期 SIGTERM,宽限
/// 仍跑则 SIGKILL——巨仓冷缓存下 status 可能秒级不归,必须逼出 EOF 免得读端
/// 永久挂起。Process 非 Sendable,此处定时器闭包只碰 isRunning / terminate /
/// 进程 id,与读端无共享可变态——@unchecked 前提(并发纪律,前提消失须同步改)。
private final class GitCommandWatchdog: @unchecked Sendable {
    private let process: Process
    private var termTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?

    init(_ process: Process) {
        self.process = process
    }

    func arm(termAfter: TimeInterval, killGrace: TimeInterval) {
        let queue = DispatchQueue.global(qos: .utility)
        let termSource = DispatchSource.makeTimerSource(queue: queue)
        termSource.schedule(deadline: .now() + termAfter)
        termSource.setEventHandler { [process] in
            if process.isRunning {
                process.terminate()
            }
        }
        termSource.resume()
        // 命名避开 Darwin `kill(2)`——局部名遮蔽函数名的实犯一次,编译器抓的。
        let killSource = DispatchSource.makeTimerSource(queue: queue)
        killSource.schedule(deadline: .now() + termAfter + killGrace)
        killSource.setEventHandler { [process] in
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        killSource.resume()
        termTimer = termSource
        killTimer = killSource
    }

    func cancel() {
        termTimer?.cancel()
        killTimer?.cancel()
    }
}
