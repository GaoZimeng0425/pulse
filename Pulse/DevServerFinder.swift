import Foundation
import Darwin

// MARK: - dev server 盘点(工单 08)
//
// argv 分类器是纯函数(工单票面):直接吃现有进程快照的 argv(RawProcess 现成
// 字段,零新采集成本);只有分类命中的候选进程才做端口扫描(PROC_PIDLISTFDS +
// PROC_PIDFDINFO_SOCKET,libproc 直调);"闲置" = 最近 10 分钟 CPU≈0(观察时刻
// 由调用方注入,单测合成时间轴,与 Sampler/AlertEngine 同款纪律)。
// 词汇表:dev server / 闲置(Idle)——处置永远由人确认,这里只盘点不杀。

/// dev server 种类(GLOSSARY:按命令行模式识别的开发期本地常驻服务)。
/// displayName 为卡片的进程行名(人读命令形态)。
enum DevServerKind: String, CaseIterable, Equatable, Sendable {
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
    var displayName: String {
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
struct DevServerMatch: Equatable, Sendable {
    let kind: DevServerKind
    let displayName: String
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
enum DevServerClassifier {
    /// 允许"脚本路径作第二个 token"的解释器(node vite.js / python manage.py)。
    private static let interpreters: Set<String> = ["node", "nodejs", "bun", "python", "python3"]

    static func classify(argv: [String]) -> DevServerMatch? {
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

// MARK: - 闲置判定(注入时刻)

/// 闲置环(纯逻辑):按 pid 记最近活动时刻与首见时刻,"闲置" = 最近
/// `idleWindow` 秒 CPU≈0(GLOSSARY 闲置);闲置秒数 = 现在 − 最近一次活动
/// (从未活动则首次观察到今——只承认看得到的历史,不编造启动前的闲置)。
struct DevServerIdleTracker: Sendable {
    /// 闲置窗口:10 分钟(工单票面)。
    static let idleWindow: TimeInterval = 600
    /// "CPU≈0"的活动线:观察值 ≥ 1%(单核口径)算有活动,低于此视为 ≈0。
    static let activityCPUThreshold: Double = 1.0

    private var firstSeen: [pid_t: Date] = [:]
    private var lastActivity: [pid_t: Date] = [:]

    /// 喂一轮观察。cpuPercent = 本轮差分 CPU%(nil = 新出生进程,尚无差分,
    /// 只立首见基线不判活动——不伪造 0)。
    mutating func observe(pid: pid_t, cpuPercent: Double?, now: Date) {
        if firstSeen[pid] == nil { firstSeen[pid] = now }
        if let cpuPercent, cpuPercent >= Self.activityCPUThreshold {
            lastActivity[pid] = now
        }
    }

    /// 闲置秒数;nil = 最近窗口内有活动(未闲置)。
    func idleSeconds(pid: pid_t, now: Date) -> TimeInterval? {
        guard let anchor = lastActivity[pid] ?? firstSeen[pid] else { return nil }
        let sinceActivity = now.timeIntervalSince(anchor)
        return sinceActivity >= Self.idleWindow ? sinceActivity : nil
    }

    /// 进程消失即清状态(pid 复用不会继承旧闲置史)。
    mutating func prune(alive: Set<pid_t>) {
        firstSeen = firstSeen.filter { alive.contains($0.key) }
        lastActivity = lastActivity.filter { alive.contains($0.key) }
    }
}

// MARK: - 盘点状态与编排

/// 卡片的一行 dev server:闲置时长 / 内存 / 监听端口。
struct DevServerStatus: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let kind: DevServerKind
    let displayName: String
    /// 物理足迹(活动监视器"内存"列口径,字节)。
    let memoryBytes: UInt64
    /// 闲置秒数;nil = 最近 10 分钟内有活动(未闲置)。
    let idleSeconds: TimeInterval?
    /// 监听中的 TCP 端口(升序去重;扫描失败/受限为空,不伪造)。
    let listeningPorts: [UInt16]

    var id: pid_t { pid }
    /// "闲置"标签:最近 10 分钟 CPU≈0(GLOSSARY)。
    var isIdle: Bool { idleSeconds != nil }
}

/// 盘点编排:分类 → 只对候选喂闲置环并扫端口 → 合成状态。
/// 有状态(闲置环)但全部时刻注入;端口扫描走缝,单测注入计数假实现。
struct DevServerFinder: Sendable {
    let portScanner: any DevServerPortScanning
    private var tracker = DevServerIdleTracker()

    /// 推进一轮:返回本轮 dev server 状态(快照序)。
    mutating func update(
        snapshot: ProcessSnapshot,
        processCPU: [pid_t: Double],
        now: Date
    ) -> [DevServerStatus] {
        var candidates: [(process: RawProcess, match: DevServerMatch)] = []
        for process in snapshot.processes {
            if let match = DevServerClassifier.classify(argv: process.argv) {
                candidates.append((process, match))
            }
        }
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
}

// MARK: - 端口扫描缝

/// 端口扫描接缝:真实现 libproc 直调(PROC_PIDLISTFDS + PROC_PIDFDINFO_SOCKET),
/// 单测注入假实现记录被扫描的 pid(成本约束的断言点)。
protocol DevServerPortScanning: Sendable {
    /// 该 pid 监听中的 TCP 端口(升序去重);进程不存在/受限 → 空数组。
    func listeningPorts(pid: pid_t) -> [UInt16]
}

/// libproc 薄适配器:列 fd → 逐 socket fd 查 TCP 监听状态与本地端口。
/// 只读系统账,不发包不连接;进程退出/受限查询静默降级为空。
struct LiveDevServerPortScanner: DevServerPortScanning {
    /// TCP 监听态(TSI_S_LISTEN,sys/proc_info.h 的 #define 不进 Swift,值钉死
    /// 与 netinet/tcp_fsm.h 的 TCPS_LISTEN 同值)。
    private static let tcpStateListen: Int32 = 1

    func listeningPorts(pid: pid_t) -> [UInt16] {
        let fdStride = MemoryLayout<proc_fdinfo>.stride
        // 尺寸探测:buffersize = 0 时返回需要的字节数(失败/进程已退 → ≤0)。
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / fdStride)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, needed)
        guard written > 0 else { return [] }
        let count = Int(written) / fdStride

        var ports = Set<UInt16>()
        for index in 0..<count {
            guard fds[index].proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            var info = socket_fdinfo()
            let result = proc_pidfdinfo(
                pid, fds[index].proc_fd, PROC_PIDFDSOCKETINFO,
                &info, Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard result == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            // 只看 TCP 监听(IPv4/IPv6);UDP/Unix 域/已连接的 TCP 都不算服务口。
            guard info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == Self.tcpStateListen
            else { continue }
            // 本地端口是 int 里的网络序 16 位。
            let raw = UInt32(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
                & 0xFFFF
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
            if port != 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}
