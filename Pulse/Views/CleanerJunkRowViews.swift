import AppKit
import PulseCore
import SwiftUI

// 清单行家族(行/档位 chip/在用 chip/年龄文案)——自 CleanerJunkViews 拆出(solid-split,纯搬运)。

// MARK: 行

struct JunkRow: View {
    let candidate: JunkCandidate
    let leader: Int64
    let accent: Color
    let isSelected: Bool
    /// 在用保护原因(nil = 不在用;05)。在用行灰显、锁代替勾选、chip 换「在用保护 · 原因」。
    let inUseReasons: CleanActivityReason?
    let disabled: Bool
    let onToggle: () -> Void
    let onExclude: () -> Void
    /// 项目产物行:住在项目大卡**内部**,只缩进不套小卡(2026-11-06 三次拍板:
    /// 「项目产物应该是一个大卡片,包含住子项!子项只有缩进!」);工具缓存行
    /// (`indented == false`)保持独立小卡。
    var indented: Bool = false

    private var isInUse: Bool {
        inUseReasons != nil
    }

    var body: some View {
        rowContent
            .padding(.leading, indented ? CleanerListMetrics.indentLeading : CleanerListMetrics.rowInset)
            .padding(.trailing, CleanerListMetrics.rowInset)
            .padding(
                .vertical,
                indented ? CleanerListMetrics.bareRowVerticalPadding : CleanerListMetrics.rowVerticalPadding
            )
            .opacity(isInUse ? 0.55 : 1)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                if !disabled, !isInUse {
                    onToggle()
                }
            }
            .contextMenu {
                Button("排除此目录(不再扫描、不再出现)") {
                    onExclude()
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                }
            }
            .help(isInUse ? "在用保护 · \(inUseReasons?.title ?? "")正在此项目——判定不缓存,删除前会重查" : candidate.rationale)
    }

    @ViewBuilder private var rowBackground: some View {
        if indented {
            // 卡内裸行:无卡底,选中给一抹强调色行底(卡里挑得出来)。
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.10))
            }
        } else {
            // 独立小卡:常态 card-hi 抬升底,选中 = 强调色 12% 染底。
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? accent.opacity(0.12) : Surface.cardHigh)
        }
    }

    private var rowContent: some View {
        HStack(spacing: CleanerListMetrics.spacing) {
            if isInUse {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .help("在用保护:该项目有进程活动,不参与本次清理")
            } else {
                CleanerCheckBox(state: isSelected ? .on : .off, disabled: disabled)
            }
            CategoryIconTile(
                symbolName: candidate.symbolName,
                // 08 色彩纪律:行图标中性灰(此前 safe=金 / checkFirst=金撞色难分)。
                color: Surface.inkTertiary,
                size: CleanerListMetrics.iconSize
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title)
                    .font(.system(size: CleanerListMetrics.titleFontSize, weight: .medium))
                    .lineLimit(1)
                // 副标一律显示路径(2026-11-06 用户实报:同名 node_modules/build 无法
                // 区分"是不是同一个目录")——rationale 每行同文案零信息量,降为悬停。
                Text(subtitle)
                    .font(.system(size: CleanerListMetrics.subFontSize))
                    .foregroundStyle(indented ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let reasons = inUseReasons {
                InUseChip(reasons: reasons)
            } else {
                TierChip(tier: candidate.tier)
            }
            MeterBar(
                fraction: MeterNormalization.fraction(Double(candidate.bytes), leader: Double(leader)),
                // 08 色彩纪律:大小条中性,强调色只留给页脚主按钮与选中态。
                tint: .secondary
            )
            .frame(width: CleanerListMetrics.meterWidth)
            Text(PulseFormat.memory(UInt64(max(0, candidate.bytes))))
                .font(.system(size: CleanerListMetrics.valueFontSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: CleanerListMetrics.valueWidth, alignment: .trailing)
        }
    }

    private var subtitle: String {
        var parts = [candidate.path]
        if candidate.isPartial {
            parts.append("部分扫描")
        }
        if let accountingNote = candidate.accountingNote {
            parts.append(accountingNote)
        }
        if candidate.projectName != nil {
            parts.append(ageText(now: Date().timeIntervalSince1970))
        }
        return parts.joined(separator: " · ")
    }

    /// 年龄人话(05 口径:项目内非产物文件的最后变动,含 git 活动;卸载残留 = 子树最新变动)。
    private func ageText(now: TimeInterval) -> String {
        guard let epoch = candidate.newestChangeEpoch else { return "年龄未知" }
        return JunkAgeText.idle(sinceEpoch: epoch, now: now)
    }
}

/// 清理清单「多久没动」的人话(行副标「N 天未动」/ 大卡头排「N 天前动过」,同档粒度:
/// 天 / 月 / 年)。2026-11-08 修:大卡头排曾用 `timeIntervalSinceNow`——对过去时刻为负,
/// 被 `<= 0` 分支全吞,恒显示「今天动过」。
enum JunkAgeText {
    static func idle(sinceEpoch epoch: Double, now: TimeInterval) -> String {
        let days = Int((now - epoch) / 86400)
        switch days {
        case ..<1: return "今天动过"
        case ..<30: return "\(days) 天未动"
        case ..<365: return "\(days / 30) 个月未动"
        default: return "\(days / 365) 年未动"
        }
    }

    static func ago(sinceEpoch epoch: Double, now: TimeInterval) -> String {
        let days = Int((now - epoch) / 86400)
        switch days {
        case ..<1: return "今天动过"
        case ..<30: return "\(days) 天前动过"
        case ..<365: return "\(days / 30) 个月前动过"
        default: return "\(days / 365) 年前动过"
        }
    }
}

/// 在用保护 chip(GLOSSARY「在用保护」):与 TierChip 同配方,三级墨色灰——
/// 不是「先检查」的警示琥珀(在用 = 客观状态,不是让用户小心的档位)。
struct InUseChip: View {
    let reasons: CleanActivityReason

    var body: some View {
        ChipView(text: "在用保护 · \(reasons.title)正在此项目", tint: Surface.inkTertiary, profile: .regular)
    }
}

/// 安全档 chip(GLOSSARY「安全档」两态):状态 chip 配方——胶囊、tint 14~16% 底 + 同色文字。
/// 可安全清理 → positive;先检查 → warning。这不是负载警示(那三处映射集中在
/// StatusBadgeRules),是删除安全语义,只在这里出。
struct TierChip: View {
    let tier: CleanSafetyTier

    private var tint: Color {
        // 08:「先检查」换 state-caution 琥珀(warning 是磁盘金别名,与页面 accent 撞色)。
        tier == .safe ? Surface.positive : Surface.caution
    }

    var body: some View {
        ChipView(
            text: tier.title,
            tint: tint,
            profile: .regular,
            // 档位人话(2026-11-06 用户实报「先检查是什么意思」):chip 自己解释自己,
            // 不用翻 GLOSSARY;行悬停另有该条规则的具体 rationale。
            help: tier == .safe
                ? "白名单担保过:重建即可或无个人数据,删了不影响使用"
                : "大概率能删,但删前看一眼——这类目录可能藏着要保留的东西(如 build 下可能有源码、JetBrains 缓存含 Local History)。安全规则:永不进自动勾选,须逐个手勾"
        )
    }
}
