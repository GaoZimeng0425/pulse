import Foundation
import Darwin

// dev server 盘点的纯逻辑:argv 分类器、闲置环、盘点编排与端口扫描接缝。libproc 端口扫描适配器在 app target(DevServerFinder.swift)。

/// dev server 种类(GLOSSARY:按命令行模式识别的开发期本地常驻服务)。
/// displayName 为卡片的进程行名(人读命令形态)。
public enum DevServerKind: String, CaseIterable, Equatable, Sendable {
    case vite
    case nextDev
    case webpackDevServer
    case tscWatch
    case vitestWatch
    case jestWatch
    case pytestWatch
    case djangoRunserver
    case bunDev
    case cargoWatch

    /// 卡片行的人读名(命令形态,不取路径)。
    public var displayName: String {
        switch self {
        case .vite: "vite"
        case .nextDev: "next dev"
        case .webpackDevServer: "webpack-dev-server"
        case .tscWatch: "tsc --watch"
        case .vitestWatch: "vitest watch"
        case .jestWatch: "jest watch"
        case .pytestWatch: "pytest --watch"
        case .djangoRunserver: "manage.py runserver"
        case .bunDev: "bun run dev"
        case .cargoWatch: "cargo watch"
        }
    }
}

/// 一次命中:种类 + 展示名。
public struct DevServerMatch: Equatable, Sendable {
    public let kind: DevServerKind
    public let displayName: String

    public init(kind: DevServerKind, displayName: String) {
        self.kind = kind
        self.displayName = displayName
    }
}

/// argv 分类器(纯函数):识别"这个进程是不是 dev server"。
///
/// 匹配纪律(防误报,票面要求"路径碰巧含 vite 的非 dev 进程"不入列):
/// - 只看可执行名与解释器脚本的 basename 的**精确**匹配——vitepress、
///   webpack.config.js 这类"路径里碰巧有"一律不命中;
/// - 一次性子命令排除(vite build / next build / next start / vitest run /
///   cargo build 等):短命进程不是常驻服务;
/// - watch 系(tsc/jest/pytest)要求显式 watch 参数:tsc 无 `--watch` 就是一次
///   编译,jest `--watchman=false` 这类前缀撞车不算。
///
/// `npm run dev` 不在此列:npm 本体是过渡父进程,真正的 vite/next 子进程会被
/// 命中(避免同一条 dev server 在卡里出现两行)。
public enum DevServerClassifier {
    /// 允许"脚本路径作第二个 token"的解释器(node vite.js / python manage.py)。
    private static let interpreters: Set<String> = ["node", "nodejs", "bun", "python", "python3"]

    public static func classify(argv: [String]) -> DevServerMatch? {
        guard let executable = argv.first else { return nil }
        let rest = argv.dropFirst()
        // 候选 token = 可执行本体;解释器再带上脚本 token(node vite.js)。
        var tokens: [(base: String, rest: [String])] = [(basename(executable), Array(rest))]
        if interpreters.contains(basename(executable)), let script = rest.first {
            tokens.append((basename(script), Array(rest.dropFirst())))
        }
        for token in tokens {
            if let match = classifyToken(base: token.base, rest: token.rest) {
                return match
            }
        }
        return nil
    }

    /// 单 token 规则:base = 精确可执行名(basename),rest = 其后的参数。
    private static func classifyToken(base: String, rest: [String]) -> DevServerMatch? {
        // 首个非 flag 参数(子命令判定用)。
        let subcommand = rest.first { !$0.hasPrefix("-") }
        switch base {
        case "vite", "vite.js":
            // vite / vite dev / vite serve / vite preview 都起服务;vite build 一次性。
            guard subcommand != "build" else { return nil }
            return match(.vite)
        case "next":
            // next(默认即 dev)/ next dev 起;build / start / lint 等不算。
            guard subcommand == nil || subcommand == "dev" else { return nil }
            return match(.nextDev)
        case "webpack-dev-server", "webpack-dev-server.js":
            return match(.webpackDevServer)
        case "webpack", "webpack.js", "webpack-cli", "webpack-cli.js":
            guard rest.contains("serve") || rest.contains("dev-server") || rest.contains("--watch")
            else { return nil }
            return match(.webpackDevServer)
        case "tsc", "tsc.js":
            // tsc --watch / -w 才是常驻监视;裸 tsc 一次编译。
            guard rest.contains("--watch") || rest.contains("-w") else { return nil }
            return match(.tscWatch)
        case "vitest", "vitest.js", "vitest.mjs":
            // 裸 vitest(TTY 默认 watch)/ vitest watch / --watch 都算;vitest run 一次性。
            guard subcommand == nil || subcommand?.contains("watch") == true || rest.contains("--watch")
            else { return nil }
            return match(.vitestWatch)
        case "jest", "jest.js":
            // 显式 watch 旗标才常驻;--watchman=false 这类前缀撞车不算。
            guard rest.contains("--watch") || rest.contains(where: { $0.hasPrefix("--watchAll") })
            else { return nil }
            return match(.jestWatch)
        case "ptw":
            // pytest-watch 的专用可执行名(本身即常驻监视)。
            return match(.pytestWatch)
        case "pytest", "py.test":
            guard rest.contains("--watch") else { return nil }
            return match(.pytestWatch)
        case "manage.py":
            // python manage.py runserver(Django);migrate / shell 等一次性不算。
            guard rest.contains("runserver") else { return nil }
            return match(.djangoRunserver)
        case "bun":
            // bun run dev / bun dev(脚本名 dev 前缀);bun build / install 天然不命中。
            if rest.first == "run", rest.count >= 2, rest[1].hasPrefix("dev") {
                return match(.bunDev)
            }
            if let subcommand, !subcommand.hasPrefix("-"), subcommand.hasPrefix("dev") {
                return match(.bunDev)
            }
            return nil
        case "cargo-watch":
            return match(.cargoWatch)
        case "cargo":
            // cargo watch -x run 常驻;cargo build / test 一次性。
            guard subcommand == "watch" else { return nil }
            return match(.cargoWatch)
        default:
            return nil
        }
    }

    private static func match(_ kind: DevServerKind) -> DevServerMatch {
        DevServerMatch(kind: kind, displayName: kind.displayName)
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// 闲置环(纯逻辑):按 pid 记最近活动时刻与首见时刻,"闲置" = 最近
/// `idleWindow` 秒 CPU≈0(GLOSSARY 闲置);闲置秒数 = 现在 − 最近一次活动
/// (从未活动则首次观察到今——只承认看得到的历史,不编造启动前的闲置)。
public struct DevServerIdleTracker: Sendable {
    /// 闲置窗口:10 分钟(工单票面)。
    public static let idleWindow: TimeInterval = 600
    /// "CPU≈0"的活动线:观察值 ≥ 1%(单核口径)算有活动,低于此视为 ≈0。
    public static let activityCPUThreshold: Double = 1.0

    private var firstSeen: [pid_t: Date] = [:]
    private var lastActivity: [pid_t: Date] = [:]

    /// 喂一轮观察。cpuPercent = 本轮差分 CPU%(nil = 新出生进程,尚无差分,
    /// 只立首见基线不判活动——不伪造 0)。
    public mutating func observe(pid: pid_t, cpuPercent: Double?, now: Date) {
        if firstSeen[pid] == nil { firstSeen[pid] = now }
        if let cpuPercent, cpuPercent >= Self.activityCPUThreshold {
            lastActivity[pid] = now
        }
    }

    /// 闲置秒数;nil = 最近窗口内有活动(未闲置)。
    public func idleSeconds(pid: pid_t, now: Date) -> TimeInterval? {
        guard let anchor = lastActivity[pid] ?? firstSeen[pid] else { return nil }
        let sinceActivity = now.timeIntervalSince(anchor)
        return sinceActivity >= Self.idleWindow ? sinceActivity : nil
    }

    /// 进程消失即清状态(pid 复用不会继承旧闲置史)。
    public mutating func prune(alive: Set<pid_t>) {
        firstSeen = firstSeen.filter { alive.contains($0.key) }
        lastActivity = lastActivity.filter { alive.contains($0.key) }
    }

    public init() {
    }
}

/// 卡片的一行 dev server:闲置时长 / 内存 / 监听端口。
public struct DevServerStatus: Identifiable, Equatable, Sendable {
    public let pid: pid_t
    public let kind: DevServerKind
    public let displayName: String
    /// 物理足迹(活动监视器"内存"列口径,字节)。
    public let memoryBytes: UInt64
    /// 闲置秒数;nil = 最近 10 分钟内有活动(未闲置)。
    public let idleSeconds: TimeInterval?
    /// 监听中的 TCP 端口(升序去重;扫描失败/受限为空,不伪造)。
    public let listeningPorts: [UInt16]

    public var id: pid_t { pid }
    /// "闲置"标签:最近 10 分钟 CPU≈0(GLOSSARY)。
    public var isIdle: Bool { idleSeconds != nil }

    public init(
        pid: pid_t,
        kind: DevServerKind,
        displayName: String,
        memoryBytes: UInt64,
        idleSeconds: TimeInterval? = nil,
        listeningPorts: [UInt16]
    ) {
        self.pid = pid
        self.kind = kind
        self.displayName = displayName
        self.memoryBytes = memoryBytes
        self.idleSeconds = idleSeconds
        self.listeningPorts = listeningPorts
    }
}

/// 盘点编排:分类 → 只对候选喂闲置环并扫端口 → 合成状态。
/// 有状态(闲置环)但全部时刻注入;端口扫描走缝,单测注入计数假实现。
public struct DevServerFinder: Sendable {
    public let portScanner: any DevServerPortScanning
    private var tracker = DevServerIdleTracker()
    /// 跨轮分类缓存(arch-review-2026-10-18/04):pid → (argv, 分类结果)。argv 终身不变
    /// (采集层出生时读一次),同 pid 同 argv 直接复用;argv 变了(pid 复用)重新分类。
    /// 每轮只带走在场进程。
    private var classifications: [pid_t: (argv: [String], match: DevServerMatch?)] = [:]

    /// 推进一轮:返回本轮 dev server 状态(快照序)。
    public mutating func update(
        snapshot: ProcessSnapshot,
        processCPU: [pid_t: Double],
        now: Date
    ) -> [DevServerStatus] {
        var candidates: [(process: RawProcess, match: DevServerMatch)] = []
        var nextClassifications: [pid_t: (argv: [String], match: DevServerMatch?)] = [:]
        nextClassifications.reserveCapacity(snapshot.processes.count)
        for process in snapshot.processes {
            let match: DevServerMatch?
            if let cached = classifications[process.pid], cached.argv == process.argv {
                match = cached.match
            } else {
                match = DevServerClassifier.classify(argv: process.argv)
            }
            nextClassifications[process.pid] = (process.argv, match)
            if let match {
                candidates.append((process, match))
            }
        }
        classifications = nextClassifications
        // 闲置环只喂候选:非候选没有展示闲置的场合,不积累状态。
        for candidate in candidates {
            tracker.observe(
                pid: candidate.process.pid,
                cpuPercent: processCPU[candidate.process.pid],
                now: now
            )
        }
        tracker.prune(alive: Set(snapshot.processes.map(\.pid)))
        // 成本约束(票面):端口扫描(libproc 逐 fd 系统调用)只对候选进程。
        return candidates.map { candidate in
            DevServerStatus(
                pid: candidate.process.pid,
                kind: candidate.match.kind,
                displayName: candidate.match.displayName,
                memoryBytes: candidate.process.physicalFootprintBytes,
                idleSeconds: tracker.idleSeconds(pid: candidate.process.pid, now: now),
                listeningPorts: portScanner.listeningPorts(pid: candidate.process.pid)
            )
        }
    }

    public init(portScanner: any DevServerPortScanning) {
        self.portScanner = portScanner
    }
}

/// 端口扫描接缝:真实现 libproc 直调(PROC_PIDLISTFDS + PROC_PIDFDINFO_SOCKET),
/// 单测注入假实现记录被扫描的 pid(成本约束的断言点)。
public protocol DevServerPortScanning: Sendable {
    /// 该 pid 监听中的 TCP 端口(升序去重);进程不存在/受限 → 空数组。
    func listeningPorts(pid: pid_t) -> [UInt16]
}
