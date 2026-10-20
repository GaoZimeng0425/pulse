import Foundation

// MARK: - 组(GLOSSARY):归组引擎的输出单位

/// 组的类别:三层归属产出 App / 项目两类;兜底三分类产出系统 / 后台服务 / 孤儿进程。
public enum GroupCategory: String, Equatable, Sendable, CaseIterable {
    case app
    case project
    case system
    case backgroundService
    case orphan
}

/// 组的类型化稳定身份(工单 00):种类即 case,稳定原始值即关联值——
/// "拿任意字符串当组 ID"自此成为编译错误。与 `GroupCategory` 1:1 映射
/// (`category`,展示口径继续吃类别),`stableKey` 逐字节复现 P0 前缀约定的
/// 规范字符串("bundle:<path>" / "project:<root>[@<worktree>]" / "system" /
/// "background-service" / "orphan"),Comparable 即 stableKey 字典序——
/// 与升级前纯字符串 id 的次键排序逐位一致,升级零行为变化。
/// 历史管线(工单 03)的分钟/小时表与出生登记都将以它做键。
public enum GroupIdentity: Hashable, Sendable, Comparable {
    /// App 组:稳定原始值 = 最外层 `.app` bundle 目录(容器口径见 appContainerPrefix)。
    case app(bundlePath: String)
    /// 项目组:项目根 + worktree 名(命中非 worktree 路径时为 nil)。
    case project(root: String, worktreeName: String?)
    /// 系统组(知名系统进程固定聚合,无原始值)。
    case system
    /// 后台服务组(launchd 域聚合,无原始值)。
    case backgroundService
    /// 孤儿进程组(断链无归属聚合,无原始值)。
    case orphan

    /// 组类别(种类 1:1 派生):图例 / 图标样式等展示口径的既有通道。
    public var category: GroupCategory {
        switch self {
        case .app: .app
        case .project: .project
        case .system: .system
        case .backgroundService: .backgroundService
        case .orphan: .orphan
        }
    }

    /// App 组的 .app bundle 目录;其余种类为 nil。
    public var bundlePath: String? {
        if case .app(let bundlePath) = self { return bundlePath }
        return nil
    }

    /// 规范字符串:与 P0 前缀约定的组 id 完全一致。只用于排序的稳定次键与
    /// 将来的持久化键,不再充当身份本身——字符串造不出组身份。
    public var stableKey: String {
        switch self {
        case .app(let bundlePath): "bundle:" + bundlePath
        case .project(let root, let worktreeName):
            "project:" + root + (worktreeName.map { "@\($0)" } ?? "")
        case .system: "system"
        case .backgroundService: "background-service"
        case .orphan: "orphan"
        }
    }

    public static func < (lhs: GroupIdentity, rhs: GroupIdentity) -> Bool {
        lhs.stableKey < rhs.stableKey
    }
}

/// 组(GLOSSARY):若干进程聚合成的一个显示实体——稳定身份、显示名、类别与聚合指标。
/// `processes` 保留进程明细(cwd / argv / 启动时刻),供下钻(工单 06)直接取用,
/// 不需回查采集层。
public struct ProcessGroup: Identifiable, Equatable, Sendable {
    /// 类型化稳定身份(工单 00):跨快照可比,类别与 bundle 目录由它派生——
    /// 身份只有这一份,历史管线(工单 03)以它做键。
    public let id: GroupIdentity
    /// 显示名(bundle 显示名 / "项目名 @ worktree" / 兜底类别名)。
    public let name: String
    /// 组类别:身份种类的 1:1 派生(图例 / 图标样式等展示口径)。
    public var category: GroupCategory { id.category }
    /// App 组的 .app bundle 目录,供 UI 取应用图标(工单 05);其余类别为 nil。
    public var bundlePath: String? { id.bundlePath }
    /// 组内进程,按进程 CPU% 降序(次键 pid 升序)——下钻列表的既定顺序。
    public let processes: [RawProcess]
    /// 组 CPU%(GLOSSARY):组内全部进程 CPU% 之和,单核 100% 累加,可超过 100%。
    public let cpuPercent: Double
    /// 组内聚合内存 = 各进程物理足迹之和(活动监视器"内存"列口径),字节。
    public let memoryBytes: UInt64

    public init(
        id: GroupIdentity,
        name: String,
        processes: [RawProcess],
        cpuPercent: Double,
        memoryBytes: UInt64
    ) {
        self.id = id
        self.name = name
        self.processes = processes
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

// MARK: - 配置

/// 归组配置:项目根列表 + 系统可执行文件名单 + launchd 服务清单 + bundle 显示名解析。
/// 全部为调用方注入的纯数据/纯函数——引擎不读磁盘:
/// CFBundleName 由 UI 层注入读取器(工单 05),缺省退化为 bundle 目录名去掉 .app 后缀;
/// launchd 服务清单由 app 侧低频传感器扫 plist 后整份注入(launchd-attribution/01)。
///
/// 项目归因不设可执行名门槛(评审 S4):到达项目归因层(未先被 App 归属)
/// 的进程,只要 cwd / argv 路径命中项目根即归项目——zig / bazel 等"名单外"
/// 工具与 rustc / node 同权。历史上的 dev 可执行名单已随该评审移除。
public struct GroupingConfiguration: Sendable {
    /// 项目根(GLOSSARY):用户配置的绝对路径(已展开 ~)。引擎只做路径前缀匹配。
    public var projectRoots: [String]
    /// 知名系统进程的可执行文件名(kernel_task / WindowServer / launchd)。
    /// 优先于 App 归属判定(WindowServer 自身路径就在 .app bundle 里),
    /// 且系统归属不可被子进程继承——launchd 的孩子们仍按自己的链路归组。
    public var systemExecutableNames: Set<String>
    /// launchd 服务清单(GLOSSARY,launchd-attribution/01 / ADR-0005):本机 launchd 各标准
    /// plist 目录声明的服务程序路径集合(字面路径与其 realpath 并存),兜底分类时与静态
    /// launchd 域并列判定后台服务。缺省空集 ⇒ 行为与引入前逐位一致(只剩静态域)。
    public var launchdServiceExecutablePaths: Set<String>
    /// bundle 显示名解析器:输入 .app 目录路径,返回 CFBundleName;返回 nil 则用目录名推导。
    public var bundleDisplayName: @Sendable (_ bundleDirectory: String) -> String?

    public init(
        projectRoots: [String] = [],
        systemExecutableNames: Set<String> = GroupingConfiguration.defaultSystemExecutableNames,
        launchdServiceExecutablePaths: Set<String> = [],
        bundleDisplayName: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.projectRoots = projectRoots
        self.systemExecutableNames = systemExecutableNames
        self.launchdServiceExecutablePaths = launchdServiceExecutablePaths
        self.bundleDisplayName = bundleDisplayName
    }

    /// 缺省系统进程名单(spec 兜底三分类举例 + launchd 本体)。
    public static let defaultSystemExecutableNames: Set<String> = ["kernel_task", "WindowServer", "launchd"]
}

// MARK: - 归组引擎

/// 归组引擎(纯函数,GLOSSARY 三层归属 + 兜底三分类)。
///
/// 输入 = 一次快照 + 出生登记表 + 项目根列表(+ 按 pid 的进程 CPU%);
/// 输出 = 按组 CPU% 降序(次键 id 升序)的组列表。同输入同输出,不持 OS 状态。
///
/// 每个进程的判定顺序:
/// 1. App 归属——自身可执行在 `.app` 容器内(容器口径见 `appContainerPrefix`:
///    含 `.app/Contents/MacOS/` 全盘生效;/Applications、/Users 下的容器助手
///    ——Frameworks、XPCServices、.appex——也归最外层宿主 .app,断链的
///    crashpad_handler、Sparkle Autoupdate 因此不再落孤儿);
/// 2. 项目归因——按 cwd 优先、argv 中路径次之与项目根前缀匹配,
///    命中 `.worktrees/<名>` 显示"项目名 @ 名"。不看可执行名(评审 S4:
///    名单闸已解除——cwd/argv 命中即归项目,zig 与 rustc 同权)。
///    放在父链上溯之前:验收锚点要求 rustc ← cargo ← node ← Zcode
///    归"项目 @ worktree",而不是归到拉起它的 Zcode;
/// 3. 父链上溯——非 bundle、无项目归因的进程沿活 ppid 链向上找有归属的祖先;
///    断链(中间父进程已死 / 被重挂到 launchd)时回查出生登记的父链;
/// 4. 兜底三分类——系统(知名系统进程,优先于第 1 步)/ 后台服务(launchd 域
///    推断:出生或现挂在 launchd 之下,且可执行位于 launchd 域——见
///    `isLaunchdDomainExecutablePath`——或命中配置注入的 launchd 服务清单,
///    launchd-attribution/01)/ 孤儿进程(其余断链者——含父为 launchd 但可执行
///    既不在域内也不在清单里、且无归属可继承的进程,评审 S3)。
///
/// CPU 接缝:进程 CPU% 由工单 04 的差分器从相邻快照算出后按 pid 传入;
/// 引擎只做求和,不接触时间。缺失条目按 0 计。
public enum GroupingEngine {
    /// 归组主入口。
    public static func groups(
        from snapshot: ProcessSnapshot,
        lineage: LineageRegistry = LineageRegistry(),
        configuration: GroupingConfiguration = GroupingConfiguration(),
        cpuPercentByPID: [pid_t: Double] = [:],
        selfAttributionCache: SelfAttributionCache? = nil
    ) -> [ProcessGroup] {
        let resolver = Resolver(
            snapshot: snapshot, lineage: lineage, configuration: configuration, cache: selfAttributionCache
        )
        defer { selfAttributionCache?.commitRound() }

        // 兜底三分类保证每个进程都有归属——榜单完整,没有漏网之鱼(用户故事 18)。
        var attributionByPID: [pid_t: Attribution] = [:]
        for process in snapshot.processes where attributionByPID[process.pid] == nil {
            attributionByPID[process.pid] = resolver.finalAttribution(for: process)
        }

        var membersByID: [GroupIdentity: [RawProcess]] = [:]
        var attributionByID: [GroupIdentity: Attribution] = [:]
        var memberPIDs: Set<pid_t> = []
        for process in snapshot.processes {
            guard memberPIDs.insert(process.pid).inserted,
                  let attribution = attributionByPID[process.pid] else { continue }
            membersByID[attribution.id, default: []].append(process)
            attributionByID[attribution.id] = attribution
        }

        // 组内进程序与组序同走 Leaderboard 内核:CPU% 降序,同值次键 pid / 组身份升序。
        let unranked = membersByID.map { id, members -> ProcessGroup in
            let attribution = attributionByID[id]!
            let sortedMembers = Leaderboard.ranked(members, by: { cpuPercentByPID[$0.pid] ?? 0 }, id: \.pid)
            let cpu = members.reduce(0.0) { $0 + (cpuPercentByPID[$1.pid] ?? 0) }
            let memory = members.reduce(UInt64(0)) { $0 + $1.physicalFootprintBytes }
            return ProcessGroup(
                id: id,
                name: attribution.name,
                processes: sortedMembers,
                cpuPercent: cpu,
                memoryBytes: memory
            )
        }
        return Leaderboard.ranked(unranked, by: \.cpuPercent, id: \.id)
    }

    /// App 归属判定的路径谓词:`.app` 容器内的进程。父链面包屑(工单 06)复用
    /// 同一口径,判定只有这一份。容器口径见 `appContainerPrefix`。
    public static func isBundleExecutablePath(_ executablePath: String?) -> Bool {
        appContainerPrefix(executablePath) != nil
    }

    /// `.app` 容器判定与归属提取(`isBundleExecutablePath` 与
    /// `outermostAppBundleDirectory` 共用的唯一口径):
    /// - 严格口径:路径含 `.app/Contents/MacOS/`,全盘生效(含 /System 下的
    ///   系统 App),归属取**最外层** `.app`——嵌套 Helper.app 因此跟随宿主
    ///   Google Chrome.app;
    /// - 放宽口径(2026-10-16):/Applications、/Users 下的 `.app` 容器内进程
    ///   (Contents/Frameworks、XPCServices、PlugIns/*.appex、*.framework,
    ///   典型:断链成 launchd 子进程的 crashpad_handler、Sparkle Autoupdate、
    ///   App 扩展)同归宿主 `.app`;系统域(/System、/usr、/Library)不放宽,
    ///   留给 launchd 域判定(后台服务),避免系统代理散成一堆 bundle 组。
    public static func appContainerPrefix(_ executablePath: String?) -> (prefix: String, strict: Bool)? {
        guard let path = executablePath, !path.isEmpty else { return nil }
        let strict = path.contains(".app/Contents/MacOS/")
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated += "/" + component
            if component.hasSuffix(".app") {
                if strict { return (accumulated, true) }
                if accumulated.hasPrefix("/Applications/") || accumulated.hasPrefix("/Users/") {
                    return (accumulated, false)
                }
            }
        }
        return nil
    }

    /// 后台服务的 launchd 域推断谓词(评审 S3,spec"后台服务 = launchd 域推断"):
    /// 可执行位于系统/厂商守护的标准驻地——/Library/LaunchAgents|LaunchDaemons、
    /// /System/Library、/Library/SystemExtensions(系统扩展)、
    /// /Library/PrivilegedHelperTools(特权助手惯例位)、/Library/Developer
    /// (CoreSimulator/CoreDevice 开发守护)、/usr/sbin、/usr/libexec——
    /// 或用户级 LaunchAgent 域(任意家目录下 ~/Library/LaunchAgents)。
    /// 2026-10-16 前只认前三个前缀:/usr/{sbin,libexec} 的 ~200 个 Apple 系统
    /// 守护(logd/configd/securityd…)全被误成孤儿进程,孤儿桶因此虚胖。
    /// 仍不算域:/usr/bin(用户一次性命令 ssh/python3 不该读成后台服务)、
    /// /usr/local、/opt/homebrew(自装常驻——S3 的本意就是不并它们)。
    /// 本谓词保持纯静态前缀,判定只有这一份;驻地非标准但确实在 launchd 注册的
    /// 第三方守护由 launchd 服务清单(`GroupingConfiguration.launchdServiceExecutablePaths`,
    /// launchd-attribution/01 / ADR-0005)在兜底分类处与本谓词并列兜住,不并进这里。
    public static func isLaunchdDomainExecutablePath(_ executablePath: String?) -> Bool {
        guard let path = executablePath, !path.isEmpty else { return false }
        if path.hasPrefix("/Library/LaunchAgents/")
            || path.hasPrefix("/Library/LaunchDaemons/")
            || path.hasPrefix("/System/Library/")
            || path.hasPrefix("/Library/SystemExtensions/")
            || path.hasPrefix("/Library/PrivilegedHelperTools/")
            || path.hasPrefix("/Library/Developer/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/usr/libexec/")
        {
            return true
        }
        // 用户级 LaunchAgent 域:任意家目录(/Users/<名>/Library/LaunchAgents)。
        return path.hasPrefix("/Users/") && path.contains("/Library/LaunchAgents/")
    }
}

// MARK: - 归属判定

/// 单进程的归属判定结果(聚合前):身份 + 显示名;类别与 bundle 目录由身份派生。
private struct Attribution: Equatable {
    public let id: GroupIdentity
    public let name: String
}

extension Attribution {
    /// 兜底三分类的固定组:同名进程聚合进各自类别的单一组。
    public static let systemGroup = Attribution(id: .system, name: "系统")
    public static let backgroundServiceGroup = Attribution(id: .backgroundService, name: "后台服务")
    public static let orphanGroup = Attribution(id: .orphan, name: "孤儿进程")
}

/// 跨轮的「自身归属」缓存(arch-review-2026-10-18/04):自身归属(App 归属 / 项目归因)
/// 只取决于进程身份三元组与项目根,绝大多数进程跨轮不变,却每轮都要拆路径、逐个 argv
/// 匹配项目根(实测占归组约七成)。按 pid 存「身份 + 结果」,下一轮身份相同即复用;身份
/// 变了(pid 复用 / exec)或项目根变了就重算。每轮只带走本轮查过的 pid,自然随在场进程
/// 收缩。由 GroupingPipeline 跨轮持有;不传则逐轮从头算(引擎仍是纯函数)。
public final class SelfAttributionCache {
    fileprivate struct Slot {
        public let identity: ProcessIdentity
        public let attribution: Attribution?
    }

    private var previous: [pid_t: Slot] = [:]
    private var current: [pid_t: Slot] = [:]
    private var roots: [String]?

    /// 本轮开始:项目根变了则整表作废。
    fileprivate func prepare(roots: [String]) {
        guard roots != self.roots else { return }
        self.roots = roots
        previous = [:]
        current = [:]
    }

    fileprivate func attribution(
        for pid: pid_t,
        identity: ProcessIdentity,
        compute: () -> Attribution?
    ) -> Attribution? {
        if let slot = current[pid], slot.identity == identity { return slot.attribution }
        let slot: Slot
        if let cached = previous[pid], cached.identity == identity {
            slot = cached
        } else {
            slot = Slot(identity: identity, attribution: compute())
        }
        current[pid] = slot
        return slot.attribution
    }

    /// 本轮结束:只留本轮查过的 pid。
    fileprivate func commitRound() {
        previous = current
        current = [:]
    }

    public init() {}
}

/// 一次 `groups` 调用私有的判定器:持有快照 / 登记表 / 配置与逐 pid 记忆化缓存。
/// 生命周期限于单次调用;跨轮的自身归属缓存由调用方可选传入。
private final class Resolver {
    private let configuration: GroupingConfiguration
    /// 归一化并按长度降序的项目根:多根命中取最长(最具体)根。
    private let normalizedRoots: [String]
    private let processesByPID: [pid_t: RawProcess]
    private let lineage: LineageRegistry
    private let cache: SelfAttributionCache?
    /// pid → 三层归属解析结果(nil = 无三层归属)。缓存含"经继承得到的归属"。
    private var layerMemo: [pid_t: LayerResolution] = [:]

    /// 三层归属的解析结果 + 活链是否途经存活的 launchd(后台服务判定信号)。
    private struct LayerResolution {
        public let attribution: Attribution?
        public let reachedLiveLaunchd: Bool
    }

    public init(
        snapshot: ProcessSnapshot,
        lineage: LineageRegistry,
        configuration: GroupingConfiguration,
        cache: SelfAttributionCache?
    ) {
        self.configuration = configuration
        self.normalizedRoots = configuration.projectRoots
            .map(PathNormalization.normalize)
            .sorted { $0.count > $1.count }
        self.processesByPID = snapshot.processesByPID
        self.lineage = lineage
        self.cache = cache
        cache?.prepare(roots: normalizedRoots)
    }

    // MARK: 最终归属(三层 + 兜底)

    public func finalAttribution(for process: RawProcess) -> Attribution {
        // 系统判定优先于 App 归属:WindowServer 的路径本身就在 .app bundle 里。
        if configuration.systemExecutableNames
            .contains(executableName(executablePath: process.executablePath, argv: process.argv))
        {
            return .systemGroup
        }
        let resolution = layerResolution(for: process.pid)
        if let attribution = resolution.attribution {
            return attribution
        }
        // 三层全部落空 → 兜底三分类(评审 S3):后台服务 = 挂在 launchd 之下
        // (出生时或现在)且可执行位于 launchd 域或命中 launchd 服务清单
        // (launchd-attribution/01);其余——含父为 launchd 但可执行既不在域内也不在
        // 清单里的重启后无名者——一律孤儿进程。
        let birth = lineage.entries[process.pid]
        let underLaunchd: Bool
        let domainCandidatePath: String?
        if let birth {
            // 出生时父即 launchd 才可能算 launchd 域服务;出生时有真实父
            // (现已死)且登记链无归属可继承 → 孤儿。
            underLaunchd = birth.parentPID == 1
            domainCandidatePath = birth.executablePath ?? process.executablePath
        } else {
            underLaunchd = resolution.reachedLiveLaunchd
            domainCandidatePath = process.executablePath
        }
        return underLaunchd && isLaunchdServiceExecutable(domainCandidatePath)
            ? .backgroundServiceGroup
            : .orphanGroup
    }

    /// 后台服务的可执行判据(兜底分类的条件 b):静态 launchd 域,或命中注入的
    /// launchd 服务清单(全等匹配;字面与 realpath 两种形态都已在清单里,引擎不解
    /// 符号链接——那是 IO,ADR-0005)。清单为空集时与引入前逐位一致。
    private func isLaunchdServiceExecutable(_ executablePath: String?) -> Bool {
        if GroupingEngine.isLaunchdDomainExecutablePath(executablePath) { return true }
        guard let executablePath else { return false }
        return configuration.launchdServiceExecutablePaths.contains(executablePath)
    }

    // MARK: 三层归属:自身 → 活链 → 登记链

    /// pid 的三层归属:自身可判定归属 → 活链上溯 → 出生登记回查。带记忆化。
    private func layerResolution(for pid: pid_t) -> LayerResolution {
        if let memoized = layerMemo[pid] {
            return memoized
        }

        var attribution: Attribution?
        var reachedLiveLaunchd = false
        var visited: Set<pid_t> = []
        var currentPID = pid

        while visited.insert(currentPID).inserted { // 环(异常父链)安全终止
            if let memoized = layerMemo[currentPID] {
                attribution = memoized.attribution
                reachedLiveLaunchd = reachedLiveLaunchd || memoized.reachedLiveLaunchd
                break
            }
            guard let process = processesByPID[currentPID] else {
                break // 父不在快照:活链断(中间父进程已死)
            }
            if let own = layerSelf(process) {
                attribution = own
                break
            }
            if process.pid == 1 {
                reachedLiveLaunchd = true // 途经存活的 launchd,继续上溯(它自身无三层归属)
            }
            currentPID = process.parentPID
        }

        if attribution == nil {
            attribution = registryChainAttribution(from: pid)
        }

        let resolution = LayerResolution(attribution: attribution, reachedLiveLaunchd: reachedLiveLaunchd)
        layerMemo[pid] = resolution
        return resolution
    }

    /// 进程自身可判定的两层归属:App 归属(bundle)→ 项目归因(项目根前缀)。
    /// 这两层可被子进程与登记链继承;系统 / 兜底归属不可继承。
    /// 项目归因不看可执行名(评审 S4):到达此层的非 bundle 进程,
    /// cwd / argv 路径命中项目根即归项目。输入即归属三元组(ProcessIdentity,
    /// D1 收拢)——快照进程与出生登记的祖先同一份形状。
    private func layerSelf(_ identity: ProcessIdentity) -> Attribution? {
        if let bundle = Self.outermostAppBundleDirectory(identity.executablePath) {
            return Attribution(
                id: .app(bundlePath: bundle),
                name: bundleDisplayName(forBundleDirectory: bundle)
            )
        }
        // 项目归因:cwd 优先,argv 中的路径次之。
        guard let match = projectMatch(identity.cwd) ?? argvProjectMatch(identity.argv) else { return nil }
        let projectName = Self.rootDisplayName(match.root)
        return Attribution(
            id: .project(root: match.root, worktreeName: match.worktreeName),
            name: match.worktreeName.map { "\(projectName) @ \($0)" } ?? projectName
        )
    }

    /// 在场进程的自身归属:有跨轮缓存时按 pid + 身份复用。
    private func layerSelf(_ process: RawProcess) -> Attribution? {
        guard let cache else { return layerSelf(process.identity) }
        return cache.attribution(for: process.pid, identity: process.identity) {
            layerSelf(process.identity)
        }
    }

    /// 出生登记回查(GLOSSARY 活链断裂后的归属来源):沿出生父链找有归属的祖先,
    /// 祖先的归属由其出生记录自身的字段判定。登记无该进程 / 链上无归属 → nil。
    private func registryChainAttribution(from pid: pid_t) -> Attribution? {
        var visited: Set<pid_t> = []
        var currentPID = pid
        while let entry = lineage.entries[currentPID], visited.insert(currentPID).inserted {
            guard let parent = lineage.entries[entry.parentPID] else { return nil }
            if let attribution = layerSelf(parent.identity) {
                return attribution
            }
            currentPID = entry.parentPID
        }
        return nil
    }

    // MARK: 路径判定

    /// bundle 显示名:注入的 CFBundleName 读取器优先,缺省退化为目录名去掉 .app 后缀。
    private func bundleDisplayName(forBundleDirectory bundle: String) -> String {
        if let injected = configuration.bundleDisplayName(bundle) {
            return injected
        }
        let directoryName = String(bundle.split(separator: "/").last ?? Substring(bundle))
        return directoryName.hasSuffix(".app") ? String(directoryName.dropLast(4)) : directoryName
    }

    /// 进程可执行文件名:路径 basename;路径缺失(proc_pidpath 受限)时退回 argv[0] 的 basename。
    private func executableName(executablePath: String?, argv: [String]) -> String {
        if let path = executablePath {
            return String(path.split(separator: "/").last ?? Substring())
        }
        if let firstArgument = argv.first {
            return String(firstArgument.split(separator: "/").last ?? Substring())
        }
        return ""
    }

    // MARK: 项目归因

    /// 项目根命中:root + worktree 名(命中 `.worktrees/<名>` 时非 nil)。
    private struct ProjectMatch: Equatable {
        public let root: String
        public let worktreeName: String?
    }

    /// 项目根前缀匹配(按路径组件对齐;多根命中取最长根)。
    private func projectMatch(_ path: String?) -> ProjectMatch? {
        guard let path else { return nil }
        let normalized = PathNormalization.normalize(path)
        for root in normalizedRoots {
            if normalized == root || normalized.hasPrefix(root + "/") {
                let remainder = normalized == root
                    ? ""
                    : String(normalized.dropFirst(root.count + 1))
                let components = remainder.split(separator: "/").map(String.init)
                let worktreeName = components.count >= 2 && components[0] == ".worktrees"
                    ? components[1]
                    : nil
                return ProjectMatch(root: root, worktreeName: worktreeName)
            }
        }
        return nil
    }

    /// argv 中路径的项目根匹配:按参数顺序取第一个命中。
    private func argvProjectMatch(_ argv: [String]) -> ProjectMatch? {
        for argument in argv {
            if let match = projectMatch(argument) {
                return match
            }
        }
        return nil
    }

    /// 最外层 .app bundle 目录:容器口径见 `appContainerPrefix`(严格 + 放宽
    /// 两档,判定只有这一份),归属一律取路径中**最外层** `.app` 目录组件。
    private static func outermostAppBundleDirectory(_ executablePath: String?) -> String? {
        GroupingEngine.appContainerPrefix(executablePath)?.prefix
    }

    /// 项目名 = 项目根最后一级目录名。
    private static func rootDisplayName(_ root: String) -> String {
        String(root.split(separator: "/").last ?? Substring(root))
    }
}
