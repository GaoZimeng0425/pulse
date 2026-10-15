import SwiftUI

// MARK: - 状态徽章(工单 P0.6-04):✓正常 / 高负载 chip 语言

/// 状态徽章语言(工单 P0.6-04):两态 chip——✓正常(空载绿)与 高负载(警示)。
/// 阈值判定在 StatusBadgeRules(纯逻辑,单测钉边界);外观在 StatusBadgeChip
/// (预览 + 手动验收,spec 测试决策)。
enum StatusBadge: Equatable, Sendable {
    /// ✓ 正常:系统空载(参考文档 §2.2 "✓ Normal" 绿 chip 同款)。
    case normal
    /// 高负载:系统负载越红线,或组 CPU% 超 100%。
    case high

    /// chip 文案(中文)。
    var title: String {
        switch self {
        case .normal: "正常"
        case .high: "高负载"
        }
    }

    /// chip 前置符号:✓ / 警示三角,互异可辨(单测断言)。
    var symbolName: String {
        switch self {
        case .normal: "checkmark"
        case .high: "exclamationmark.triangle.fill"
        }
    }
}

/// 徽章阈值规则(纯逻辑,单测见 StatusBadgeTests)。
/// 系统 = 三档语言(空载 ✓正常 / 高负载 / 中间静默);组卡只挂高负载警示——
/// 组级 ✓正常 会满屏绿 chip,与"徽章 = 值得注意的偏差"的语义冲突。
enum StatusBadgeRules {
    /// 组 CPU% 高负载线:**> 100%** 才算(恰好 100% = 单核满载,是正常可达值,不算;
    /// 工单钉死的边界)。GLOSSARY:组 CPU% 单核为 100%,445% ≈ 4.5 个核满载。
    static let groupHighLoadCPUThreshold: Double = 100
    /// 系统空载线:负载 < 30% 挂 ✓正常(恰 30% 落入静默档)。
    static let systemIdleLoadThreshold: Double = 30
    /// 系统高负载线:> 70%,与菜单栏变红同一口径(SystemMonitor.redThreshold,
    /// 字面量直写避免 MainActor 隔离引用;两处相等由单测 @MainActor 断言钉死)。
    static let systemHighLoadThreshold: Double = 70

    /// 系统负载徽章:> 70% → .high;< 30% → .normal;中间静默(nil,不挂 chip)。
    static func systemBadge(load: Double) -> StatusBadge? {
        if load > systemHighLoadThreshold { return .high }
        if load < systemIdleLoadThreshold { return .normal }
        return nil
    }

    /// 组卡徽章:组 CPU% > 100% → .high,否则不挂。
    static func groupBadge(cpuPercent: Double) -> StatusBadge? {
        cpuPercent > groupHighLoadCPUThreshold ? .high : nil
    }
}

/// 状态 chip(参考文档 §1.1 chip 派生公式:底 = 色 14% + 同色文字;圆角 7px
/// 参照 §1.3 .badge):✓正常 绿、高负载 警示红(与菜单栏变红同一警示语言)。
struct StatusBadgeChip: View {
    let badge: StatusBadge

    /// 状态语义色。正常 = 绿(Vitals "✓ Normal" 同款);高负载 = 红——不是孤儿橙,
    /// 孤儿橙专属"来历不明"语义(GLOSSARY),高负载是另一码事。
    private var tint: Color {
        switch badge {
        case .normal: .green
        case .high: .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.symbolName)
                .font(.system(size: 9, weight: .bold))
            Text(badge.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 7))
        // 卡内名称行空间紧张时,名称截断、chip 不缩不折。
        .fixedSize()
        .accessibilityLabel(badge == .normal ? "状态正常" : "状态高负载")
    }
}

#Preview("状态 chip") {
    VStack(alignment: .leading, spacing: 12) {
        StatusBadgeChip(badge: .normal)
        StatusBadgeChip(badge: .high)
        HStack(spacing: 6) {
            Text("octok-client @ skill-manage-read-and-index")
                .lineLimit(1)
            StatusBadgeChip(badge: .high)
        }
        .font(.subheadline.weight(.semibold))
        .frame(width: 280, alignment: .leading)
    }
    .padding(16)
}
