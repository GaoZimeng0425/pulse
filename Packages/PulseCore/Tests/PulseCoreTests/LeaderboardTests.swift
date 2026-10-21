@testable import PulseCore
import XCTest

/// 榜单内核(架构审查高3,纯函数):组卡榜单 / 模块排行 / 进程表 meter / 归组引擎
/// 共用的唯一排序与榜首口径——按值降序、同值身份升序(跨采样轮稳定)、
/// 榜首 = 最大值(meter 归一分母)。各站点的零值行口径不在内核,由站点各自钉。
final class LeaderboardTests: XCTestCase {
    /// 夹具条目:身份 + 读数(Double 口径,如 CPU% / 速率)。
    private struct Entry: Equatable {
        let id: String
        let value: Double
    }

    // MARK: ranked

    func testRankedOrdersByValueDescending() {
        let entries = [
            Entry(id: "b", value: 30),
            Entry(id: "a", value: 50),
            Entry(id: "c", value: 10),
        ]
        let ranked = Leaderboard.ranked(entries, by: \.value, id: \.id)
        XCTAssertEqual(ranked.map(\.id), ["a", "b", "c"])
    }

    /// 同值次键 = 身份升序:并列者的相对位置不随输入序漂移(跨采样轮稳定)。
    func testEqualValuesBreakTiesByIdentityAscending() {
        let entries = [
            Entry(id: "d", value: 20),
            Entry(id: "c", value: 20),
            Entry(id: "b", value: 50),
            Entry(id: "a", value: 20),
        ]
        let ranked = Leaderboard.ranked(entries, by: \.value, id: \.id)
        XCTAssertEqual(ranked.map(\.id), ["b", "a", "c", "d"])
    }

    /// 结果与输入序无关:同一组读数的任意排列(含并列)都排出同一张榜。
    func testRankingIsIndependentOfInputOrder() {
        let entries = [
            Entry(id: "d", value: 20),
            Entry(id: "c", value: 20),
            Entry(id: "b", value: 50),
            Entry(id: "a", value: 20),
        ]
        let orders = permutations(of: entries)
        XCTAssertEqual(orders.count, 24)
        for order in orders {
            XCTAssertEqual(
                Leaderboard.ranked(order, by: \.value, id: \.id).map(\.id),
                ["b", "a", "c", "d"],
                "输入序 \(order.map(\.id))"
            )
        }
    }

    /// 整数读数(内存字节 UInt64)与整数身份(pid)同一口径;内核不剔除零值——
    /// 零值行去留是站点口径。
    func testRanksUInt64ValuesWithPIDIdentityAndKeepsZeroRows() {
        let entries: [(pid: pid_t, bytes: UInt64)] = [
            (30, 4_000_000_000),
            (12, 9_000_000_000),
            (21, 0),
            (7, 4_000_000_000),
        ]
        let ranked = Leaderboard.ranked(entries, by: \.bytes, id: \.pid)
        XCTAssertEqual(ranked.map(\.pid), [12, 7, 30, 21])
    }

    func testEmptyInputRanksEmpty() {
        XCTAssertTrue(Leaderboard.ranked([Entry](), by: \.value, id: \.id).isEmpty)
    }

    // MARK: leader

    /// 榜首 = 最大值 = 榜单头名的读数(meter 满条的那一行)。
    func testLeaderIsTheMaximumValue() {
        let entries = [
            Entry(id: "a", value: 12.5),
            Entry(id: "b", value: 445.2),
            Entry(id: "c", value: 89.0),
        ]
        XCTAssertEqual(Leaderboard.leader(entries, by: \.value), 445.2)
        XCTAssertEqual(Leaderboard.ranked(entries, by: \.value, id: \.id).first?.value, 445.2)

        let bytes: [UInt64] = [4_000_000_000, 9_000_000_000, 0]
        XCTAssertEqual(Leaderboard.leader(bytes, by: { $0 }), 9_000_000_000)
    }

    /// 空榜(首轮采样前 / 全部被站点过滤掉):榜首 = 零,Double 与 UInt64 同。
    func testLeaderOfEmptyInputIsZero() {
        XCTAssertEqual(Leaderboard.leader([Entry](), by: \.value), 0)
        XCTAssertEqual(Leaderboard.leader([UInt64](), by: { $0 }), 0)
    }

    /// 全零读数(空载):榜首为零,meter 归一一律 0——不画填充,也不除零。
    func testAllZeroLeaderYieldsZeroMeterWithoutDividingByZero() {
        let entries = [Entry(id: "a", value: 0), Entry(id: "b", value: 0)]
        let leader = Leaderboard.leader(entries, by: \.value)
        XCTAssertEqual(leader, 0)
        for entry in entries {
            XCTAssertEqual(MeterNormalization.fraction(entry.value, leader: leader), 0)
        }
    }

    // MARK: 夹具工具

    /// 全排列(n! 个,夹具规模 ≤ 4)。
    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(of: rest).map { [head] + $0 }
        }
    }
}
