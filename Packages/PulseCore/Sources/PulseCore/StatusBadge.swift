import Foundation

// MARK: - 状态徽章语言(工单 P0.6-04 语义,评审 F1 并入 05 chip 实现)

/// 状态徽章:两态语言——✓正常(空载)与 高负载(警示)。外观不复刻 04 的
/// 独立组件,统一映射到 05 的 `MetricCardChip`(经 `MetricChipView` 渲染)——
/// 徽章 = 值得注意的偏差,现役于指标卡大数字旁(系统负载)。排行行的组高负载
/// 改由行尾 CPU 数值红字 + 最忙进程名 chip 表达(2026-10-30 用户拍板),
/// 阈值仍从本规则取——判定只有这一份。
public enum StatusBadge: Equatable, Sendable {
    /// ✓ 正常:系统空载(参考文档 §2.2 "✓ Normal" 绿 chip 同款)。
    case normal
    /// 高负载:系统负载越红线,或组 CPU% 超 100%。
    case high
}

/// 徽章阈值规则(纯逻辑,单测见 StatusBadgeTests)。
/// 系统 = 三档语言(空载 ✓正常 / 高负载 / 中间静默);组卡只挂高负载警示——
/// 组级 ✓正常 会满屏绿 chip,与"徽章 = 值得注意的偏差"的语义冲突。
public enum StatusBadgeRules {
    /// 组 CPU% 高负载线:**> 100%** 才算(恰好 100% = 单核满载,是正常可达值,不算;
    /// 工单钉死的边界)。GLOSSARY:组 CPU% 单核为 100%,445% ≈ 4.5 个核满载。
    public static let groupHighLoadCPUThreshold: Double = 100
    /// 系统空载线:负载 < 30% 挂 ✓正常(恰 30% 落入静默档)。
    public static let systemIdleLoadThreshold: Double = 30
    /// 系统高负载线:> 70%,与菜单栏变红同一口径(SystemMonitor.redThreshold,
    /// 字面量直写避免 MainActor 隔离引用;两处相等由 app 侧 StatusBadgeChipTests 的 @MainActor 断言钉死)。
    public static let systemHighLoadThreshold: Double = 70

    /// 系统负载徽章:> 70% → .high;< 30% → .normal;中间静默(nil,不挂 chip)。
    public static func systemBadge(load: Double) -> StatusBadge? {
        if load > systemHighLoadThreshold {
            return .high
        }
        if load < systemIdleLoadThreshold {
            return .normal
        }
        return nil
    }

    /// 组卡徽章:组 CPU% > 100% → .high,否则不挂。
    public static func groupBadge(cpuPercent: Double) -> StatusBadge? {
        cpuPercent > groupHighLoadCPUThreshold ? .high : nil
    }

    /// 组高负载时组内最忙进程的显示名(组行红色 chip,2026-10-30 用户拍板):
    /// 阈值与数值标红同源;引擎契约组内进程按 CPU% 降序,首个即最忙。未越线或空组 → nil。
    public static func groupHotProcessName(_ group: ProcessGroup) -> String? {
        guard groupBadge(cpuPercent: group.cpuPercent) != nil, let top = group.processes.first else {
            return nil
        }
        return PulseFormat.processName(executablePath: top.executablePath, argv: top.argv, pid: top.pid)
    }
}
