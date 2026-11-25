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
}

// MARK: - 主卡面积图定长窗口(chart-hover-partial,2026-11-25 用户拍板)

public extension HistoryCurveHover {
    /// 主卡面积图的一个点:值 + 采样时刻(补位点没有时刻 = nil)。
    struct EdgePoint: Equatable, Sendable {
        public let value: Double
        public let time: Date?

        public init(value: Double, time: Date?) {
            self.value = value
            self.time = time
        }
    }

    /// 定长窗口:取最近 `count` 个点;不足时**前面补 0**,补出来的点没有时刻。
    /// 图拿到的就是恰好 `count` 个点的 list,第 i 格 = list[i],悬停到哪格显示哪格——
    /// 视图里不再有「格子序号 ↔ 数据序号」的换算(旧的垫底换算曾被扣两次,
    /// 未满窗的 GPU / 磁盘图悬停全失)。时刻轴与值不等长 = 时刻全部缺省(不按序号猜)。
    /// 空输入返回空:没有任何读数时图只画网格,不画一条 0 线冒充数据。
    static func edgeWindow(values: [Double], times: [Date], count: Int) -> [EdgePoint] {
        guard !values.isEmpty, count > 0 else { return [] }
        let aligned = times.count == values.count
        let recentValues = Array(values.suffix(count))
        let recentTimes: [Date?] = aligned ? Array(times.suffix(count)) : recentValues.map { _ in nil }
        let padding = count - recentValues.count
        let padded = Array(repeating: EdgePoint(value: 0, time: nil), count: padding)
        return padded + zip(recentValues, recentTimes).map { EdgePoint(value: $0, time: $1) }
    }
}
