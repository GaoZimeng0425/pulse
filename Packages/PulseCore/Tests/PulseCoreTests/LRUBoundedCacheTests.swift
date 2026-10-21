@testable import PulseCore
import XCTest

/// 有界 LRU(菜单栏徽标渲染缓存的记账与淘汰规则;评审修复:徽标文案逐轮变新键,
/// 缓存必须有界)。
final class LRUBoundedCacheTests: XCTestCase {
    /// 容量上界:插入超过容量,最旧键被淘汰,条数不再增长。
    func testLRUCacheEvictsOldestBeyondCapacity() {
        var cache = LRUBoundedCache<String, Int>(capacity: 3)
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            cache.insert(index, forKey: key)
        }
        XCTAssertEqual(cache.order, ["b", "c", "d"], "容量 3 时最旧的 a 被挤出")
        XCTAssertNil(cache.hit("a"))
        XCTAssertEqual(cache.hit("d"), 3)
    }

    /// 命中即续命:被访问的键挪到最新,淘汰顺位让给真正最旧的键。
    func testLRUCacheHitRefreshesRecency() {
        var cache = LRUBoundedCache<String, Int>(capacity: 3)
        for (index, key) in ["a", "b", "c"].enumerated() {
            cache.insert(index, forKey: key)
        }
        XCTAssertEqual(cache.hit("a"), 0, "命中返回值")
        cache.insert(9, forKey: "d")
        XCTAssertEqual(cache.order, ["c", "a", "d"], "a 因命中续命,b 成为最旧被挤出")
        XCTAssertNil(cache.hit("b"))
        XCTAssertEqual(cache.hit("a"), 0)
        XCTAssertEqual(cache.hit("c"), 2, "c 未被命中过但仍未到淘汰顺位")
    }

    /// 重复插入同键:更新值且不产生重复序位。
    func testLRUCacheReinsertUpdatesWithoutDuplicates() {
        var cache = LRUBoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(3, forKey: "a")
        XCTAssertEqual(cache.order, ["b", "a"])
        XCTAssertEqual(cache.hit("a"), 3, "同键再插更新值")
    }
}
