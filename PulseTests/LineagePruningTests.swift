import XCTest
@testable import Pulse

/// 出生登记修剪(arch-review-2026-10-18/04):登记表只留「还在的进程 + 它们父链上的
/// 全部祖先」——断链归组靠的正是已死祖先(cargo)的记录;其余死进程的记录丢掉,登记表
/// 规模随活进程数而不是随运行时长增长(此前 4 天涨到近 10 万条)。
final class LineagePruningTests: XCTestCase {
    private func registry(_ links: [(pid_t, pid_t)]) -> LineageRegistry {
        var registry = LineageRegistry()
        for (pid, parent) in links {
            registry.register(pid: pid, entry: LineageRegistry.Entry(
                parentPID: parent, identity: ProcessIdentity(executablePath: "/bin/p\(pid)")
            ))
        }
        return registry
    }

    func testKeepsLivePIDsAndTheirWholeAncestorChain() {
        // 11 → 12(已死)→ 100(活);200(已死,无活后代);300(活,父 1 无记录)。
        let full = registry([(11, 1), (12, 11), (100, 12), (200, 11), (300, 1)])

        let pruned = full.pruned(keeping: [100, 300])

        XCTAssertEqual(pruned.entries.keys.sorted(), [11, 12, 100, 300])
    }

    func testParentCycleTerminates() {
        // 记录损坏成环(pid 复用交错):走链必须停得下来。
        let cyclic = registry([(5, 6), (6, 5), (7, 1)])

        XCTAssertEqual(cyclic.pruned(keeping: [5]).entries.keys.sorted(), [5, 6])
    }

    func testKeptPIDWithoutRecordIsIgnored() {
        XCTAssertEqual(registry([(1, 0)]).pruned(keeping: [99]).entries.keys.sorted(), [])
    }
}
