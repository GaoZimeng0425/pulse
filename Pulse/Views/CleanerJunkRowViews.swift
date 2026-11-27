import AppKit
import PulseCore
import SwiftUI

// 清单行家族:行(JunkRow)、档位 chip(TierChip)、在用 chip(InUseChip)、年龄文案(JunkAgeText)、
// 标志小标(JunkFlagChips)。

// MARK: 行

struct JunkRow: View {
    let candidate: JunkCandidate
    let leader: Int64
    let accent: Color
    let isSelected: Bool
    /// 在用保护原因(nil = 不在用)。在用行灰显、锁代替勾选、chip 换「在用保护 · 原因」;
    /// 点行不勾选,右键菜单照常。
    let inUseReasons: CleanActivityReason?
    let disabled: Bool
    let onToggle: () -> Void
    let onExclude: () -> Void
    /// 两种条目形态由它切换:项目大卡内的子项行(`true`)只缩进、不套小卡;
    /// 工具缓存这类组的条目行(`false`)是一张独立小卡。
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
            // 独立小卡:常态抬升底,选中 = 强调色染底。
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? accent.opacity(0.12) : Surface.cardHigh)
        }
    }

    private var rowContent: some View {
        HStack(spacing: CleanerListMetrics.spacing) {
            if isInUse {
                Image(systemName: "lock.fill")
                    .font(.system(size: IconSize.inline))
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
                JunkTitleLine(
                    title: candidate.title,
                    flags: candidate.flags,
                    fontSize: CleanerListMetrics.titleFontSize
                )
                // 副标一律显示路径:同名的 node_modules / build 只靠路径区分。档位说明
                // (rationale)每行同文案、零信息量,不上副标,降为行悬停;档位本身由
                // TierChip 的悬停自解释。
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

/// 清理清单「多久没动」的人话:行副标用 idle(「N 天未动」),大卡头排用 ago(「N 天前
/// 动过」),两者同档粒度(天 / 月 / 年)。别改成对过去时刻取 `timeIntervalSinceNow`:
/// 那是负数,会全落进「今天动过」。
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

/// 候选的条目标志小标(GLOSSARY「条目标志」):「需要管理员权限」「未识别」,
/// 挤在名称后。清单行、确认清单、清理历史三处同一实现——文案与悬停说明取自标志本身,
/// 这里只管形。三级墨色灰:客观状态,不是警示(同在用保护 chip);没有标志时不出。
struct JunkFlagChips: View {
    let flags: [JunkCandidateFlag]

    var body: some View {
        ForEach(flags, id: \.rawValue) { flag in
            ChipView(text: flag.title, tint: Surface.inkTertiary, profile: .inline, help: flag.help)
        }
    }
}

/// 「标题 + 标志小标」一行(清单行、确认清单、清理历史三处同一实现):标题单行,
/// 小标不被压缩——放不下时截标题,不截标志。名称与小签的间距 6 同智能体页名称后的行内小签。
struct JunkTitleLine: View {
    let title: String
    let flags: [JunkCandidateFlag]
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .lineLimit(1)
            JunkFlagChips(flags: flags)
        }
    }
}

/// 安全档 chip(GLOSSARY「安全档」两态):可安全清理 → positive,先检查 → caution。
/// 这是删除安全语义,不是负载警示(那套映射在 StatusBadgeRules),只在清理页出。
struct TierChip: View {
    let tier: CleanSafetyTier

    private var tint: Color {
        // 「先检查」取档位专用的 caution 琥珀,不取 warning——warning 是磁盘指标金的别名。
        tier == .safe ? Surface.positive : Surface.caution
    }

    var body: some View {
        ChipView(
            text: tier.title,
            tint: tint,
            profile: .regular,
            // 档位人话挂在 chip 悬停:chip 自己解释自己,不用翻 GLOSSARY;行悬停另有
            // 该条规则的具体 rationale。
            help: tier == .safe
                ? "白名单担保过:重建即可或无个人数据,删了不影响使用"
                : "大概率能删,但删前看一眼——这类目录可能藏着要保留的东西(如 build 下可能有源码、JetBrains 缓存含 Local History)。安全规则:永不进自动勾选,须逐个手勾"
        )
    }
}
