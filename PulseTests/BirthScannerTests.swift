import XCTest
@testable import Pulse
@testable import PulseCore

/// 接缝:出生扫描(评审 S1,spec"每 2s 扫描新出现的 pid")——
/// 独立于采样节奏的登记来源。时钟与睡眠注入假实现(与 SamplerTests 同法),
/// 源注入脚本化假源:新 pid 差分、登记内容、幂等、节奏全部确定性覆盖;
/// LiveBirthScanSource 另做真机冒烟。
final class BirthScannerTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: 测试替身

    /// 脚本化出生扫描源:按调用顺序吐 pid 列表(耗尽停在末张),
    /// birthInfo 按闭包应答并记录查询轨迹。
    private final class ScriptedBirthScanSource: BirthScanSource, @unchecked Sendable {
        private let lock = NSLock()
        private let pidLists: [[pid_t]]
        private let entryFor: (pid_t) -> LineageRegistry.Entry?
        private var listIndex = 0
        private var queries: [pid_t] = []

        init(
            pidLists: [[pid_t]],
            entryFor: @escaping (pid_t) -> LineageRegistry.Entry?
        ) {
            precondition(!pidLists.isEmpty)
            self.pidLists = pidLists
            self.entryFor = entryFor
        }

        func pids() -> [pid_t] {
            lock.lock(); defer { lock.unlock() }
            let list = pidLists[min(listIndex, pidLists.count - 1)]
            listIndex += 1
            return list
        }

        func birthInfo(for pid: pid_t) -> LineageRegistry.Entry? {
            lock.lock(); defer { lock.unlock() }
            queries.append(pid)
            return entryFor(pid)
        }

        var birthQueries: [pid_t] {
            lock.lock(); defer { lock.unlock() }
            return queries
        }
    }

    /// 假时间轴(与 SamplerTests 同法):记录睡眠请求,预算耗尽抛错停机。
    private final class FakeTimeline: @unchecked Sendable {
        private let lock = NSLock()
        private let start: Date
        private var requests: [TimeInterval] = []
        private let budget: Int
        struct Exhausted: Error {}

        init(start: Date, sleepBudget: Int) {
            self.start = start
            budget = sleepBudget
        }

        var clock: @Sendable () -> Date {
            { [self] in
                lock.lock(); defer { lock.unlock() }
                return start
            }
        }

        var sleeper: @Sendable (TimeInterval) async throws -> Void {
            { [self] seconds in
                await Task.yield()
                try record(seconds)
            }
        }

        /// 同步临界区:锁不落在 async 词法上下文里(NSLock 在 async 中禁用)。
        private func record(_ seconds: TimeInterval) throws {
            lock.lock(); defer { lock.unlock() }
            guard requests.count < budget else { throw Exhausted() }
            requests.append(seconds)
        }

        var sleepRequests: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    /// 线程安全的登记表交付记录。
    private final class RegistryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var registries: [LineageRegistry] = []

        func append(_ registry: LineageRegistry) {
            lock.lock(); defer { lock.unlock() }
            registries.append(registry)
        }

        var delivered: [LineageRegistry] {
            lock.lock(); defer { lock.unlock() }
            return registries
        }
    }

    /// 跑到假时钟预算耗尽(run 自然返回),返回全部交付的登记表。
    private func drain(
        _ scanner: BirthScanner,
        timeline: FakeTimeline
    ) async -> [LineageRegistry] {
        let box = RegistryBox()
        let task = Task { await scanner.run { box.append($0) } }
        await task.value
        return box.delivered
    }

    private func makeScanner(
        source: any BirthScanSource,
        timeline: FakeTimeline
    ) -> BirthScanner {
        BirthScanner(source: source, clock: timeline.clock, sleep: timeline.sleeper)
    }

    // MARK: 新 pid 差分(纯逻辑)

    func testNewlyAppearedDiffingKeepsOrderAndDeduplicates() {
        XCTAssertEqual(BirthScanner.newlyAppeared(pids: [1, 2, 3], known: []), [1, 2, 3])
        XCTAssertEqual(BirthScanner.newlyAppeared(pids: [1, 2, 3], known: [1, 2]), [3])
        XCTAssertEqual(BirthScanner.newlyAppeared(pids: [1, 2, 3], known: [1, 2, 3]), [])
        // 列表内重复只算一次新面孔;顺序保持出现序。
        XCTAssertEqual(BirthScanner.newlyAppeared(pids: [9, 9, 4, 1], known: [1]), [9, 4])
        XCTAssertEqual(BirthScanner.newlyAppeared(pids: [], known: []), [])
    }

    // MARK: 登记

    func testScanRegistersBirthInfoForNewlyAppearedPIDs() async {
        let source = ScriptedBirthScanSource(
            pidLists: [[1], [1, 42]],
            entryFor: { pid in
                pid == 1
                    ? LineageRegistry.Entry(
                        parentPID: 0,
                        identity: ProcessIdentity(executablePath: "/sbin/launchd", cwd: nil, argv: ["launchd"])
                    )
                    : LineageRegistry.Entry(
                        parentPID: 7,
                        identity: ProcessIdentity(executablePath: "/bin/foo", cwd: "/tmp/x", argv: ["foo", "-x"])
                    )
            }
        )
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let delivered = await drain(makeScanner(source: source, timeline: timeline), timeline: timeline)

        // 预算 2 次睡眠 → 3 轮扫描,每轮交付本轮新登记的出生(增量,不是累计表——
        // 累计表只增不删,4 天能涨到近 10 万条,票 arch-review-2026-10-18/04)。
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered.map { $0.entries.keys.sorted() }, [[1], [42], []])
        let registry = delivered[1]
        XCTAssertEqual(
            registry.entries[42],
            LineageRegistry.Entry(
                parentPID: 7,
                identity: ProcessIdentity(executablePath: "/bin/foo", cwd: "/tmp/x", argv: ["foo", "-x"])
            ),
            "新 pid 的出生信息应完整登记(父 pid / 路径 / cwd / argv)"
        )
        XCTAssertEqual(delivered[0].entries[1]?.parentPID, 0)
        // 每个新 pid 只查询一次:第二轮起 [1,42] 都是已知面孔。
        XCTAssertEqual(source.birthQueries, [1, 42])
    }

    func testRegistrationIsIdempotentFirstRecordWins() async {
        // 源对 42 的应答逐次变化:登记必须保留首次记录、且不重复查询。
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let counter = Counter()
        let source = ScriptedBirthScanSource(
            pidLists: [[42]],
            entryFor: { _ in
                let round = counter.next()
                return LineageRegistry.Entry(
                    parentPID: pid_t(round),
                    identity: ProcessIdentity(executablePath: "/bin/foo")
                )
            }
        )
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let delivered = await drain(makeScanner(source: source, timeline: timeline), timeline: timeline)

        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered[0].entries[42]?.parentPID, 1, "首轮登记首次查询结果")
        XCTAssertTrue(delivered[1].entries.isEmpty && delivered[2].entries.isEmpty, "仍在的 pid 不重复交付")
        XCTAssertEqual(source.birthQueries, [42], "同一 pid 只应被查询一次")
    }

    /// pid 消失后又出现 = 被新进程复用:重新探测、重新交付出生(已知集合只记上一轮
    /// 还在的 pid,不再终身累计)。
    func testReappearingPIDIsProbedAgainAsANewBirth() async {
        let source = ScriptedBirthScanSource(pidLists: [[42], [], [42]]) { _ in
            LineageRegistry.Entry(parentPID: 1, identity: ProcessIdentity(executablePath: "/bin/foo"))
        }
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let delivered = await drain(makeScanner(source: source, timeline: timeline), timeline: timeline)

        XCTAssertEqual(delivered.map { $0.entries.keys.sorted() }, [[42], [], [42]])
        XCTAssertEqual(source.birthQueries, [42, 42])
    }

    func testProcessVanishingBetweenListAndQueryIsSkippedSilently() async {
        // pid 5 出现在枚举里但查询时已退出(entry nil):安静跳过,不崩不登记;
        // 之后各轮也不再重试(采样轮的 registeringBirths 是兜底)。
        let source = ScriptedBirthScanSource(pidLists: [[5]]) { _ in nil }
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let delivered = await drain(makeScanner(source: source, timeline: timeline), timeline: timeline)

        XCTAssertEqual(delivered.count, 3)
        XCTAssertTrue(delivered.allSatisfy { $0.entries.isEmpty })
        XCTAssertEqual(source.birthQueries, [5], "查询失败的 pid 不逐轮重试")
    }

    // MARK: 节奏与登记表融合

    func testCadenceIsTwoSecondsIndependentOfSampling() async {
        let source = ScriptedBirthScanSource(pidLists: [[1]]) { _ in nil }
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        _ = await drain(makeScanner(source: source, timeline: timeline), timeline: timeline)

        XCTAssertEqual(
            timeline.sleepRequests, [2, 2],
            "出生扫描固定 ~2s 节奏(spec),与采样 5s/1s 无关"
        )
    }

    func testRegistryMergingKeepsOwnRecordsAndFillsGaps() {
        var own = LineageRegistry()
        own.register(pid: 10, entry: LineageRegistry.Entry(parentPID: 1, identity: ProcessIdentity(executablePath: "/a")))
        var other = LineageRegistry()
        other.register(pid: 10, entry: LineageRegistry.Entry(parentPID: 2, identity: ProcessIdentity(executablePath: "/b")))
        other.register(pid: 11, entry: LineageRegistry.Entry(parentPID: 3, identity: ProcessIdentity(executablePath: "/c")))

        let merged = own.merging(other)

        XCTAssertEqual(merged.entries[10]?.executablePath, "/a", "两侧都有的 pid 保留自身首记")
        XCTAssertEqual(merged.entries[11]?.executablePath, "/c", "缺失的 pid 从扫描侧补足")
        XCTAssertEqual(own.entries[11], nil, "融合是纯函数:原表不变")
    }

    // MARK: Live 源冒烟(与 LiveProcessSourceSmokeTests 同决策口径)

    func testLiveBirthScanSourceSmoke() {
        let live = LiveBirthScanSource()

        let pids = live.pids()
        XCTAssertGreaterThan(pids.count, 0, "本机 pid 枚举应非空")
        XCTAssertTrue(pids.contains(1), "launchd(pid 1)应在枚举里")

        let launchd = live.birthInfo(for: 1)
        XCTAssertNotNil(launchd, "launchd 的出生信息应可读")
        XCTAssertEqual(launchd?.parentPID, 0, "launchd 的父是 0")
        XCTAssertEqual(launchd?.executablePath, "/sbin/launchd")
    }
}
