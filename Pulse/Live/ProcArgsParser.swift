import Foundation
import Darwin
import PulseCore

/// KERN_PROCARGS2 缓冲解析(纯逻辑,可单测)。
///
/// 布局:`int32 argc + execpath(NUL 结尾)+ argv[0..argc-1](各自 NUL 结尾)+ envp…`
/// 解析时跳过第一个字符串(execpath),再取满 argc 条 argv——与 ps 同口径。
enum ProcArgsParser {
    /// 解析缓冲里的 argv。`validLength` 是 sysctl 实际写入的有效字节数。
    static func parseArgv(buffer: [CChar], validLength: Int) -> [String] {
        guard validLength >= 4, validLength <= buffer.count else { return [] }

        let argc = buffer.withUnsafeBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }
        guard argc > 0 else { return [] }

        var index = 4
        // 跳过 execpath(第一个 NUL 结尾字符串)及其后的对齐补位 NUL:
        // 内核把 argv 起点对齐到 int 边界,execpath 结尾可能跟 0~3 个额外 NUL(ps 同样整段跳过)。
        while index < validLength && buffer[index] != 0 {
            index += 1
        }
        while index < validLength && buffer[index] == 0 {
            index += 1
        }

        var argv: [String] = []
        var consumed = 0
        // 空参数占一个槽位但不产出条目,保证窗口不会错位读到 envp。
        while consumed < argc && index < validLength {
            let start = index
            while index < validLength && buffer[index] != 0 {
                index += 1
            }
            if index > start {
                var cString = Array(buffer[start..<index])
                cString.append(0)
                argv.append(String(cString: cString))
            }
            consumed += 1
            index += 1  // 跳过本条 argv 的 NUL
        }
        return argv
    }

    /// 对目标进程执行 KERN_PROCARGS2 sysctl 并解析;失败 / 受限 → 空数组。
    /// `buffer` 由调用方持有并在整轮采集内复用,避免每进程分配 1 MiB。
    static func argv(of pid: pid_t, into buffer: inout [CChar]) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = buffer.count
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return [] }
        return parseArgv(buffer: buffer, validLength: length)
    }
}
