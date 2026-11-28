@testable import Pulse
import PulseCore
import XCTest

// agent-git-status/01:AgentSessionFeature 壳层 git 三道闸的行为钉子(评审 P2
// 补测)——不可见不采 / cwd 集变化 5s 档 / 稳态 15s 档 / 在飞不双发。夹具全合成
// (假注册表 JSON + 假 git reader),时钟用注入的 takenAt,零真 git。

/// 假会话注册表:可变条目集(cwd 集变化测试要在两轮之间加第二个实例)。
/// @unchecked 前提:entries 与读计数只在 NSLock 下读写(测试主线程加条目,盘点的
/// utility 任务读——跨线程,锁即串行化)。
private final class StubSessionReader: AgentSessionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Data]

    init(entries: [Data] = []) {
        self.entries = entries
    }

    func addEntry(pid: Int32, cwd: String) {
        let json = """
        {"pid": \(pid), "sessionId": "s\(pid)", "cwd": "\(cwd)", "startedAt": 1000}
        """
        lock.lock()
        entries.append(Data(json.utf8))
        lock.unlock()
    }

    func claudeRegistryFiles() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return entries
    }

    /// 注册表读次数(盘点闸断言点:不可见期不得碰会话文件)。
    private var reads = 0
    var registryReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func claudeUsageSnapshotFile() -> Data? {
        nil
    }

    func claudeTranscriptTail(cwd: String, sessionId: String) -> Data? {
        nil
    }

    func claudeSubagentCount(cwd: String, sessionId: String) -> Int {
        0
    }

    func zcodeAgentMetadataCandidates(lookback: TimeInterval, now: Date) -> [ZCodeMetadataCandidate] {
        []
    }

    func zcodeAgentMetadata(atPath path: String) -> Data? {
        nil
    }
}

/// 假 git reader:记每次 status(cwd:) 调用;可选信号量闸门卡住首调(在飞互斥
/// 测试)。@unchecked 前提:计数与闸门捕获只在 NSLock 下 / 信号量语义内访问。
private final class CountingGitReader: SessionGitStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var gate: DispatchSemaphore?

    private static let head = Data("ref: refs/heads/develop\n".utf8)

    func armGate() {
        gate = DispatchSemaphore(value: 0)
    }

    func openGate() {
        gate?.signal()
    }

    func gitHeadFile(cwd: String) -> Data? {
        // 先记账再等闸:在飞测试要能观察到「已进入 reader 但被闸门卡住」。
        lock.lock()
        calls.append(cwd)
        let currentGate = gate
        lock.unlock()
        currentGate?.wait()
        return Self.head
    }

    func gitStatusOutput(cwd: String) -> Data? {
        Data("".utf8)
    }

    var callLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@MainActor
final class AgentSessionFeatureGitTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let agentsVisible = MonitorVisibility(mainWindowTab: .agents)
    private let otherTabVisible = MonitorVisibility(mainWindowTab: .cpu)

    private func makeFeature(git: CountingGitReader, sessions: StubSessionReader) -> AgentSessionFeature {
        AgentSessionFeature(reader: sessions, gitReader: git)
    }

    /// 一轮带存活进程的主干上下文(照 AlertCenterToastTests.round 同款);
    /// takenAt 注入——git 节流的双档全靠它推进。
    private func round(at takenAt: Date, pids: [pid_t]) -> RoundContext {
        let processes = pids.map {
            RawProcess(pid: $0, parentPID: 1, executablePath: "/bin/claude")
        }
        let snapshot = ProcessSnapshot(takenAt: takenAt, processes: processes)
        var spine = RoundSpine(configuration: GroupingConfiguration(projectRoots: []))
        return spine.advance(SamplingUpdate(
            snapshot: snapshot,
            diff: CPUDiffer.diff(previous: nil, current: snapshot),
            cpu: CPULoadBreakdown(total: 10, user: 10, system: 0),
            rankings: .empty
        ))
    }

    /// 等后台采集批落到 gitStatuses(detached → MainActor 回跳)。
    private func settleGit(_ feature: AgentSessionFeature, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while feature.gitStatuses.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 等一小段确认「没有新采集被发起」(节流断言的反向等待)。
    private func pause(_ seconds: TimeInterval = 0.25) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testInvisibleTabNeverSamplesGit() async {
        let git = CountingGitReader()
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: git, sessions: sessions)
        feature.visibilityChanged(otherTabVisible)
        feature.onRound(round(at: t0, pids: [42]))
        await settleGit(feature, timeout: 0.5)
        XCTAssertTrue(git.callLog.isEmpty, "智能体页不可见时不得发起 git 采集")
        XCTAssertTrue(feature.gitStatuses.isEmpty)
    }

    func testVisibleTabSamplesAndSteadyIntervalThrottles() async {
        let git = CountingGitReader()
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: git, sessions: sessions)
        feature.visibilityChanged(agentsVisible)

        // 首轮:新 cwd 集,立即可见即可采。
        feature.onRound(round(at: t0, pids: [42]))
        await settleGit(feature)
        XCTAssertEqual(feature.gitStatuses["/repo"]?.branch, "develop")
        XCTAssertEqual(git.callLog, ["/repo"])

        // +6s,cwd 集没变:稳态 15s 档,不采。
        feature.onRound(round(at: t0.addingTimeInterval(6), pids: [42]))
        await pause()
        XCTAssertEqual(git.callLog.count, 1, "cwd 集未变时 15s 内不得重复采集")

        // +16s:稳态档到点,再采。
        feature.onRound(round(at: t0.addingTimeInterval(16), pids: [42]))
        let deadline = Date().addingTimeInterval(2)
        while git.callLog.count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(git.callLog.count, 2, "稳态 15s 到点应再次采集")
    }

    func testChangedDirSetUsesShortInterval() async {
        let git = CountingGitReader()
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: git, sessions: sessions)
        feature.visibilityChanged(agentsVisible)

        feature.onRound(round(at: t0, pids: [42]))
        await settleGit(feature)
        XCTAssertEqual(git.callLog.count, 1)

        // +6s 出现第二个 cwd(catalog 自身 5s 刷新档在 +6s 已能看到它):
        // cwd 集变化走 5s 档,立即可采——这正是「新会话分支别等一轮长的」。
        sessions.addEntry(pid: 43, cwd: "/repo2")
        feature.onRound(round(at: t0.addingTimeInterval(6), pids: [42, 43]))
        let deadline = Date().addingTimeInterval(2)
        while git.callLog.count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(Set(git.callLog), ["/repo", "/repo2"], "新 cwd 集应按 5s 档立刻采集")
    }

    func testInFlightBatchBlocksSecondKick() async {
        let git = CountingGitReader()
        git.armGate()
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: git, sessions: sessions)
        feature.visibilityChanged(agentsVisible)

        // 首批卡在闸门上(在飞)。
        feature.onRound(round(at: t0, pids: [42]))
        await pause(0.3)
        XCTAssertEqual(git.callLog.count, 1, "首批应已进入 reader(被闸门卡住)")

        // 在飞期间 cwd 集变化 + 5s 档到点:不得双发。
        sessions.addEntry(pid: 43, cwd: "/repo2")
        feature.onRound(round(at: t0.addingTimeInterval(6), pids: [42, 43]))
        await pause(0.3)
        XCTAssertEqual(git.callLog.count, 1, "在飞批次未落定前不得发起第二批")

        // 放行首批评完,确认整程只有一批;此后下一轮照常可采。
        git.openGate()
        await settleGit(feature)
        XCTAssertEqual(feature.gitStatuses["/repo"]?.branch, "develop")
        XCTAssertEqual(git.callLog, ["/repo"])
    }

    // MARK: - 盘点闸(agent-scan-cost)

    /// 等盘点落到 snapshot(detached → MainActor 回跳)。
    private func settleSnapshot(_ feature: AgentSessionFeature, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while feature.snapshot.claudeSessions.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testInvisibleTabNeverReadsSessionFiles() async {
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: CountingGitReader(), sessions: sessions)
        feature.visibilityChanged(otherTabVisible)
        feature.onRound(round(at: t0, pids: [42]))
        feature.onRound(round(at: t0.addingTimeInterval(6), pids: [42]))
        await pause()
        XCTAssertEqual(sessions.registryReads, 0, "智能体页不可见时不得盘点会话文件")
        XCTAssertTrue(feature.snapshot.claudeSessions.isEmpty)
    }

    func testOpeningAgentsTabRefreshesWithoutWaitingForNextRound() async {
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: CountingGitReader(), sessions: sessions)
        feature.visibilityChanged(otherTabVisible)
        feature.onRound(round(at: t0, pids: [42]))

        // 打开智能体页:不再来新的一轮,也要用最近一轮的进程表立即盘点上屏。
        feature.visibilityChanged(agentsVisible)
        await settleSnapshot(feature)
        XCTAssertEqual(feature.snapshot.claudeSessions.map(\.pid), [42])
        XCTAssertEqual(sessions.registryReads, 1)
    }

    func testAdvancedCatalogIsWrittenBackSoThrottledRoundsSkipIO() async {
        let sessions = StubSessionReader()
        sessions.addEntry(pid: 42, cwd: "/repo")
        let feature = makeFeature(git: CountingGitReader(), sessions: sessions)
        feature.visibilityChanged(agentsVisible)
        feature.onRound(round(at: t0, pids: [42]))
        await settleSnapshot(feature)
        XCTAssertEqual(sessions.registryReads, 1)

        // +1s 仍在 5s 节流窗内:后台算完的 catalog 若没写回,这里会再读一遍盘。
        feature.onRound(round(at: t0.addingTimeInterval(1), pids: [42]))
        await pause()
        XCTAssertEqual(sessions.registryReads, 1, "节流窗内不得重读会话文件")

        // 进程退出:节流轮照样按存活过滤下榜。
        feature.onRound(round(at: t0.addingTimeInterval(2), pids: []))
        await pause()
        XCTAssertTrue(feature.snapshot.claudeSessions.isEmpty, "退出实例应在一轮内下榜")
    }
}
