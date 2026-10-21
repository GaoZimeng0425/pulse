@testable import PulseCore
import XCTest

/// 身份缓存决策单测(工单 10):命中 / exec·pid 复用失配 / cwd 低频校正 /
/// 消失裁剪四条策略边界,全部合成注入、零真实系统调用。
final class ProcessIdentityCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func identity(cwd: String? = "/tmp/proj", argv: [String] = ["/usr/bin/swift", "run"]) -> ProcessIdentity {
        ProcessIdentity(
            executablePath: "/usr/bin/swift",
            cwd: cwd,
            argv: argv
        )
    }

    // MARK: 命中

    func testFirstSightingMissesThenHits() {
        var cache = ProcessIdentityCache()
        XCTAssertNil(
            cache.identity(pid: 42, commandName: "swift", now: t0),
            "首见 pid 无缓存,必须重读"
        )
        cache.record(pid: 42, identity: identity(), commandName: "swift", at: t0)
        XCTAssertEqual(
            cache.identity(pid: 42, commandName: "swift", now: t0.addingTimeInterval(1)),
            identity(),
            "同 pid 同 p_comm 未过校正期 → 命中缓存"
        )
    }

    func testPIDsDoNotCrossContaminate() {
        var cache = ProcessIdentityCache()
        let mine = identity(cwd: "/tmp/a")
        let theirs = identity(cwd: "/tmp/b")
        cache.record(pid: 1, identity: mine, commandName: "a", at: t0)
        cache.record(pid: 2, identity: theirs, commandName: "b", at: t0)
        XCTAssertEqual(cache.identity(pid: 1, commandName: "a", now: t0), mine)
        XCTAssertEqual(cache.identity(pid: 2, commandName: "b", now: t0), theirs)
        XCTAssertNil(cache.identity(pid: 1, commandName: "b", now: t0), "p_comm 不匹配即失配")
    }

    // MARK: exec / pid 复用检测(p_comm 失配重读)

    func testCommandNameMismatchForcesRereadThenNewRecordWins() {
        var cache = ProcessIdentityCache()
        cache.record(pid: 7, identity: identity(argv: ["/bin/zsh"]), commandName: "zsh", at: t0)
        // exec(或 pid 复用)后 p_comm 变了 → 不命中,调用方重读。
        XCTAssertNil(
            cache.identity(pid: 7, commandName: "node", now: t0.addingTimeInterval(1)),
            "p_comm 变化必须立即重读,不得沿用旧身份"
        )
        let execd = identity(cwd: "/tmp/node", argv: ["/usr/local/bin/node", "server.js"])
        cache.record(pid: 7, identity: execd, commandName: "node", at: t0.addingTimeInterval(1))
        XCTAssertEqual(
            cache.identity(pid: 7, commandName: "node", now: t0.addingTimeInterval(2)),
            execd,
            "exec 重读后以新身份覆盖旧缓存(后写为准)"
        )
    }

    // MARK: cwd 低频校正(60s 到期重读)

    func testRefreshIntervalBoundsStaleness() {
        var cache = ProcessIdentityCache()
        cache.record(pid: 9, identity: identity(), commandName: "swift", at: t0)
        // 59.9s:仍在校正期内 → 命中。
        XCTAssertNotNil(cache.identity(pid: 9, commandName: "swift", now: t0.addingTimeInterval(59.9)))
        // 满 60s:过期 → 未命中,触发校正重读(左闭右开:恰在边界即重读)。
        XCTAssertNil(
            cache.identity(pid: 9, commandName: "swift", now: t0.addingTimeInterval(60)),
            "校正期一满必须重读,cwd 漂移的可见上界即 refreshInterval"
        )
        // 校正回填后周期重启。
        cache.record(
            pid: 9,
            identity: identity(cwd: "/tmp/elsewhere"),
            commandName: "swift",
            at: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(
            cache.identity(pid: 9, commandName: "swift", now: t0.addingTimeInterval(119.9)),
            identity(cwd: "/tmp/elsewhere"),
            "校正后的新 cwd 在下一周期内生效"
        )
    }

    func testRefreshAppliesToChangedCwdOnlyViaReread() {
        // 低频校正语义:期内 cwd 即便真实变更也沿用缓存(可见上界 60s),
        // 由到期重读自然校正——本用例钉住"期内不重读"这一取舍本身。
        var cache = ProcessIdentityCache()
        cache.record(pid: 5, identity: identity(cwd: "/tmp/old"), commandName: "swift", at: t0)
        XCTAssertEqual(
            cache.identity(pid: 5, commandName: "swift", now: t0.addingTimeInterval(30)),
            identity(cwd: "/tmp/old"),
            "校正期内沿用缓存,不做 cwd 失配检测(检测与重读同价)"
        )
    }

    // MARK: 消失裁剪(pid 复用防线)

    func testPruneDropsVanishedPIDsKeepsSurvivors() {
        var cache = ProcessIdentityCache()
        cache.record(pid: 1, identity: identity(), commandName: "a", at: t0)
        cache.record(pid: 2, identity: identity(), commandName: "b", at: t0)
        cache.prune(keeping: [2])
        XCTAssertNil(cache.identity(pid: 1, commandName: "a", now: t0), "消失的 pid 逐出缓存")
        XCTAssertEqual(cache.identity(pid: 2, commandName: "b", now: t0), identity(), "存活者不受影响")
        cache.prune(keeping: [])
        XCTAssertNil(cache.identity(pid: 2, commandName: "b", now: t0), "全量裁剪后缓存清空")
    }

    func testPrunedPIDReuseCannotResurrectStaleIdentity() {
        // pid 复用双保险的第二道:即使裁剪间隙里 pid 被复用,p_comm 比对也拦住旧身份。
        var cache = ProcessIdentityCache()
        cache.record(pid: 100, identity: identity(cwd: "/tmp/old-owner"), commandName: "python3", at: t0)
        cache.prune(keeping: []) // 旧主退场,缓存清空
        cache.record(
            pid: 100,
            identity: identity(cwd: "/tmp/new-owner"),
            commandName: "ruby",
            at: t0.addingTimeInterval(1)
        )
        XCTAssertNil(
            cache.identity(pid: 100, commandName: "python3", now: t0.addingTimeInterval(2)),
            "复用后 p_comm 已变,旧身份不可命中"
        )
        XCTAssertEqual(
            cache.identity(pid: 100, commandName: "ruby", now: t0.addingTimeInterval(2)),
            identity(cwd: "/tmp/new-owner")
        )
    }
}
