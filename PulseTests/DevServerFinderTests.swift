@testable import Pulse
@testable import PulseCore
import XCTest

/// 工单 08:argv 分类器(模式 + 误报负例)、闲置环(注入时刻)、盘点编排
/// (端口扫描只对候选——成本约束)、闲置 24h 告警规则经合成快照真实触发。
final class DevServerFinderTests: XCTestCase {
    // MARK: - argv 分类器:已知模式清单

    /// 每种 dev server 至少一条真实形态 argv 命中。
    func testClassifierMatchesKnownPatterns() {
        let cases: [(argv: [String], kind: DevServerKind)] = [
            (["node", "/x/proj/node_modules/.bin/vite"], .vite),
            (["node", "/x/proj/node_modules/vite/bin/vite.js", "--port", "5173"], .vite),
            (["/Users/x/.local/bin/vite", "--host"], .vite),
            (["node", "/usr/local/bin/next", "dev", "-p", "3000"], .nextDev),
            (["/usr/local/bin/next"], .nextDev),
            (["node", "/x/node_modules/webpack-dev-server/bin/webpack-dev-server.js"], .webpackDevServer),
            (["node", "/x/node_modules/.bin/webpack", "serve", "--mode", "development"], .webpackDevServer),
            (["/usr/local/bin/tsc", "--watch", "-p", "/x"], .tscWatch),
            (["node", "/x/node_modules/typescript/bin/tsc", "-w"], .tscWatch),
            (["node", "/x/node_modules/.bin/vitest", "watch"], .vitestWatch),
            (["node", "/x/node_modules/.bin/vitest", "--coverage"], .vitestWatch),
            (["node", "/x/node_modules/.bin/jest", "--watchAll"], .jestWatch),
            (["/usr/local/bin/pytest", "--watch", "-x"], .pytestWatch),
            (["python", "/x/proj/manage.py", "runserver", "0.0.0.0:8000"], .djangoRunserver),
            (["python3", "manage.py", "runserver"], .djangoRunserver),
            (["/opt/homebrew/bin/bun", "run", "dev"], .bunDev),
            (["/opt/homebrew/bin/bun", "dev"], .bunDev),
            (["/opt/homebrew/bin/cargo", "watch", "-x", "run"], .cargoWatch),
            (["/opt/homebrew/bin/cargo-watch"], .cargoWatch),
        ]
        for testCase in cases {
            let match = DevServerClassifier.classify(argv: testCase.argv)
            XCTAssertEqual(match?.kind, testCase.kind, "argv \(testCase.argv) 应命中 \(testCase.kind)")
            XCTAssertNotNil(match?.displayName, "命中应带展示名")
        }
    }

    // MARK: - argv 分类器:误报负例

    /// 路径碰巧含工具名 / 一次性子命令 / 缺 watch 参数的进程不入列(票面要求)。
    func testClassifierRejectsFalsePositivesAndOneShots() {
        let negatives: [[String]] = [
            // 路径里碰巧含 vite 的非 dev 进程(vitepress / 工具名带前缀)。
            ["node", "/Users/x/proj/vitepress/build.js"],
            ["node", "/Users/x/tools/vite-check/bin/scan"],
            ["/usr/local/bin/vite-scan", "run"],
            // 一次性子命令:build / start / migrate / install。
            ["node", "/x/node_modules/.bin/vite", "build"],
            ["node", "/usr/local/bin/next", "build"],
            ["node", "/usr/local/bin/next", "start"],
            ["python", "manage.py", "migrate"],
            ["/opt/homebrew/bin/bun", "run", "build"],
            ["/opt/homebrew/bin/cargo", "build"],
            // watch 系缺显式 watch 参数:tsc/jest/pytest 一次跑完就退。
            ["/usr/local/bin/tsc", "-p", "tsconfig.json"],
            ["node", "/x/node_modules/.bin/vitest", "run"],
            ["node", "/x/node_modules/.bin/jest", "--coverage"],
            ["node", "/x/node_modules/.bin/jest", "--watchman=false", "run"],
            ["/usr/local/bin/pytest", "test_app.py"],
            // webpack.config.js 是配置文件路径,不是 webpack 本体。
            ["node", "/x/proj/webpack.config.js"],
            // 普通服务脚本(node server.js)与空 argv。
            ["node", "server.js"],
        ]
        for argv in negatives {
            XCTAssertNil(DevServerClassifier.classify(argv: argv), "argv \(argv) 不应命中")
        }
        XCTAssertNil(DevServerClassifier.classify(argv: []))
    }

    // MARK: - 闲置环:注入时刻

    /// 有活动 → 未闲置;窗口(10 分钟)内再无活动 → 满窗起记闲置;活动重置。
    func testIdleTrackerWindowAndResetWithInjectedClock() {
        var tracker = DevServerIdleTracker()
        var now = Date(timeIntervalSince1970: 1_000_000)

        // 刚起:无 CPU 读数(新出生)也立首见基线,闲置秒 = 0,未满窗 → 未闲置。
        tracker.observe(pid: 10, cpuPercent: nil, now: now)
        XCTAssertNil(tracker.idleSeconds(pid: 10, now: now))

        // 有活动:未闲置,闲置秒恒 nil。
        now.addTimeInterval(5)
        tracker.observe(pid: 10, cpuPercent: 45, now: now)
        XCTAssertNil(tracker.idleSeconds(pid: 10, now: now.addingTimeInterval(60)))

        // 活动后 10 分钟整:满窗判定为闲置,秒数从最后一次活动起算。
        let lastActive = now
        let atWindow = lastActive.addingTimeInterval(DevServerIdleTracker.idleWindow)
        XCTAssertEqual(tracker.idleSeconds(pid: 10, now: atWindow), DevServerIdleTracker.idleWindow)

        // 窗口边界的"≈0"线:活动判定 ≥1%,0.5% 的读数不算活动。
        now = atWindow
        tracker.observe(pid: 10, cpuPercent: 0.5, now: now)
        XCTAssertEqual(
            tracker.idleSeconds(pid: 10, now: now.addingTimeInterval(120)),
            atWindow.addingTimeInterval(120).timeIntervalSince(lastActive),
            "0.5% 观察不重置闲置锚点"
        )

        // 重新活动(2%):闲置清零回到未闲置。
        let resumed = now.addingTimeInterval(120)
        tracker.observe(pid: 10, cpuPercent: 2, now: resumed)
        XCTAssertNil(tracker.idleSeconds(pid: 10, now: resumed.addingTimeInterval(30)))
        XCTAssertEqual(
            tracker.idleSeconds(pid: 10, now: resumed.addingTimeInterval(DevServerIdleTracker.idleWindow)),
            DevServerIdleTracker.idleWindow
        )

        // 首见兜底:从未活动过的进程,闲置秒从首见起算(只承认看得到的历史)。
        var fresh = DevServerIdleTracker()
        let seen = Date(timeIntervalSince1970: 5_000_000)
        fresh.observe(pid: 20, cpuPercent: 0, now: seen)
        XCTAssertEqual(
            fresh.idleSeconds(pid: 20, now: seen.addingTimeInterval(DevServerIdleTracker.idleWindow)),
            DevServerIdleTracker.idleWindow
        )
    }

    /// 消失即清状态:同 pid 重生不继承旧闲置史。
    func testIdleTrackerPruneDropsDeadPids() {
        var tracker = DevServerIdleTracker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        tracker.observe(pid: 10, cpuPercent: 0, now: now)
        tracker.prune(alive: [99])
        XCTAssertNil(
            tracker.idleSeconds(pid: 10, now: now.addingTimeInterval(DevServerIdleTracker.idleWindow)),
            "被 prune 的 pid 闲置史清空"
        )
    }

    // MARK: - 盘点编排:端口扫描只对候选(成本约束)

    /// 冒烟(真机口径,OS 边界走一次真路径):本进程内开一个真实 TCP 监听
    /// socket,libproc 扫描应读到同一端口——钉死 struct 路径与网络序换算。
    func testLivePortScannerReadsRealListeningSocket() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return XCTFail("socket() 失败 errno \(errno)") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // 绑随机端口,读回实际值
        addr.sin_addr = in_addr(s_addr: in_addr_t(0)) // INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            return XCTFail("bind/listen 失败 errno \(errno)")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { return XCTFail("getsockname 失败 errno \(errno)") }
        let port = UInt16(bigEndian: bound.sin_port)
        guard port != 0 else { return XCTFail("绑定到端口 0") }
        let ports = LiveDevServerPortScanner().listeningPorts(pid: getpid())
        XCTAssertTrue(
            ports.contains(port),
            "libproc 扫描应读到本进程监听端口 \(port),实际 \(ports)"
        )
    }

    /// 记录被扫描 pid 的假扫描器(端口扫描缝的测试注入点)。
    private final class RecordingScanner: DevServerPortScanning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var scanned: [pid_t] = []
        let portsByPID: [pid_t: [UInt16]]

        init(portsByPID: [pid_t: [UInt16]] = [:]) {
            self.portsByPID = portsByPID
        }

        func listeningPorts(pid: pid_t) -> [UInt16] {
            lock.lock()
            scanned.append(pid)
            lock.unlock()
            return portsByPID[pid] ?? []
        }
    }

    /// 十个进程里一个候选:libproc 逐 fd 的扫描只发生一次(票面"成本约束有测试体现")。
    func testPortScanOnlyRunsForCandidates() {
        let scanner = RecordingScanner(portsByPID: [300: [5173]])
        var finder = DevServerFinder(portScanner: scanner)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let processes = (0 ..< 9).map { index in
            RawProcess(
                pid: pid_t(100 + index),
                parentPID: 1,
                executablePath: "/Applications/A\(index).app/Contents/MacOS/A\(index)",
                argv: ["/Applications/A\(index).app/Contents/MacOS/A\(index)"]
            )
        }
        // 路径含 vite 的误报进程也不许被扫(分类器负例进编排同样成立)。
        let decoy = RawProcess(
            pid: 400, parentPID: 1,
            executablePath: "/Users/x/proj/vitepress/build.js",
            argv: ["node", "/Users/x/proj/vitepress/build.js"]
        )
        let candidate = RawProcess(
            pid: 300, parentPID: 1, executablePath: "/x/node_modules/.bin/vite",
            argv: ["node", "/x/node_modules/.bin/vite"], physicalFootprintBytes: 84_000_000
        )
        let servers = finder.update(
            snapshot: ProcessSnapshot(takenAt: now, processes: processes + [decoy, candidate]),
            processCPU: [300: 0],
            now: now
        )
        XCTAssertEqual(scanner.scanned, [300], "只有 argv 命中的候选进程被端口扫描")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.pid, 300)
        XCTAssertEqual(servers.first?.listeningPorts, [5173])
        XCTAssertEqual(servers.first?.memoryBytes, 84_000_000)
        XCTAssertEqual(servers.first?.kind, .vite)
    }

    /// 跨轮分类缓存(arch-review-2026-10-18/04):同一 pid 下一轮 argv 变了(被复用)要重新
    /// 分类——上一轮是 vite,这一轮是普通 node 脚本,就不再是候选。
    func testReusedPIDWithDifferentArgvIsReclassified() {
        var finder = DevServerFinder(portScanner: RecordingScanner(portsByPID: [:]))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let vite = RawProcess(
            pid: 300,
            parentPID: 1,
            executablePath: "/x/node",
            argv: ["node", "/x/node_modules/.bin/vite"]
        )
        let script = RawProcess(pid: 300, parentPID: 1, executablePath: "/x/node", argv: ["node", "/x/build.js"])

        let first = finder.update(snapshot: ProcessSnapshot(takenAt: now, processes: [vite]), processCPU: [:], now: now)
        let second = finder.update(
            snapshot: ProcessSnapshot(takenAt: now.addingTimeInterval(5), processes: [script]),
            processCPU: [:], now: now.addingTimeInterval(5)
        )

        XCTAssertEqual(first.map(\.pid), [300])
        XCTAssertEqual(second, [])
    }

    /// 闲置时长经编排层合成:候选进程 0% 观察 25h → 状态携带闲置秒数与"闲置"标签。
    func testFinderComposesIdleDurationAcrossRounds() {
        let scanner = RecordingScanner()
        var finder = DevServerFinder(portScanner: scanner)
        var now = Date(timeIntervalSince1970: 1_000_000)
        let candidate = RawProcess(
            pid: 300, parentPID: 1, executablePath: "/x/node_modules/.bin/vite",
            argv: ["node", "/x/node_modules/.bin/vite"]
        )
        // 首轮有活动,随后长跑零负载观察。
        var servers = finder.update(
            snapshot: ProcessSnapshot(takenAt: now, processes: [candidate]),
            processCPU: [300: 40],
            now: now
        )
        XCTAssertFalse(servers[0].isIdle)

        now = now.addingTimeInterval(25 * 3600)
        servers = finder.update(
            snapshot: ProcessSnapshot(takenAt: now, processes: [candidate]),
            processCPU: [300: 0],
            now: now
        )
        XCTAssertTrue(servers[0].isIdle)
        XCTAssertEqual(servers[0].idleSeconds ?? -1, 25 * 3600, accuracy: 1)

        // 进程真的消失一轮(触发 prune 清状态)后重生(同 pid):
        // 首轮零差分读数 → 闲置秒从重生首见起算,未满窗,不继承旧闲置史。
        _ = finder.update(
            snapshot: ProcessSnapshot(takenAt: now.addingTimeInterval(5), processes: []),
            processCPU: [:],
            now: now.addingTimeInterval(5)
        )
        let reborn = finder.update(
            snapshot: ProcessSnapshot(takenAt: now.addingTimeInterval(10), processes: [candidate]),
            processCPU: [:],
            now: now.addingTimeInterval(10)
        )
        XCTAssertFalse(reborn[0].isIdle)
        XCTAssertEqual(reborn[0].idleSeconds ?? -1, 0, accuracy: 1)
    }

    // MARK: - 闲置 >24h 告警:合成快照注入引擎真实触发

    /// 合成 dev server 快照逐轮喂引擎:连续 3 轮超阈触发(fired),server 消失
    /// 立即解除(resolved)——票面"真实可触发"验收的纯逻辑锚点。
    func testDevServerIdleAlertFiresWithSyntheticFeeds() {
        var engine = AlertEngine()
        var settings = AlertEvaluationSettings()
        settings[.devServerIdle] = AlertRulePolicy(
            isEnabled: true,
            threshold: 24 * 3600,
            sustain: nil,
            cooldown: 600,
            direction: .above
        )
        let server = AlertDevServerSnapshot(pid: 300, name: "vite", idleSeconds: 25 * 3600)
        var now = Date(timeIntervalSince1970: 2_000_000)

        // 前两轮:进入计数未满,不发。
        XCTAssertNil(fired(engine.record(.devServers([server]), now: now, settings: settings)))
        now.addTimeInterval(5)
        XCTAssertNil(fired(engine.record(.devServers([server]), now: now, settings: settings)))
        // 第三轮:进入条件齐(连续 3 次 > 24h),真实发出。
        now.addTimeInterval(5)
        let occurrence = fired(engine.record(.devServers([server]), now: now, settings: settings))
        XCTAssertEqual(occurrence?.kind, .devServerIdle)
        XCTAssertEqual(occurrence?.subjectKey, AlertEngine.devServerSubjectKey(pid: 300))
        XCTAssertEqual(occurrence?.subjectName, "vite")
        XCTAssertEqual(occurrence?.value, 25 * 3600)
        XCTAssertEqual(occurrence?.kind.route, .overview, "点通知直达总览(dev server 卡所在页)")

        // 未闲置的 server(闲置秒 nil)不喂——喂进去的只有确认闲置的读数。

        // server 消失:立即解除。
        now.addTimeInterval(5)
        let resolved = engine.record(.devServers([]), now: now, settings: settings)
        XCTAssertEqual(resolved, [.resolved(kind: .devServerIdle, subjectKey: "devserver|300")])

        // 重新出现且再次闲置:独立主体重新走完进入路径(冷却锚点随消失清空)。
        for round in 0 ..< 3 {
            now.addTimeInterval(5)
            let events = engine.record(.devServers([server]), now: now, settings: settings)
            if round == 2 {
                XCTAssertEqual(fired(events)?.kind, .devServerIdle, "重生后再次真实触发")
            } else {
                XCTAssertNil(fired(events))
            }
        }
    }

    /// 迟滞语义对闲置规则同样成立:回到安全侧(闲置 < 阈值−20%)连续 6 轮解除。
    func testDevServerIdleAlertResolvesAfterActivity() {
        var engine = AlertEngine()
        var settings = AlertEvaluationSettings()
        settings[.devServerIdle] = AlertRulePolicy(
            isEnabled: true, threshold: 24 * 3600, sustain: nil, cooldown: 600, direction: .above
        )
        var now = Date(timeIntervalSince1970: 2_000_000)
        let idle = AlertDevServerSnapshot(pid: 7, name: "next dev", idleSeconds: 30 * 3600)

        // 前两轮立进入计数,第三轮真实发出。
        for _ in 0 ..< 2 {
            now.addTimeInterval(5)
            _ = engine.record(.devServers([idle]), now: now, settings: settings)
        }
        now.addTimeInterval(5)
        XCTAssertEqual(fired(engine.record(.devServers([idle]), now: now, settings: settings))?.kind, .devServerIdle)

        // 活动恢复:闲置秒回 0(安全侧),连续 6 轮后解除。
        let active = AlertDevServerSnapshot(pid: 7, name: "next dev", idleSeconds: 0)
        var events: [AlertEvent] = []
        for round in 0 ..< 6 {
            now.addTimeInterval(5)
            events = engine.record(.devServers([active]), now: now, settings: settings)
            if round < 5 {
                XCTAssertTrue(events.isEmpty, "安全计数未满不该提前解除")
            }
        }
        XCTAssertEqual(events, [.resolved(kind: .devServerIdle, subjectKey: "devserver|7")])
    }

    // MARK: 工具

    private func fired(_ events: [AlertEvent]) -> AlertOccurrence? {
        events.compactMap {
            if case let .fired(occurrence) = $0 {
                return occurrence
            } else {
                return nil
            }
        }.first
    }
}
