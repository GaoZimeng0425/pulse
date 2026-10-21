import Foundation

// MARK: - 榜单内核(arch-review-2026-10-18/01 高3)

/// 榜单内核(arch-review-2026-10-18/01 高3):按值降序、同值身份升序(跨采样轮稳定)、榜首 = 最大值(meter 归一分母)。
///
/// 组卡榜单(MetricTabContent)、模块排行(ModuleRankingAggregator)、进程表 meter
/// (MainWindowView)与归组引擎输出序(GroupingEngine)共用这一份口径——此前各自
/// 手写、一致性只靠互不相干的测试各钉各的。单测见 LeaderboardTests。
///
/// 内核**不过滤零值**:零值口径随站点而异(模块排行剔除零值行、组 tab 保留零值组、
/// 内存环形分段剔除零字节组),由各站点在调用前自行处理。
public enum Leaderboard {
    /// 榜单序:值降序;同值按身份升序破平——身份全序即结果与输入序无关,
    /// 同一组读数跨采样轮排出同一张榜。
    public static func ranked<Item>(
        _ items: some Sequence<Item>,
        by value: (Item) -> some Comparable,
        id: (Item) -> some Comparable
    ) -> [Item] {
        items.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
            return id(lhs) < id(rhs)
        }
    }

    /// 榜首 = 读数最大值(= `ranked` 头名的读数),meter 归一的分母;
    /// 空榜为 `.zero`——交 `MeterNormalization.fraction` 时榜首 ≤ 0 一律出 0,不除零。
    public static func leader<Item, Value: Comparable & AdditiveArithmetic>(
        _ items: some Sequence<Item>,
        by value: (Item) -> Value
    ) -> Value {
        items.map(value).max() ?? .zero
    }
}
