import Foundation

// MARK: - 走势环(p2-review/06)

/// 走势环:定长窗口的最新值序列,append 溢出丢最旧。三处手写环
/// (GPU 利用率 / ANE 功率 / 网络速率)收成一个类型。分档单循环
/// (p2-review/06)后窗口为混排节拍——可见 5s / 不可见 30s——窗长按
/// "最近 N 个样本"计,不按墙钟;图表口径如实画,不跳点。
public struct TrendRing<Value: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var values: [Value] = []
    public let limit: Int

    public init(limit: Int) {
        self.limit = Swift.max(0, limit)
    }

    /// 追加一个样本;超限丢最旧。
    public mutating func append(_ value: Value) {
        guard limit > 0 else { return }
        values.append(value)
        if values.count > limit {
            values.removeFirst(values.count - limit)
        }
    }

    public var last: Value? {
        values.last
    }

    public var isEmpty: Bool {
        values.isEmpty
    }

    public var count: Int {
        values.count
    }
}
