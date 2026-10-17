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

    /// 内存大数字与单位分层(工单 P0.6-03,内存 tab 组卡):("2.4", "GB")——
    /// 数字走圆体大字,单位小一号、基线对齐(参考文档 §1.2 figure 规格)。
    /// 与 memory() 同源同格式,只是拆开交付;两个出口不会差一个字。
    static func memoryFigure(_ bytes: UInt64) -> (value: String, unit: String) {
        let text = memory(bytes)
        guard let separator = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<separator]), String(text[text.index(after: separator)...]))
    }

    /// 系统内存(工单 P0.6-05 总览/内存卡):**二进制** GB 两位小数("51.06 GB"),
    /// <1 GiB 显示整 MB——与物理总量同一口径,"已用 / 共" 不打架
    /// (组内存仍走 memory() 的十进制口径,两者语境不同)。
    static func systemMemory(_ bytes: UInt64) -> String {
        let figure = systemMemoryFigure(bytes)
        return "\(figure.value) \(figure.unit)"
    }

    /// systemMemory 的数字/单位分层版(大数字排版用)。
    static func systemMemoryFigure(_ bytes: UInt64) -> (value: String, unit: String) {
        let gib = Double(bytes) / 1_073_741_824
        guard gib >= 1 else { return ("\(bytes / 1_048_576)", "MB") }
        let hundredths = Int((gib * 100).rounded())
        let fraction = hundredths % 100
        return ("\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)", "GB")
    }

    /// 物理内存总量:二进制 GB 取整("64 GB")。
    static func physicalMemoryTotal(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB"
    }

    /// 磁盘容量(工单 05):字节 → **十进制** GB 两位小数("398.12 GB")——
    /// Finder「可用/已用」按十进制 GB 报数(探针①同刻 209.55 GB 分毫不差),
    /// 磁盘卡与 Finder 对照必须同口径;百分位手算拼串,不受系统区域影响。
    static func diskCapacity(_ bytes: UInt64) -> String {
        let figure = diskCapacityFigure(bytes)
        return "\(figure.value) \(figure.unit)"
    }

    /// diskCapacity 的数字/单位分层版(大数字排版用),同源同格式。
    static func diskCapacityFigure(_ bytes: UInt64) -> (value: String, unit: String) {
        let gb = Double(bytes) / 1_000_000_000
        let hundredths = Int((gb * 100).rounded())
        let fraction = hundredths % 100
        return ("\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)", "GB")
    }

    /// 磁盘速率(工单 05):字节/秒 → "12.4 MB/s"(十进制 KB/MB/GB 三级,
    /// 一位小数;十分位手算拼串,不随系统区域漂移;负值按 0 夹紧)。
    static func diskRate(_ bytesPerSecond: Double) -> String {
        let (value, unit) = decimalByteScale(max(0, bytesPerSecond))
        return "\(oneDecimal(value)) \(unit)/s"
    }

    /// 磁盘剩余徽标(工单 09 菜单栏槽位):字节 → 十进制 GB 整数("182 GB"),
    /// 与磁盘卡同口径不同精度——菜单栏求窄,两位小数让位给一字宽度;
    /// nil = 容量读数未到,占位 "—" 不伪造;负值(读数异常)按 0 夹紧。
    static func diskRemainingBadge(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let gb = Double(max(0, bytes)) / 1_000_000_000
        return "\(Int(gb.rounded())) GB"
    }

    /// 网络速率徽标(工单 09 菜单栏槽位):字节/秒 → "12.4 MB/s",口径与
    /// 磁盘速率同一套十进制三级一位小数;独立入口,工单 06 网络卡的卡片
    /// 展示格式落地时不与本徽标耦合。
    static func networkRateBadge(_ bytesPerSecond: Double) -> String {
        diskRate(bytesPerSecond)
    }

    /// 网络速率的数字/单位分层版(工单 06 网络卡大数字排版),口径与
    /// networkRateBadge 同源同格式(磁盘速率同一套十进制三级一位小数)。
    static func networkRateFigure(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let text = networkRateBadge(bytesPerSecond) // "12.4 MB/s"
        let parts = text.split(separator: " ")
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    /// 网络累计(工单 06):字节 → "12.4 MB" / "2.5 GB" / "1.2 TB"(十进制
    /// KB/MB/GB/TB 四级;百级以上取整求窄,0 恒为 "0.0 KB");与速率同一套
    /// 十进制口径,Today/7 天累计列共用。
    static func networkTotal(_ bytes: UInt64) -> String {
        let (value, unit) = decimalByteScale(Double(bytes))
        if value >= 100 { return "\(Int(value.rounded())) \(unit)" }
        return "\(oneDecimal(value)) \(unit)"
    }

    // MARK: 字节量级私有阶梯(diskRate 与 networkTotal 同源)

    /// 十进制 KB/MB/GB/TB 阶梯:字节量 → (数值, 单位)。磁盘速率(工单 05)
    /// 与网络累计(工单 06)共用同一套口径;速率层级里 TB 段物理不可达,入表
    /// 只为与累计同源(阶梯唯一出处)。
    private static func decimalByteScale(_ bytes: Double) -> (value: Double, unit: String) {
        if bytes >= 1_000_000_000_000 { return (bytes / 1_000_000_000_000, "TB") }
        if bytes >= 1_000_000_000 { return (bytes / 1_000_000_000, "GB") }
        if bytes >= 1_000_000 { return (bytes / 1_000_000, "MB") }
        return (bytes / 1_000, "KB")
    }

    /// 十进制一位小数拼串(十分位手算,不受系统区域影响)。
    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// 主窗口副标题(工单 P0.6-05):"Apple M4 Pro · 12 核 · 48 GB";芯片名未知则省略。
    static func hostSummary(chipName: String?, coreCount: Int, physicalMemoryBytes: UInt64) -> String {
        let parts = [chipName, "\(coreCount) 核", physicalMemoryTotal(physicalMemoryBytes)]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// 系统运行时长(弹窗头部,Vitals 的 "Up 6d 4h"):取最大两级单位,
    /// 不足 1 分钟按 1 分钟。
    static func systemUptime(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3600
        let minutes = total % 3600 / 60
        if days > 0 { return "已运行 \(days) 天 \(hours) 小时" }
        if hours > 0 { return "已运行 \(hours) 小时 \(minutes) 分" }
        return "已运行 \(max(minutes, 1)) 分钟"
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

    /// 电池时间估计(工单 02):分钟 → "3 小时 12 分"/"48 分钟"/"3 小时";
    /// nil / ≤0(IOPS 未给估计)= "—",不伪造。
    static func batteryTime(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "—" }
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
        }
        return "\(minutes) 分钟"
    }

    /// 功率(工单 02 电池卡):瓦 → "18.2 W"(一位小数;tenth 整数运算拼串,
    /// 不受系统区域小数点写法影响)。负值按 0 夹紧(方向语义由充电状态行表达)。
    static func watts(_ value: Double) -> String {
        let tenths = Int((max(0, value) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10) W"
    }

    /// CPU 秒数(工单 01 电池页能耗影响排行主值):秒 → "4.2 秒"(一位小数,
    /// 十分位手算拼串不随系统区域漂移,与 watts 同因;负值按 0 夹紧)。
    static func cpuSeconds(_ seconds: Double) -> String {
        "\(oneDecimal(max(0, seconds))) 秒"
    }

    /// 每秒唤醒次数(工单 01 能耗影响排行副文):"2.4 次/秒"。分母是约定
    /// 5 秒节拍,由聚合层折好传入,这里只管展示。
    static func wakeupsPerSecond(_ countPerSecond: Double) -> String {
        "\(oneDecimal(max(0, countPerSecond))) 次/秒"
    }

    /// 时长(工单 11 诊断报告"运行时长"):最大两级单位,负数(时钟回拨)按 0 夹紧。
    /// 与 systemUptime 同取级策略,但不带"已运行"前缀——报告里它只是字段值。
    static func duration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        let secs = total % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分 \(secs) 秒" }
        return "\(secs) 秒"
    }

    /// 毫秒(工单 11 诊断报告"平均轮耗时"):一位小数;过小但非零如实标下限,
    /// 不圆整成 0。十分位手算拼串,写法不随系统区域漂移(与 memory 同因)。
    static func milliseconds(_ seconds: TimeInterval) -> String {
        let value = seconds * 1_000
        if value == 0 { return "0 ms" }
        guard value >= 0.1 else { return "<0.1 ms" }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10) ms"
    }

    private static func basename(ofPath path: String?) -> String? {
        path.map { String($0.split(separator: "/").last ?? Substring($0)) }
    }
}
