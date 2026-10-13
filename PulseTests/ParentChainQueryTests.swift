import XCTest
@testable import Pulse

/// 接缝:ParentChainQuery 父链面包屑(工单 06)。合成进程树驱动的纯查询:
/// 从进程自身沿活链追溯到有归属的祖先(App 归属的 bundle 祖先 / launchd),
/// 活链断裂(中间父已死 / 被重挂 launchd)时回查出生登记。
/// 期望名序全部为独立字面量(验收锚点:"rustc ← cargo ← node ← Zcode")。
final class ParentChainQueryTests: XCTestCase {
    // MARK: 夹具:验收锚点门禁树

    private func zcode() -> RawProcess {
        RawProcess(
            pid: 10,
            parentPID: 1,
            executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode"
        )
    }

    private func node() -> RawProcess {
        RawProcess(
            pid: 11,
            parentPID: 10,
            executablePath: "/usr/local/bin/node",
            argv: ["node", "server.js"]
        )
    }

    private func cargo() -> RawProcess {
        RawProcess(
            pid: 12,
            parentPID: 11,
            executablePath: "/Users/x/.cargo/bin/cargo",
            argv: ["cargo", "test"]
        )
    }

    private func rustc(parentPID: pid_t = 12) -> RawProcess {
        RawProcess(
            pid: 100,
            parentPID: parentPID,
            executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
            argv: ["rustc", "--crate-name", "octok"]
        )
    }

    private func launchd() -> RawProcess {
        RawProcess(pid: 1, parentPID: 0, executablePath: "/sbin/launchd")
    }

    private func snapshot(_ processes: [RawProcess]) -> ProcessSnapshot {
        ProcessSnapshot(takenAt: Date(timeIntervalSinceReferenceDate: 1_000), processes: processes)
    }

    /// 历史快照(全树)逐轮登记出的出生表:与采样管线同构。
    private func lineage(after snapshots: [ProcessSnapshot]) -> LineageRegistry {
        snapshots.reduce(LineageRegistry()) { $0.registeringBirths(in: $1) }
    }

    private func names(for pid: pid_t, snapshot: ProcessSnapshot, lineage: LineageRegistry) -> [String] {
        ParentChainQuery.breadcrumbNames(for: pid, in: snapshot, lineage: lineage)
    }

    // MARK: 活链

    /// 验收锚点形态:全树存活时从 rustc 一路走到 bundle 祖先 Zcode,含自身、止于归属。
    func testLiveChainWalksFromSelfToBundleAncestor() {
        let current = snapshot([zcode(), node(), cargo(), rustc()])

        XCTAssertEqual(names(for: 100, snapshot: current, lineage: LineageRegistry()),
                       ["rustc", "cargo", "node", "Zcode"])
        XCTAssertEqual(names(for: 11, snapshot: current, lineage: LineageRegistry()),
                       ["node", "Zcode"])
    }

    /// 宿主 App 自身:出生即在 launchd 之下 → 面包屑止于 launchd(后台服务口径)。
    func testChainBornUnderLaunchdEndsWithLaunchd() {
        let current = snapshot([launchd(), zcode()])

        XCTAssertEqual(names(for: 10, snapshot: current, lineage: lineage(after: [current])),
                       ["Zcode", "launchd"])
    }

    // MARK: 断链回查出生登记

    /// 中间父(node/cargo)已死、宿主也已不在快照:整条链只能靠出生记录重建,
    /// bundle 终点与名字都来自记录里的可执行路径。
    func testBrokenLiveChainIsRebuiltFromBirthRecords() {
        let history = snapshot([zcode(), node(), cargo(), rustc()])
        // 现状:只剩 rustc,父 pid 指向已死的 cargo(未重挂)。
        let current = snapshot([rustc()])

        XCTAssertEqual(
            names(for: 100, snapshot: current, lineage: lineage(after: [history])),
            ["rustc", "cargo", "node", "Zcode"]
        )
    }

    /// rustc 被重挂 launchd(现父=1,且 launchd 活着):出生记录的亲父优先于
    /// 现场挂靠,面包屑仍是出生链而非"← launchd"。
    func testReparentedToLiveLaunchdPrefersBirthChainOverLiveReparenting() {
        let history = snapshot([zcode(), node(), cargo(), rustc()])
        let current = snapshot([launchd(), zcode(), rustc(parentPID: 1)])

        XCTAssertEqual(
            names(for: 100, snapshot: current, lineage: lineage(after: [history])),
            ["rustc", "cargo", "node", "Zcode"]
        )
    }

    /// 断链且无出生记录(Pulse 拉起前出生的进程):只能呈自身,不崩、不臆造祖先。
    func testBrokenChainWithoutBirthRecordsEndsAtSelf() {
        let current = snapshot([rustc()])

        XCTAssertEqual(names(for: 100, snapshot: current, lineage: LineageRegistry()),
                       ["rustc"])
    }

    // MARK: 退化与安全

    /// 异常父链成环(a→b→a):按已访问 pid 终止,不无限循环。
    func testCyclicParentChainTerminates() {
        let current = snapshot([
            RawProcess(pid: 20, parentPID: 21, executablePath: "/usr/local/bin/a"),
            RawProcess(pid: 21, parentPID: 20, executablePath: "/usr/local/bin/b"),
        ])

        XCTAssertEqual(names(for: 20, snapshot: current, lineage: LineageRegistry()),
                       ["a", "b"])
    }

    /// 可执行路径受限的进程:名字退用 argv[0] basename(与进程行同口径)。
    func testRestrictedPathFallsBackToArgvZeroName() {
        let current = snapshot([
            RawProcess(pid: 30, parentPID: 1, argv: ["vitest", "run"]),
        ])

        XCTAssertEqual(names(for: 30, snapshot: current, lineage: LineageRegistry()),
                       ["vitest", "launchd"])
    }

    /// 查询的 pid 不在快照里(下钻期间进程退出、采样已刷新):返回空,不崩。
    func testUnknownPIDReturnsEmptyChain() {
        XCTAssertEqual(
            names(for: 999, snapshot: snapshot([zcode()]), lineage: LineageRegistry()),
            []
        )
    }
}
