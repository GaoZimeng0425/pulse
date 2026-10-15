import Foundation
import Darwin

// MARK: - 头部环境信息(工单 P0.6-04)

/// 设备环境信息:主窗口副标题(芯片 · 核数 · 内存)与弹窗 uptime 的数据源。
/// 读取(sysctl / ProcessInfo)与格式化(纯逻辑)分离——格式化单测见
/// EnvironmentInfoTests,读到的实机值以走查验收(硬件不会热变,启动期读一次)。
struct SystemEnvironmentInfo: Equatable, Sendable {
    /// 芯片营销名,如 "Apple M4"。取 sysctl `machdep.cpu.brand_string`——
    /// Apple Silicon 上即营销名(工单原提的 `hw.model` 是机型代号 "Mac16,1",
    /// 取不到 "Apple M4" 这类营销名;Intel 机型 brand_string 为完整品牌串,同样可读)。
    let chipName: String
    /// 逻辑核数(ProcessInfo.processorCount)。
    let coreCount: Int
    /// 物理内存字节(ProcessInfo.physicalMemory)。
    let physicalMemoryBytes: UInt64

    /// 实机读取(启动期一次)。
    static func live() -> SystemEnvironmentInfo {
        SystemEnvironmentInfo(
            chipName: Self.sysctlString("machdep.cpu.brand_string") ?? "",
            coreCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// sysctl 字符串读取;失败(名字不存在 / 受限)返回 nil。
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 环境信息纯格式化(单测接缝)。
enum EnvironmentInfoFormat {
    /// 主窗口副标题(参考文档 §2.1 "Apple M1 Max · 10 cores · 64 GB" 形态,
    /// 中文单位):"Apple M4 · 10 核 · 32 GB"。空段跳过——读不到芯片名不硬凑。
    static func subtitle(chipName: String, coreCount: Int, memoryBytes: UInt64) -> String {
        var parts: [String] = []
        if !chipName.isEmpty { parts.append(chipName) }
        if coreCount > 0 { parts.append("\(coreCount) 核") }
        let gigabytes = memoryGigabytes(memoryBytes)
        if gigabytes > 0 { parts.append("\(gigabytes) GB") }
        return parts.joined(separator: " · ")
    }

    /// 物理内存 → 整 GB:装机容量为 2 的幂 GiB,直读即整;防御非幂值取最近。
    static func memoryGigabytes(_ bytes: UInt64) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    /// 系统 uptime(ProcessInfo.systemUptime 秒):"已运行 3 天 4 小时"式复合
    /// 时长大单位 + 次级单位,次级为 0 省略;<1 小时退为单单位(秒 / 分钟)。
    /// 与进程启动时长 PulseFormat.uptime("已 25 分钟",恒单单位)是两个口径。
    /// 负值(时钟异常)按 0 夹紧。
    static func systemUptime(_ seconds: Double) -> String {
        let elapsed = max(0, Int(seconds))
        let minute = 60
        let hour = 60 * minute
        let day = 24 * hour
        switch elapsed {
        case ..<minute:
            return "已运行 \(elapsed) 秒"
        case ..<hour:
            return "已运行 \(elapsed / minute) 分钟"
        case ..<day:
            return compound(elapsed / hour, "小时", (elapsed % hour) / minute, "分钟")
        default:
            return compound(elapsed / day, "天", (elapsed % day) / hour, "小时")
        }
    }

    /// "已运行 A 单位a B 单位b";B 为 0 时省略后半,不出现"0 小时"。
    private static func compound(_ major: Int, _ majorUnit: String, _ minor: Int, _ minorUnit: String) -> String {
        minor > 0
            ? "已运行 \(major) \(majorUnit) \(minor) \(minorUnit)"
            : "已运行 \(major) \(majorUnit)"
    }
}
