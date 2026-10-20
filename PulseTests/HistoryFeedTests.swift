import XCTest
@testable import Pulse

/// 历史喂料纯内核(HistoryFeed):每轮主干上下文 + 两轮之间交付的磁盘吞吐读数 →
/// 一笔落库入参(HistoryIngest)。上下文经真主干(RoundSpine)从合成快照推进得到;
/// 只经公开接口断言,期望值全部为独立字面量(手算的工作示例)。
final class HistoryFeedTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)
    private let ingestAt = Date(timeIntervalSinceReferenceDate: 1_005)

    // MARK: 夹具

    /// 磁盘吞吐读数:记账增量 + 速率。
    private func diskReading(read: UInt64, write: UInt64, rate: Double) -> DiskThroughputReading {
        DiskThroughputReading(
            current: DiskRates(readBytesPerSecond: rate, writeBytesPerSecond: rate / 2),
            trend: [DiskRatePoint(read: rate, write: rate / 2)],
            readBytesDelta: read,
            writeBytesDelta: write
        )
    }

    /// 一轮主干上下文:单进程快照(首轮,无差分),网络读数按需给。
    private func context(network: NetworkRoundResult? = nil) -> RoundContext {
        let snapshot = ProcessSnapshot(takenAt: base, processes: [
            RawProcess(pid: 50, parentPID: 1, executablePath: "/Applications/WaifuX.app/Contents/MacOS/WaifuX"),
        ])
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: nil, current: snapshot),
            cpu: .zero,
            memory: nil,
            network: network,
            rankings: .empty
        ))
    }

    private let waifuX = GroupIdentity.app(bundlePath: "/Applications/WaifuX.app")
    private let zed = GroupIdentity.app(bundlePath: "/Applications/Zed.app")

    /// 两个 App 组的一轮(前一张快照 1s 前):WaifuX 主进程 + 嵌套 Helper(CPU 时间
    /// +0.25s / +0.5s → 25% + 50% = 75%,足迹 300MB + 200MB),Zed 单进程
    /// (+0.125s → 12.5%,100MB)。系统负载 42.5%。
    private func twoAppsContext() -> RoundContext {
        let waifuXMain = "/Applications/WaifuX.app/Contents/MacOS/WaifuX"
        let waifuXHelper = "/Applications/WaifuX.app/Contents/Frameworks/WaifuX Helper.app/Contents/MacOS/WaifuX Helper"
        let zedMain = "/Applications/Zed.app/Contents/MacOS/zed"
        let previous = ProcessSnapshot(takenAt: base, processes: [
            RawProcess(pid: 50, parentPID: 1, executablePath: waifuXMain, cpuTimeNanoseconds: 1_000_000_000),
            RawProcess(pid: 51, parentPID: 50, executablePath: waifuXHelper),
            RawProcess(pid: 60, parentPID: 1, executablePath: zedMain),
        ])
        let current = ProcessSnapshot(takenAt: base.addingTimeInterval(1), processes: [
            RawProcess(
                pid: 50, parentPID: 1, executablePath: waifuXMain,
                cpuTimeNanoseconds: 1_250_000_000, physicalFootprintBytes: 300_000_000
            ),
            RawProcess(
                pid: 51, parentPID: 50, executablePath: waifuXHelper,
                cpuTimeNanoseconds: 500_000_000, physicalFootprintBytes: 200_000_000
            ),
            RawProcess(
                pid: 60, parentPID: 1, executablePath: zedMain,
                cpuTimeNanoseconds: 125_000_000, physicalFootprintBytes: 100_000_000
            ),
        ])
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: current,
            diff: CPUDiffer.diff(previous: previous, current: current),
            cpu: CPULoadBreakdown(total: 42.5, user: 30, system: 12.5),
            memory: nil,
            network: nil,
            rankings: .empty
        ))
    }

    // MARK: 磁盘吞吐记账:恰好一次

    /// driver 读失败时重投上次好值(标 stale):只记新读数那一次。
    func testStaleRedeliveryOfTheLastGoodDiskReadingIsNotCounted() {
        var feed = HistoryFeed()
        let reading = diskReading(read: 4_096, write: 1_024, rate: 800)

        feed.recordDiskThroughput(.fresh(reading))
        feed.recordDiskThroughput(.stale(reading))
        let ingest = feed.takeIngest(from: context(), at: ingestAt)

        XCTAssertEqual(ingest.diskReadBytes, 4_096)
        XCTAssertEqual(ingest.diskWriteBytes, 1_024)
    }

    /// 两份新读数逐字段全等(同速率、同增量)也各记一次——新鲜度看标记,不看值
    /// (此前按值去重时这是已知边界)。
    func testTwoFreshReadingsWithIdenticalValuesAreBothCounted() {
        var feed = HistoryFeed()
        let reading = diskReading(read: 4_096, write: 1_024, rate: 800)

        feed.recordDiskThroughput(.fresh(reading))
        feed.recordDiskThroughput(.fresh(reading))
        let ingest = feed.takeIngest(from: context(), at: ingestAt)

        XCTAssertEqual(ingest.diskReadBytes, 8_192)
        XCTAssertEqual(ingest.diskWriteBytes, 2_048)
    }

    /// 两轮心跳之间来了两份不同读数(4096/1024 与 8192/2048):这一笔带走合计
    /// 12288/3072;再下一笔(期间无新读数)为 0——账本已清。
    func testDistinctDiskReadingsAccumulateAndTheNextIngestDrainsThem() {
        var feed = HistoryFeed()

        feed.recordDiskThroughput(.fresh(diskReading(read: 4_096, write: 1_024, rate: 800)))
        feed.recordDiskThroughput(.fresh(diskReading(read: 8_192, write: 2_048, rate: 1_600)))
        let first = feed.takeIngest(from: context(), at: ingestAt)
        let second = feed.takeIngest(from: context(), at: ingestAt.addingTimeInterval(5))

        XCTAssertEqual(first.diskReadBytes, 12_288)
        XCTAssertEqual(first.diskWriteBytes, 3_072)
        XCTAssertEqual(second.diskReadBytes, 0)
        XCTAssertEqual(second.diskWriteBytes, 0)
    }

    /// 清账之后 driver 又重投了同一份上次好值(读失败轮):已经记过,不再记。
    func testDiskReadingRedeliveredAfterTheDrainIsNotCountedAgain() {
        var feed = HistoryFeed()
        let reading = diskReading(read: 4_096, write: 1_024, rate: 800)

        feed.recordDiskThroughput(.fresh(reading))
        let drained = feed.takeIngest(from: context(), at: ingestAt)
        feed.recordDiskThroughput(.stale(reading))
        let afterRedelivery = feed.takeIngest(from: context(), at: ingestAt.addingTimeInterval(5))

        XCTAssertEqual(drained.diskReadBytes, 4_096)
        XCTAssertEqual(afterRedelivery.diskReadBytes, 0)
        XCTAssertEqual(afterRedelivery.diskWriteBytes, 0)
    }

    // MARK: 网络记账增量

    /// 网络心跳轮差分:下行 1500 → rx,上行 300 → tx。
    func testNetworkDeltasMapDownloadToRxAndUploadToTx() {
        var feed = HistoryFeed()
        let network = NetworkRoundResult(
            interface: "en0",
            rates: NetworkRates(upBytesPerSecond: 60, downBytesPerSecond: 300),
            upBytesDelta: 300,
            downBytesDelta: 1_500
        )

        let ingest = feed.takeIngest(from: context(network: network), at: ingestAt)

        XCTAssertEqual(ingest.netRxBytes, 1_500)
        XCTAssertEqual(ingest.netTxBytes, 300)
    }

    /// 本轮网络读缺失(network == nil):增量 0,不伪造。
    func testRoundWithoutNetworkReadingIngestsZeroNetBytes() {
        var feed = HistoryFeed()

        let ingest = feed.takeIngest(from: context(network: nil), at: ingestAt)

        XCTAssertEqual(ingest.netRxBytes, 0)
        XCTAssertEqual(ingest.netTxBytes, 0)
    }

    // MARK: 组采样与展示名

    /// 组采样(CPU% / 足迹 / 进程数)与展示名都取本轮主干的组,组 CPU% 降序。
    func testGroupSamplesAndDisplayNamesComeFromTheRoundGroups() {
        var feed = HistoryFeed()

        let ingest = feed.takeIngest(from: twoAppsContext(), at: ingestAt)

        XCTAssertEqual(ingest.groups, [
            GroupSample(id: waifuX, cpuPercent: 75, memoryBytes: 500_000_000, processCount: 2),
            GroupSample(id: zed, cpuPercent: 12.5, memoryBytes: 100_000_000, processCount: 1),
        ])
        XCTAssertEqual(ingest.displayNames, [waifuX: "WaifuX", zed: "Zed"])
    }

    /// 采样时刻取壳给的 now(不是快照时刻);系统负载取本轮心跳;出生登记取本轮
    /// 主干累计表(三个进程都由快照兜底登记,Helper 生在 WaifuX 主进程下)。
    func testIngestCarriesGivenTimeRoundSystemLoadAndRoundLineage() {
        var feed = HistoryFeed()

        let ingest = feed.takeIngest(from: twoAppsContext(), at: ingestAt)

        XCTAssertEqual(ingest.at, ingestAt)
        XCTAssertEqual(ingest.systemLoad, 42.5)
        XCTAssertEqual(ingest.lineage.entries.keys.sorted(), [50, 51, 60])
        XCTAssertEqual(ingest.lineage.entries[51]?.parentPID, 50)
    }
}
