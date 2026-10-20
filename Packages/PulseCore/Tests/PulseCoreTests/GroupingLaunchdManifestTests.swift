import XCTest
@testable import PulseCore

/// launchd 服务清单在归组引擎兜底分类里的四态(launchd-attribution/01):清单命中 ∧ 父为
/// launchd → 后台服务;命中 ∧ 父非 launchd → 与改前一致(清单不单独改判);未命中 → 与改前
/// 一致;空集 → 逐位不变。另钉 S3 回归(/usr/bin/ssh 形态)、全等匹配、静态域不受影响、
/// 管线热更新。期望值全部为独立字面量。
final class GroupingLaunchdManifestTests: XCTestCase {
    private let corplink = "/usr/local/corplink/corplink-service"

    private func launchd() -> RawProcess {
        RawProcess(pid: 1, parentPID: 0, executablePath: "/sbin/launchd", physicalFootprintBytes: 20_000_000)
    }

    private func configuration(manifest: Set<String>) -> GroupingConfiguration {
        GroupingConfiguration(launchdServiceExecutablePaths: manifest)
    }

    private func group(containing pid: pid_t, in groups: [ProcessGroup]) -> ProcessGroup? {
        groups.first { $0.processes.contains { $0.pid == pid } }
    }

    // MARK: 命中 ∧ 父为 launchd → 后台服务

    /// 无出生记录(Pulse 重启后)、现挂在活 launchd 之下、驻地 /usr/local 不在静态域,
    /// 但命中清单 → 后台服务。这正是 corplink-service 的真机形态。
    func testManifestHitUnderLiveLaunchdFallsToBackgroundService() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 500, parentPID: 1, executablePath: corplink, physicalFootprintBytes: 30_000_000),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: configuration(manifest: [corplink]),
            cpuPercentByPID: [500: 3]
        )

        let service = group(containing: 500, in: groups)
        XCTAssertEqual(service?.name, "后台服务")
        XCTAssertEqual(service?.category, .backgroundService)
    }

    /// 有出生记录、出生时父即 launchd:命中清单 → 后台服务(判定用出生路径)。
    func testManifestHitWithLaunchdBirthRecordFallsToBackgroundService() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 500, parentPID: 1, executablePath: corplink),
        ])
        let lineage = LineageRegistry().registeringBirths(in: snapshot)

        let groups = GroupingEngine.groups(
            from: snapshot,
            lineage: lineage,
            configuration: configuration(manifest: [corplink])
        )

        XCTAssertEqual(group(containing: 500, in: groups)?.category, .backgroundService)
    }

    // MARK: 命中 ∧ 父非 launchd → 与改前一致

    /// 出生时父是一个已死的无归属进程(非 launchd),现被重挂到 launchd:清单命中也不改判
    /// ——条件 (a) 不变,仍是孤儿。
    func testManifestHitWithoutLaunchdParentStaysOrphan() {
        let born = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 300, parentPID: 1, executablePath: "/usr/local/bin/launcher"),
            RawProcess(pid: 500, parentPID: 300, executablePath: corplink),
        ])
        let lineage = LineageRegistry().registeringBirths(in: born)
        // 父 300 已死,500 被重挂到 launchd。
        let now = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 500, parentPID: 1, executablePath: corplink),
        ])

        let groups = GroupingEngine.groups(
            from: now,
            lineage: lineage,
            configuration: configuration(manifest: [corplink])
        )

        XCTAssertEqual(group(containing: 500, in: groups)?.category, .orphan)
    }

    // MARK: 未命中 / 空集 → 与改前一致

    func testManifestMissUnderLaunchdStaysOrphan() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 500, parentPID: 1, executablePath: "/usr/local/postgres/bin/postgres"),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: configuration(manifest: [corplink])
        )

        XCTAssertEqual(group(containing: 500, in: groups)?.category, .orphan)
    }

    /// 缺省配置(清单空集)下 corplink 仍落孤儿——引入清单前的行为逐位保留。
    func testEmptyManifestLeavesCorplinkOrphan() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 500, parentPID: 1, executablePath: corplink),
        ])

        let groups = GroupingEngine.groups(from: snapshot)

        XCTAssertEqual(group(containing: 500, in: groups)?.name, "孤儿进程")
    }

    // MARK: S3 回归与匹配口径

    /// 评审 S3:launchd 之下但不在清单的一次性用户命令(/usr/bin/ssh)仍不算后台服务——
    /// 即便同目录的 ssh-agent 在清单里。
    func testOneOffUserCommandUnderLaunchdNotInManifestStaysOrphan() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 700, parentPID: 1, executablePath: "/usr/bin/ssh", argv: ["ssh", "host"]),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: configuration(manifest: [corplink, "/usr/bin/ssh-agent"])
        )

        XCTAssertEqual(group(containing: 700, in: groups)?.category, .orphan)
    }

    /// 清单在时静态域照常生效:/usr/libexec 守护不需要在清单里。
    func testStaticDomainStillWinsWithManifestPresent() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 800, parentPID: 1, executablePath: "/usr/libexec/logd"),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: configuration(manifest: [corplink])
        )

        XCTAssertEqual(group(containing: 800, in: groups)?.category, .backgroundService)
    }

    /// 匹配是全等不是前缀:同目录的 helper 与清单路径的父目录都不命中(ADR-0005)。
    func testManifestMatchIsExactNotPrefix() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 501, parentPID: 1, executablePath: corplink + "-helper"),
            RawProcess(pid: 502, parentPID: 1, executablePath: "/usr/local/corplink"),
        ])

        let groups = GroupingEngine.groups(
            from: snapshot,
            configuration: configuration(manifest: [corplink])
        )

        XCTAssertEqual(group(containing: 501, in: groups)?.category, .orphan)
        XCTAssertEqual(group(containing: 502, in: groups)?.category, .orphan)
    }

    // MARK: 管线热更新

    /// 清单经 setLaunchdServiceExecutablePaths 注入后,下一轮 update 即生效(与项目根热更新同形)。
    func testPipelineAppliesManifestOnNextUpdate() {
        let snapshot = ProcessSnapshot(processes: [
            launchd(),
            RawProcess(pid: 500, parentPID: 1, executablePath: corplink),
        ])
        var pipeline = GroupingPipeline()

        _ = pipeline.update(snapshot: snapshot, processCPU: [])
        XCTAssertEqual(group(containing: 500, in: pipeline.allGroups)?.category, .orphan)

        pipeline.setLaunchdServiceExecutablePaths([corplink])
        _ = pipeline.update(snapshot: snapshot, processCPU: [])
        XCTAssertEqual(group(containing: 500, in: pipeline.allGroups)?.category, .backgroundService)

        pipeline.setLaunchdServiceExecutablePaths([])
        _ = pipeline.update(snapshot: snapshot, processCPU: [])
        XCTAssertEqual(group(containing: 500, in: pipeline.allGroups)?.category, .orphan)
    }
}
