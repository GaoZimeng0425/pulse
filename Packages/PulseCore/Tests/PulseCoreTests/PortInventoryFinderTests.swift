@testable import PulseCore
import XCTest

/// 全局端口盘点纯逻辑(port-view/01):归并 / 同口多进程 / 排序 / 截断 /
/// dev server 标注 / 名字口径——全部合成夹具,零真实扫描。
final class PortInventoryFinderTests: XCTestCase {
    private let finder = PortInventoryFinder()

    private func snapshot(_ processes: [RawProcess]) -> ProcessSnapshot {
        ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 1_789_000_000), processes: processes)
    }

    private func server(pid: pid_t, kind: DevServerKind = .vite, idle: TimeInterval? = nil) -> DevServerStatus {
        DevServerStatus(
            pid: pid, kind: kind, displayName: kind.displayName,
            memoryBytes: 0, idleSeconds: idle, listeningPorts: []
        )
    }

    // MARK: 归并与排序

    func testAggregatesByPortAscendingAcrossProcesses() {
        let snap = snapshot([
            RawProcess(pid: 20, parentPID: 1, executablePath: "/usr/local/bin/node", argv: []),
            RawProcess(pid: 10, parentPID: 1, executablePath: "/opt/homebrew/bin/postgres", argv: []),
        ])
        let inventory = finder.inventory(
            scan: [20: [5173], 10: [5432, 5433]],
            snapshot: snap, devServers: [], limit: 20
        )
        XCTAssertEqual(inventory.entries.map(\.port), [5173, 5432, 5433])
        XCTAssertEqual(inventory.totalCount, 3)
        XCTAssertFalse(inventory.isTruncated)
    }

    func testSamePortMultipleHoldersListedByPIDAscending() {
        let snap = snapshot([
            RawProcess(pid: 30, parentPID: 1, executablePath: "/usr/local/bin/node", argv: []),
            RawProcess(pid: 12, parentPID: 1, executablePath: "/usr/local/bin/node", argv: []),
        ])
        let inventory = finder.inventory(
            scan: [30: [3000], 12: [3000, 3001]],
            snapshot: snap, devServers: [], limit: 20
        )
        XCTAssertEqual(inventory.totalCount, 2)
        XCTAssertEqual(inventory.entries.first { $0.port == 3000 }?.holders.map(\.pid), [12, 30])
    }

    /// 扫描见到但快照尚无身份(时间差窗口):不丢行,名字兜底 "pid N"。
    func testUnknownPIDFallsBackToPIDName() {
        let inventory = finder.inventory(
            scan: [777: [8080]],
            snapshot: snapshot([]), devServers: [], limit: 20
        )
        let holder = inventory.entries.first?.holders.first
        XCTAssertEqual(holder?.name, "pid 777")
    }

    /// 端口 0 与空扫描如实不出行。
    func testZeroPortAndEmptyScanProduceNoEntries() {
        let snap = snapshot([RawProcess(pid: 1, parentPID: 0, executablePath: "/bin/launchd", argv: [])])
        let zero = finder.inventory(scan: [1: [0]], snapshot: snap, devServers: [], limit: 20)
        XCTAssertTrue(zero.entries.isEmpty)
        let empty = finder.inventory(scan: [:], snapshot: snap, devServers: [], limit: 20)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.totalCount, 0)
    }

    // MARK: 截断

    func testTruncatesToLimitKeepingTotalCount() {
        let processes = (1 ... 8).map {
            RawProcess(pid: pid_t($0), parentPID: 1, executablePath: "/bin/x", argv: [])
        }
        let scan = Dictionary(
            uniqueKeysWithValues: (1 ... 8).map { (pid_t($0), [UInt16(10000 + $0)]) }
        )
        let inventory = finder.inventory(scan: scan, snapshot: snapshot(processes), devServers: [], limit: 5)
        XCTAssertEqual(inventory.entries.count, 5)
        XCTAssertEqual(inventory.totalCount, 8)
        XCTAssertTrue(inventory.isTruncated)
        // 截断保号序最小的前 5 个。
        XCTAssertEqual(inventory.entries.map(\.port), (1 ... 5).map { UInt16(10000 + $0) })
    }

    // MARK: dev server 标注与名字口径

    func testDevServerAnnotationComesFromInventoryBroadcast() {
        let snap = snapshot([
            RawProcess(pid: 55, parentPID: 1, executablePath: "/usr/local/bin/node", argv: ["node", "vite.js"]),
        ])
        let inventory = finder.inventory(
            scan: [55: [5173]],
            snapshot: snap,
            devServers: [server(pid: 55, kind: .vite, idle: 600)],
            limit: 20
        )
        let holder = inventory.entries.first?.holders.first
        XCTAssertEqual(holder?.devServerKind, .vite)
        XCTAssertEqual(holder?.idleSeconds, 600)
        XCTAssertEqual(holder?.name, "node")
        XCTAssertEqual(holder?.killTarget, KillTarget(pid: 55, name: "node"))
    }

    func testNonDevServerHolderHasNoAnnotation() {
        let snap = snapshot([
            RawProcess(pid: 66, parentPID: 1, executablePath: nil, argv: ["/opt/homebrew/bin/postgres"]),
        ])
        let inventory = finder.inventory(
            scan: [66: [5432]], snapshot: snap, devServers: [], limit: 20
        )
        let holder = inventory.entries.first?.holders.first
        XCTAssertNil(holder?.devServerKind)
        XCTAssertNil(holder?.idleSeconds)
        // 名字口径与全 app 一致:argv[0] 也取 basename。
        XCTAssertEqual(holder?.name, "postgres")
    }
}
