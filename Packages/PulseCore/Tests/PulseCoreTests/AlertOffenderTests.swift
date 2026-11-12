@testable import PulseCore
import XCTest

/// 告警归因单测(NemoNotch toast 的原料):触发当轮组排行 + 进程 CPU 差分 →
/// 承载组 + 前三名进程。组表由引擎契约保证 CPU% 降序,CPU 类直接取组内既定
/// 顺序;内存类按物理足迹重排。磁盘 / dev server 无归因,组不在场 = 空摘要,
/// 不硬造。
final class AlertOffenderTests: XCTestCase {
    private func group(
        _ id: GroupIdentity,
        name: String,
        processes: [RawProcess],
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0
    ) -> ProcessGroup {
        ProcessGroup(
            id: id, name: name, processes: processes,
            cpuPercent: cpuPercent, memoryBytes: memoryBytes
        )
    }

    private func process(
        _ pid: pid_t, name: String, footprint: UInt64 = 0
    ) -> RawProcess {
        RawProcess(
            pid: pid, parentPID: 1,
            executablePath: "/usr/local/bin/\(name)", argv: [name],
            physicalFootprintBytes: footprint
        )
    }

    /// 系统级:全机第一名组(组表 CPU 降序)+ 组内既定顺序前三名(第四名截掉)。
    func testSystemLoadNamesTopGroupAndProcesses() {
        let top = group(
            .project(root: "octok", worktreeName: nil),
            name: "octok @ wt",
            processes: [
                process(100, name: "electron", footprint: 1000),
                process(101, name: "node", footprint: 2000),
                process(102, name: "rustc", footprint: 3000),
                process(103, name: "clang", footprint: 4000),
            ]
        )
        let idle = group(.system, name: "system", processes: [process(1, name: "launchd")])
        let summary = AlertOffenderAttribution.summarize(
            occurrence: AlertOccurrence(kind: .systemLoad, subjectKey: "system", value: 87, firedAt: Date()),
            groups: [top, idle],
            cpuPercentByPID: [100: 320, 101: 88, 102: 41, 103: 5]
        )
        XCTAssertEqual(summary.groupName, "octok @ wt")
        XCTAssertEqual(summary.entries.map(\.name), ["electron", "node", "rustc"])
        XCTAssertEqual(summary.entries.map(\.cpuPercent), [320, 88, 41])
        XCTAssertEqual(summary.entries.map(\.memoryBytes), [1000, 2000, 3000])
    }

    /// 系统级但组表为空(极端:采样空转)→ 空摘要,文案侧有兜底句。
    func testSystemLoadWithNoGroupsYieldsNone() {
        let summary = AlertOffenderAttribution.summarize(
            occurrence: AlertOccurrence(kind: .systemLoad, subjectKey: "system", value: 90, firedAt: Date()),
            groups: [],
            cpuPercentByPID: [:]
        )
        XCTAssertEqual(summary, .none)
    }

    /// 组级:按 subjectKey(stableKey)命中,不是按名字、不看组序。
    func testGroupCPUResolvesSubjectByStableKey() {
        let target = group(
            .app(bundlePath: "/Applications/Zap.app"),
            name: "Zap",
            processes: [process(7, name: "helper")]
        )
        let other = group(.orphan, name: "orphan", processes: [process(8, name: "stray")])
        let key = AlertEngine.subjectKey(of: target.id)
        let summary = AlertOffenderAttribution.summarize(
            occurrence: AlertOccurrence(
                kind: .groupCPU,
                subjectKey: key,
                subjectName: "Zap",
                value: 310,
                firedAt: Date()
            ),
            groups: [other, target],
            cpuPercentByPID: [7: 310]
        )
        XCTAssertEqual(summary.groupName, "Zap")
        XCTAssertEqual(summary.entries.map(\.name), ["helper"])
    }

    /// 组级但主体已不在当轮组表(消失与触发的极端错位)→ 空摘要。
    func testGroupCPUMissingSubjectYieldsNone() {
        let summary = AlertOffenderAttribution.summarize(
            occurrence: AlertOccurrence(kind: .groupCPU, subjectKey: "bundle:/gone.app", value: 400, firedAt: Date()),
            groups: [group(.orphan, name: "orphan", processes: [])],
            cpuPercentByPID: [:]
        )
        XCTAssertEqual(summary, .none)
    }

    /// 内存类:按物理足迹降序——组内既定顺序是 CPU 序,必须重排。
    func testNewGroupMemorySortsByFootprintNotGroupOrder() {
        let target = group(
            .project(root: "pulse", worktreeName: "wt"),
            name: "pulse @ wt",
            processes: [
                process(1, name: "swift-frontend", footprint: 900),
                process(2, name: "node", footprint: 2400),
                process(3, name: "electron", footprint: 1500),
            ]
        )
        let key = AlertEngine.subjectKey(of: target.id)
        let summary = AlertOffenderAttribution.summarize(
            occurrence: AlertOccurrence(kind: .newGroupMemory, subjectKey: key, value: 3000, firedAt: Date()),
            groups: [target],
            cpuPercentByPID: [1: 50, 2: 10, 3: 30]
        )
        XCTAssertEqual(summary.entries.map(\.name), ["node", "electron", "swift-frontend"])
        XCTAssertEqual(summary.entries.map(\.memoryBytes), [2400, 1500, 900])
    }

    /// 新出生进程无差分:cpuPercent 如实缺席(nil),不伪造 0。
    func testNewbornProcessKeepsNilCPUPercent() {
        let target = group(.app(bundlePath: "/x.app"), name: "x", processes: [process(9, name: "fresh")])
        let key = AlertEngine.subjectKey(of: target.id)
        let summary = AlertOffenderAttribution.summarize(
            occurrence: AlertOccurrence(kind: .groupCPU, subjectKey: key, value: 310, firedAt: Date()),
            groups: [target],
            cpuPercentByPID: [:]
        )
        XCTAssertEqual(summary.entries.map(\.cpuPercent), [nil])
    }

    /// 磁盘 / dev server:无进程归因(磁盘满是历史累计,不硬造)。
    func testDiskAndDevServerHaveNoAttribution() {
        let groups = [group(.orphan, name: "orphan", processes: [process(1, name: "x")])]
        for kind in [AlertKind.diskAvailable, .devServerIdle] {
            let summary = AlertOffenderAttribution.summarize(
                occurrence: AlertOccurrence(kind: kind, subjectKey: "disk", value: 1, firedAt: Date()),
                groups: groups,
                cpuPercentByPID: [1: 99]
            )
            XCTAssertEqual(summary, .none)
        }
    }

    // MARK: - 共享文案(bodyText,alert-offender-outlets 五出口单出处)

    /// 正文模板:引导语 + 名字读数串;新出生进程(nil 读数)只列名。
    func testBodyTextListsEntriesWithMetric() {
        let entries = [
            AlertOffenderEntry(name: "electron", cpuPercent: 320, memoryBytes: 1000),
            AlertOffenderEntry(name: "fresh", cpuPercent: nil, memoryBytes: 2000),
        ]
        let text = AlertOffenderAttribution.bodyText(
            lead: "最耗 CPU", entries: entries,
            metric: { entry in entry.cpuPercent.map { "\(String(format: "%g", $0))%" } }
        )
        XCTAssertEqual(text, "最耗 CPU:electron 320%、fresh")
    }

    /// entries 为空:引导语 + 兜底句(组已不在场)。
    func testBodyTextEmptyEntriesGivesFallback() {
        XCTAssertEqual(
            AlertOffenderAttribution.bodyText(
                lead: "最耗 CPU", entries: [], metric: { _ in nil }
            ),
            "最耗 CPU:进程已不在场,打开 Pulse 查看排行。"
        )
    }

    /// 日志一行摘要:承载组 + 第一名进程(带读数);无归因给「无归因」。
    func testLogLineNamesGroupAndFirstEntry() {
        let attributed = AlertOffenderSummary(
            groupName: "octok",
            entries: [
                AlertOffenderEntry(name: "electron", cpuPercent: 320, memoryBytes: 1),
                AlertOffenderEntry(name: "node", cpuPercent: 88, memoryBytes: 1),
            ]
        )
        XCTAssertEqual(
            AlertOffenderAttribution.logLine(for: attributed),
            "承载组 octok,electron 320%"
        )
        XCTAssertEqual(AlertOffenderAttribution.logLine(for: .none), "无归因")
    }

    // MARK: - 落库 JSON(alert_event.offender_entries)

    /// entriesJSON 往返:编解码等值;空表 → nil(列值 NULL,老行兼容口径一致)。
    func testEntriesJSONRoundTrip() {
        let entries = [
            AlertOffenderEntry(name: "electron", cpuPercent: 320.5, memoryBytes: 1000),
            AlertOffenderEntry(name: "fresh", cpuPercent: nil, memoryBytes: 2000),
        ]
        let summary = AlertOffenderSummary(groupName: "octok", entries: entries)
        let json = summary.entriesJSON
        XCTAssertNotNil(json)
        XCTAssertEqual(AlertOffenderSummary.entries(fromJSON: json), entries)

        XCTAssertNil(AlertOffenderSummary(groupName: nil, entries: []).entriesJSON, "空表不落列")
        XCTAssertEqual(AlertOffenderSummary.entries(fromJSON: nil), [], "老行 NULL 读出空表")
        XCTAssertEqual(
            AlertOffenderSummary.entries(fromJSON: "not json"),
            [],
            "坏行不炸读侧"
        )
    }

    /// 归因键 = 种类|主体(与系统通知 identifier 同规则)。
    func testOffenderKeyMatchesNotificationIdentifier() {
        let occurrence = AlertOccurrence(
            kind: .groupCPU, subjectKey: "bundle:/X.app", value: 300, firedAt: Date()
        )
        XCTAssertEqual(occurrence.offenderKey, "groupCPU|bundle:/X.app")
    }
}
