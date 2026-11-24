import CoreGraphics
import Foundation

// 历史曲线悬停(工单 history-hover/01):x → 桶序号反算与最近非空点吸附,
// 纯函数可测(ChartHoverGeometry 同族);视图层(HistoryCurveView)只做接线
// 与浮层,映射口径与绘制同式(桶中心 x=(i+0.5)·width/count)。

public enum HistoryCurveHover {
    /// 悬停 x → 桶序号:绘制同式的反算,越界钳到边界桶(悬停越出图缘不炸)。
    public static func bucketIndex(atX x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let raw = x / width * CGFloat(count) - 0.5
        return min(max(Int(raw.rounded()), 0), count - 1)
    }

    /// 锚桶最近的非空桶:查读数要有数——空桶(曲线断线处)吸到最近有数据的
    /// 点,竖线画在吸附点上即自明读的是哪个点;两侧等距取更早的(确定性);
    /// 全空返回 nil(整条无数据不给悬停读数,不造数)。
    public static func nearestFilled(anchor: Int, values: [Double?]) -> Int? {
        guard !values.isEmpty else { return nil }
        let clamped = min(max(anchor, 0), values.count - 1)
        if values[clamped] != nil {
            return clamped
        }
        for distance in 1 ... values.count {
            let left = clamped - distance
            let right = clamped + distance
            if left >= 0, values[left] != nil {
                return left
            }
            if right < values.count, values[right] != nil {
                return right
            }
        }
        return nil
    }
}

// MARK: - 端点锚定网格(主卡面积图,history-hover/02)

public extension HistoryCurveHover {
    /// 主卡面积图的反算:x = i/(count-1)·width(首尾点贴两缘,与历史页的
    /// 桶中心式不同——两图 x 几何不同构,反算各写各的,别硬套)。
    static func edgeIndex(atX x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1, width > 0 else { return 0 }
        let raw = x / width * CGFloat(count - 1)
        return min(max(Int(raw.rounded()), 0), count - 1)
    }

    /// 槽序号 → 真实数据窗内序号:主卡图右对齐,左端 paddingCount 个槽是
    /// 2% 垫底假点(不是读数)——垫底槽返回 nil,悬停不出读数不编数。
    static func windowIndex(forSlot slot: Int, paddingCount: Int) -> Int? {
        slot >= paddingCount ? slot - paddingCount : nil
    }
}

// MARK: - 主卡面积图悬停取值(history-hover/02)

public extension HistoryCurveHover {
    /// 主卡面积图一个悬停槽的真实读数与采样时刻。
    struct EdgeHoverSample: Equatable, Sendable {
        public let value: Double
        public let time: Date

        public init(value: Double, time: Date) {
            self.value = value
            self.time = time
        }
    }

    /// 槽序号 → 悬停样本;nil = 垫底槽 / 时刻轴与值长度不齐 / 无数据(不出读数)。
    /// 视图取悬停读数的**唯一出口**:实犯(2026-11-24)是视图直接下标
    /// `values.suffix(n)`——那是 ArraySlice,下标从 values.count − n 起而非 0,
    /// 满环后拿 0 起的槽序号去取会往前错位(前 4 槽还取不到)。这里物化成
    /// 0 起数组再取,值与时刻同一下标出自同一次换窗。
    static func edgeHoverSample(
        values: [Double],
        times: [Date],
        slot: Int,
        pointCount: Int
    ) -> EdgeHoverSample? {
        guard !values.isEmpty, values.count == times.count else { return nil }
        let padding = pointCount - min(values.count, pointCount)
        guard let index = windowIndex(forSlot: slot, paddingCount: padding) else { return nil }
        let window = Array(values.suffix(pointCount))
        let timeWindow = Array(times.suffix(pointCount))
        guard window.indices.contains(index), timeWindow.indices.contains(index) else { return nil }
        return EdgeHoverSample(value: window[index], time: timeWindow[index])
    }
}
