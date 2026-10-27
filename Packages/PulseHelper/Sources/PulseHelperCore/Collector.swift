import Foundation

// 采集与解析核心(p3-root-mcp/03):库 target 供单测,
// executable 只留 XPC 服务与校验。

public enum PowermetricsParser {
    /// 解析 `powermetrics -n 1 --show-process-energy…` 的 Running tasks 表。
    /// **语义锚定,不依赖列数**:表头列名是多词(`Energy Impact`、
    /// `(<2 ms, 2-5 ms)`),按表头数列数不可靠——改为:行尾 token =
    /// Energy Impact(恒为末列,probe 08 实证);名字后**第一个纯整数**
    /// token = pid(进程名含空格/括号实例:OrbStack Helper、
    /// Browser Helper (Renderer);纯数字进程名属未见过形态,启发式失效
    /// 时该行被跳过,不崩)。表头行(首 token 为 Name)跳过。
    public static func parse(_ output: String) -> [(pid: Int, name: String, impact: Double)] {
        var results: [(Int, String, Double)] = []
        var inTasks = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*** Running tasks ***") {
                inTasks = true
                continue
            }
            guard inTasks else { continue }
            if trimmed.hasPrefix("*") {
                break
            } // 下一个 section
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 3, tokens[0] != "Name",
                  let impact = Double(tokens[tokens.count - 1])
            else { continue }
            // 第一个纯整数 token = pid,其前 = 名字。
            guard let idIndex = tokens.firstIndex(where: { Int($0) != nil }),
                  idIndex > tokens.startIndex,
                  tokens[(idIndex + 1)...].allSatisfy({ Double($0) != nil })
            else { continue }
            let pid = Int(tokens[idIndex])!
            let name = tokens[..<idIndex].joined(separator: " ")
            results.append((pid, name, impact))
        }
        return results
    }
}

// MARK: - 采集器

public final class EnergyCollector {
    public private(set) var samples: [(pid: Int, name: String, impact: Double)] = []
    public private(set) var collectedAt = Date.distantPast

    public init() {}

    public func collect() {
        // 输出走 powermetrics 的 -o 临时文件,stdout/stderr 全部接 nullDevice:
        // 管道方案在 launchd daemon 环境实测死锁(2026-10-27 首装机二验——
        // helper 卡死首轮 collect,client 5s 超时,零子进程退出;经典 pipe
        // 缓冲互塞,readDataToEndOfFile 永等)。文件路径完全绕开管道。
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-helper-powermetrics-\(getpid()).txt")
        try? FileManager.default.removeItem(at: outputFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "-n", "1", "-i", "1000", "--show-process-energy", "--suppress-noop-events",
            "-o", outputFile.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return // 采集失败保留上一轮(调用方按 collectedAt 判龄)
        }
        // 壁钟防御:powermetrics -n 1 正常 ~1s;异常挂起 5s 强杀,本轮放弃。
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return
        }
        guard process.terminationStatus == 0 else { return }
        defer { try? FileManager.default.removeItem(at: outputFile) }
        guard let data = try? Data(contentsOf: outputFile) else { return }
        let parsed = PowermetricsParser.parse(String(data: data, encoding: .utf8) ?? "")
        guard !parsed.isEmpty else { return }
        samples = parsed
        collectedAt = Date()
    }
}
