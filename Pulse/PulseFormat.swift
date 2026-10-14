import Foundation

/// 纯显示格式化接缝:组卡与菜单栏的数字文案统一从这里出。
/// 无 OS 依赖,可单测(spec 测试决策:纯逻辑才测,UI 不写单元测试)。
enum PulseFormat {
    /// 百分比 → "42%":四舍五入到整数。组 CPU% 可超过 100("445%"),系统 CPU 负载 0–100。
    static func cpuPercent(_ value: Double) -> String {
        "\(cpuPercentNumber(value))%"
    }

    /// 百分比数字部分 → "445"(P0.6-02):大数字与单位分层排版用——
    /// 数字走圆体大字,单位 "%" 由视图以小字基线对齐拼接;取整口径与
    /// cpuPercent 同源,两个出口不会差 1%。
    static func cpuPercentNumber(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// 字节 → 人类可读内存:十进制单位(与活动监视器一致)。
    /// <1 GB 显示整 MB("512 MB");≥1 GB 保留一位小数("2.4 GB")。
    static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            // 整数算 tenth 再拼串,避免 String(format:) 受系统区域影响小数点写法。
            let tenths = Int((gb * 10).rounded())
            return "\(tenths / 10).\(tenths % 10) GB"
        }
        return "\(bytes / 1_000_000) MB"
    }

    /// 启动时长(工单 06):("已 25 分钟")。
    /// 秒 → 分 → 时 → 天逐级取整(<60 秒 "已 40 秒";<60 分 "已 25 分钟";
    /// <24 小时 "已 3 小时";≥24 小时 "已 3 天"——用户故事 13 的"常驻 3 天")。
    /// `startedAt` 为 nil(受限查询拿不到启动时刻)→ "启动时刻未知";
    /// 未来时刻(时钟回拨)按 0 秒夹紧。`now` 由调用方注入,纯函数可单测。
    static func uptime(startedAt: Date?, now: Date) -> String {
        guard let startedAt else { return "启动时刻未知" }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let minute = 60
        let hour = 60 * minute
        let day = 24 * hour
        switch elapsed {
        case ..<minute:
            return "已 \(elapsed) 秒"
        case ..<hour:
            return "已 \(elapsed / minute) 分钟"
        case ..<day:
            return "已 \(elapsed / hour) 小时"
        default:
            return "已 \(elapsed / day) 天"
        }
    }

    /// 进程显示名(工单 06):可执行路径 basename → argv[0] basename(路径受限时)→
    /// "pid N"(两者都拿不到时)。面包屑与进程行共用同一口径。
    static func processName(executablePath: String?, argv: [String], pid: pid_t) -> String {
        if let name = basename(ofPath: executablePath) ?? argv.first.flatMap(basename(ofPath:)),
           !name.isEmpty
        {
            return name
        }
        return "pid \(pid)"
    }

    private static func basename(ofPath path: String?) -> String? {
        path.map { String($0.split(separator: "/").last ?? Substring($0)) }
    }
}
