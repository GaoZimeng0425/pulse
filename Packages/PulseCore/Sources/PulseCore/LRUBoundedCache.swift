import Foundation

/// 容量有界的 LRU 字典(纯逻辑):命中把键挪到最新,插入超容淘汰最旧。
/// 渲染器缓存的记账与淘汰规则单测钉在这里;值类型不设约束(NSImage 存取
/// 留在渲染器侧)。实现只有一张访问序表 + 一个字典,规模 ≤ 容量,线性
/// 移除即可,不值得上双向链表。
public struct LRUBoundedCache<Key: Hashable, Value> {
    public let capacity: Int
    private(set) var order: [Key] = []
    private var storage: [Key: Value] = [:]

    public init(capacity: Int) {
        precondition(capacity > 0, "LRU 容量必须为正")
        self.capacity = capacity
    }

    /// 命中读值(并把键记为最新);未命中返回 nil。
    public mutating func hit(_ key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// 插入/更新(键记为最新;超容淘汰最旧)。
    public mutating func insert(_ value: Value, forKey key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
