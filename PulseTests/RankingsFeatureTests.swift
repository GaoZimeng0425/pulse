import XCTest
import Observation
@testable import Pulse

/// 模块排行薄壳(RankingsFeature)的粘合:onRound 用同一份上下文的组出行;行没变不写
/// (Observation 每次 set 都通知);可见性折算 anyWindow 下发心跳账本门控。
/// 聚合 / 入账口径由 RankingBoardTests 与 ModuleRankingAggregatorTests 钉,这里只钉接线。
/// nettop 源惰性(不起子进程),不启动调度器。
@MainActor
final class RankingsFeatureTests: XCTestCase {
    private let takenAt = Date(timeIntervalSinceReferenceDate: 3_000)
    private let waifuID = "bundle:/Applications/WaifuX.app"

    // MARK: 测试替身

    /// 跨并发域记录盒:门控闭包在任意上下文被调,MainActor 上读。
    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []

        func append(_ value: Value) {
            lock.lock(); defer { lock.unlock() }
            stored.append(value)
        }

        var values: [Value] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private func makeFeature(gate: Recorder<Bool> = Recorder()) -> RankingsFeature {
        RankingsFeature(nettopSource: InertNettopCSVSource()) { active in
            gate.append(active)
        }
    }

    /// 主干真走一轮(RoundSpine):WaifuX(pid 50)一组,排行读数随本轮心跳带入。
    private func context(rankings: ProcessRankingRound) -> RoundContext {
        let snapshot = ProcessSnapshot(takenAt: takenAt, processes: [
            RawProcess(
                pid: 50,
                parentPID: 1,
                executablePath: "/Applications/WaifuX.app/Contents/MacOS/WaifuX"
            ),
        ])
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: nil, current: snapshot),
            cpu: .zero,
            memory: nil,
            network: nil,
            rankings: rankings
        ))
    }

    private let oneSecond = ProcessEnergyImpact(
        cpuNanosDelta: 1_000_000_000, wakeupsDelta: 0, impact: 1_000_000_000
    )

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            XCTFail("等待超时(\(timeout)s):\(what)")
        }
    }

    // MARK: 同轮出行

    /// 满窗轮落地:能耗行当场按同一份上下文的组出(pid 50 → WaifuX 组,1 秒)。
    func testRoundPublishesRowsGroupedByTheSameRoundsGroups() {
        let feature = makeFeature()

        feature.onRound(context(rankings: ProcessRankingRound(energyImpacts: [50: oneSecond])))

        XCTAssertEqual(feature.energyRows.map(\.id), [waifuID])
        XCTAssertEqual(feature.energyRows.first?.primary ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(feature.diskRows, [])
        XCTAssertEqual(feature.networkRows, [])
    }

    /// 下一轮行没变(未满窗,同组同读数):观察者不被惊动——钉的是对外契约,
    /// 由壳的显式比较与 @Observable 宏的同值跳过双重保证。
    func testUnchangedRowsAreNotRewritten() {
        let feature = makeFeature()
        feature.onRound(context(rankings: ProcessRankingRound(energyImpacts: [50: oneSecond])))
        let notified = Recorder<Bool>()

        withObservationTracking {
            _ = feature.energyRows
            _ = feature.diskRows
            _ = feature.networkRows
        } onChange: {
            notified.append(true)
        }
        feature.onRound(context(rankings: .empty))

        XCTAssertEqual(notified.values, [])
        XCTAssertEqual(feature.energyRows.map(\.id), [waifuID])
    }

    // MARK: 采样成本闸门

    /// 模块页开 → 心跳账本开闸;全关 → 关闸(逐次等落地,避免两条下发任务的先后之争)。
    func testVisibilityDrivesTheHeartbeatRankingGate() async {
        let gate = Recorder<Bool>()
        let feature = makeFeature(gate: gate)

        feature.visibilityChanged(MonitorVisibility(popover: false, moduleRankings: true))
        await waitUntil("开闸下发") { gate.values.count == 1 }
        feature.visibilityChanged(MonitorVisibility())
        await waitUntil("关闸下发") { gate.values.count == 2 }

        XCTAssertEqual(gate.values, [true, false])
    }
}
