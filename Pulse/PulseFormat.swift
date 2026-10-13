import Foundation

/// 纯显示格式化接缝:组卡与菜单栏的数字文案统一从这里出。
/// 无 OS 依赖,可单测(spec 测试决策:纯逻辑才测,UI 不写单元测试)。
enum PulseFormat {
    /// 百分比 → "42%":四舍五入到整数。组 CPU% 可超过 100("445%"),系统 CPU 负载 0–100。
    static func cpuPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
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
}
