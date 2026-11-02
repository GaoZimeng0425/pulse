import PulseCore
import SwiftUI

// MARK: - 排行截断(ranking-limit/01,用户拍板 2026-11-02:主窗口与弹窗同规则)

//
// 各排行(组排行「当前最忙」/ 模块排行「能耗影响 / 读写最多 / 每进程流量」)只列前
// `limit` 名,溢出由末行按宿主处理:弹窗「查看全部」跳主窗口并落地即展开(360pt 里不翻
// 长榜),主窗口「显示全部」原地展开 / 「收起」回到前 N(它没别处可跳)。
// 为什么两处都截:行是同一个 SwiftUI 组件,滚动逐行渲染,行越多越贵——弹窗换原生列表后
// 快速翻百行仍 10–22%(native-list 真机),主窗口容器是 LazyVStack 无行复用,按机制只贵不
// 便宜;弹窗 11-01 先截(popover-top20),主窗口 11-02 对齐(「直接经验复用」),两处成本封顶。
// 搜索命中(主窗口)不截:过滤本身已经收窄。

enum RankingOverflow {
    /// DESIGN.md `{layout.ranking-limit}`:两处排行的上限。
    static let limit = 20

    /// 末行行为(宿主定)。
    enum Action {
        /// 弹窗:跳主窗口(调用方带上卡 id,主窗口落地即展开该卡)。
        case jump(() -> Void)
        /// 主窗口:原地展开 / 收起,展开态由调用方持有(DashboardModel.expandedRankingIDs)。
        case expand(isExpanded: Bool, toggle: () -> Void)

        var isExpanded: Bool {
            switch self {
            case .jump: false
            case let .expand(isExpanded, _): isExpanded
            }
        }
    }

    /// 可见前缀与隐藏数:展开时全量(隐藏 0)。
    static func split<T>(_ items: [T], isExpanded: Bool) -> (shown: ArraySlice<T>, hidden: Int) {
        if isExpanded || items.count <= limit {
            return (items[...], 0)
        }
        return (items.prefix(limit), items.count - limit)
    }

    /// 末行数据面:总数不超上限时不画(展开态下榜单缩回上限内也不留一行孤零零的「收起」);
    /// 超出时按行为画「查看全部 / 显示全部(另 N 项)」或「收起」。
    static func rowModel(total: Int, action: Action) -> RankingOverflowRowModel? {
        guard total > limit else { return nil }
        return RankingOverflowRowModel(hiddenCount: action.isExpanded ? 0 : total - limit, action: action)
    }
}

/// 排行溢出策略(宿主定一次,各排行卡按卡 id 派生动作)。
enum RankingOverflowPolicy {
    /// 主窗口:原地展开,展开态按卡 id 存在模型里(切 tab 回到前 N;弹窗落地可预置)。
    case expandInPlace
    /// 弹窗:跳主窗口,带上卡 id。
    case jumpToMainWindow(open: (_ rankingID: String) -> Void)

    @MainActor
    func action(for rankingID: String, model: DashboardModel) -> RankingOverflow.Action {
        switch self {
        case .expandInPlace:
            .expand(isExpanded: model.expandedRankingIDs.contains(rankingID)) {
                model.toggleRankingExpansion(rankingID)
            }
        case let .jumpToMainWindow(open):
            .jump { open(rankingID) }
        }
    }
}

/// 截断末行的数据面:隐藏数 + 行为。
struct RankingOverflowRowModel {
    let hiddenCount: Int
    let action: RankingOverflow.Action
}

/// 排行截断后的末行:弹窗「查看全部(另 N 项)›」跳主窗口;主窗口「显示全部(另 N 项)⌄」
/// 原地展开,展开后「收起,只看前 20 名⌃」。字号 `{typography.caption}` 11 medium、
/// secondary 墨色;悬停底色同排行行(primary 5% + 圆角 8)。
struct RankingOverflowRow: View {
    let model: RankingOverflowRowModel
    let isCompact: Bool

    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: symbolName)
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, isCompact ? 7 : 9)
            .background(isHovering ? Color.primary.opacity(0.05) : Color.clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var label: String {
        switch model.action {
        case .jump:
            "查看全部(另 \(model.hiddenCount) 项)"
        case let .expand(isExpanded, _):
            isExpanded ? "收起,只看前 \(RankingOverflow.limit) 名" : "显示全部(另 \(model.hiddenCount) 项)"
        }
    }

    private var symbolName: String {
        switch model.action {
        case .jump: "chevron.right"
        case let .expand(isExpanded, _): isExpanded ? "chevron.up" : "chevron.down"
        }
    }

    private var help: String {
        switch model.action {
        case .jump: "在主窗口查看完整排行"
        case let .expand(isExpanded, _): isExpanded ? "收起到前 \(RankingOverflow.limit) 名" : "在本卡内展开完整排行"
        }
    }

    private func perform() {
        switch model.action {
        case let .jump(open): open()
        case let .expand(_, toggle): toggle()
        }
    }
}
