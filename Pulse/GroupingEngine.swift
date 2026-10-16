import Foundation

// MARK: - 组(GLOSSARY):归组引擎的输出单位

/// 组的类别:三层归属产出 App / 项目两类;兜底三分类产出系统 / 后台服务 / 孤儿进程。
enum GroupCategory: String, Equatable, Sendable, CaseIterable {
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
enum GroupIdentity: Hashable, Sendable, Comparable {
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
    var category: GroupCategory {
        switch self {
        case .app: .app
        case .project: .project
        case .system: .system
        case .backgroundService: .backgroundService
        case .orphan: .orphan
        }
    }

    /// App 组的 .app bundle 目录;其余种类为 nil。
    var bundlePath: String? {
        if case .app(let bundlePath) = self { return bundlePath }
        return nil
    }

    /// 规范字符串:与 P0 前缀约定的组 id 完全一致。只用于排序的稳定次键与
    /// 将来的持久化键,不再充当身份本身——字符串造不出组身份。
    var stableKey: String {
        switch self {
        case .app(let bundlePath): "bundle:" + bundlePath
        case .project(let root, let worktreeName):
            "project:" + root + (worktreeName.map { "@\($0)" } ?? "")
        case .system: "system"
        case .backgroundService: "background-service"
        case .orphan: "orphan"
        }
    }

    static func < (lhs: GroupIdentity, rhs: GroupIdentity) -> Bool {
        lhs.stableKey < rhs.stableKey
    }
}

/// 组(GLOSSARY):若干进程聚合成的一个显示实体——稳定身份、显示名、类别与聚合指标。
/// `processes` 保留进程明细(cwd / argv / 启动时刻),供下钻(工单 06)直接取用,
/// 不需回查采集层。
struct ProcessGroup: Identifiable, Equatable, Sendable {
    /// 类型化稳定身份(工单 00):跨快照可比,类别与 bundle 目录由它派生——
    /// 身份只有这一份,历史管线(工单 03)以它做键。
    let id: GroupIdentity
    /// 显示名(bundle 显示名 / "项目名 @ worktree" / 兜底类别名)。
    let name: String
    /// 组类别:身份种类的 1:1 派生(图例 / 图标样式等展示口径)。
    var category: GroupCategory { id.category }
    /// App 组的 .app bundle 目录,供 UI 取应用图标(工单 05);其余类别为 nil。
    var bundlePath: String? { id.bundlePath }
    /// 组内进程,按进程 CPU% 降序(次键 pid 升序)——下钻列表的既定顺序。
    let processes: [RawProcess]
    /// 组 CPU%(GLOSSARY):组内全部进程 CPU% 之和,单核 100% 累加,可超过 100%。
    let cpuPercent: Double
    /// 组内聚合内存 = 各进程物理足迹之和(活动监视器"内存"列口径),字节。
    let memoryBytes: UInt64
}

// MARK: - 配置

/// 归组配置:项目根列表 + 系统可执行文件名单 + bundle 显示名解析。
/// 全部为调用方注入的纯数据/纯函数——引擎不读磁盘:
/// CFBundleName 由 UI 层注入读取器(工单 05),缺省退化为 bundle 目录名去掉 .app 后缀。
///
/// 项目归因不设可执行名门槛(评审 S4):到达项目归因层(未先被 App 归属)
/// 的进程,只要 cwd / argv 路径命中项目根即归项目——zig / bazel 等"名单外"
/// 工具与 rustc / node 同权。历史上的 dev 可执行名单已随该评审移除。
struct GroupingConfiguration: Sendable {
    /// 项目根(GLOSSARY):用户配置的绝对路径(已展开 ~)。引擎只做路径前缀匹配。
    var projectRoots: [String]
    /// 知名系统进程的可执行文件名(kernel_task / WindowServer / launchd)。
    /// 优先于 App 归属判定(WindowServer 自身路径就在 .app bundle 里),
    /// 且系统归属不可被子进程继承——launchd 的孩子们仍按自己的链路归组。
    var systemExecutableNames: Set<String>
    /// bundle 显示名解析器:输入 .app 目录路径,返回 CFBundleName;返回 nil 则用目录名推导。
    var bundleDisplayName: @Sendable (_ bundleDirectory: String) -> String?

    init(
        projectRoots: [String] = [],
        systemExecutableNames: Set<String> = GroupingConfiguration.defaultSystemExecutableNames,
        bundleDisplayName: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.projectRoots = projectRoots
        self.systemExecutableNames = systemExecutableNames
        self.bundleDisplayName = bundleDisplayName
    }

    /// 缺省系统进程名单(spec 兜底三分类举例 + launchd 本体)。
    static let defaultSystemExecutableNames: Set<String> = ["kernel_task", "WindowServer", "launchd"]
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
///    推断:出生或现挂在 launchd 之下,且可执行位于 launchd 域,
///    见 `isLaunchdDomainExecutablePath`)/ 孤儿进程(其余断链者——含
///    父为 launchd 但可执行不在域内、且无归属可继承的进程,评审 S3)。
///
/// CPU 接缝:进程 CPU% 由工单 04 的差分器从相邻快照算出后按 pid 传入;
/// 引擎只做求和,不接触时间。缺失条目按 0 计。
enum GroupingEngine {
    /// 归组主入口。
    static func groups(
        from snapshot: ProcessSnapshot,
        lineage: LineageRegistry = LineageRegistry(),
        configuration: GroupingConfiguration = GroupingConfiguration(),
        cpuPercentByPID: [pid_t: Double] = [:]
    ) -> [ProcessGroup] {
        let resolver = Resolver(snapshot: snapshot, lineage: lineage, configuration: configuration)

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

        return membersByID.map { id, members -> ProcessGroup in
            let attribution = attributionByID[id]!
            let sortedMembers = members.sorted { lhs, rhs in
                let lhsCPU = cpuPercentByPID[lhs.pid] ?? 0
                let rhsCPU = cpuPercentByPID[rhs.pid] ?? 0
                return lhsCPU == rhsCPU ? lhs.pid < rhs.pid : lhsCPU > rhsCPU
            }
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
        .sorted { $0.cpuPercent == $1.cpuPercent ? $0.id < $1.id : $0.cpuPercent > $1.cpuPercent }
    }

    /// App 归属判定的路径谓词:`.app` 容器内的进程。父链面包屑(工单 06)复用
    /// 同一口径,判定只有这一份。容器口径见 `appContainerPrefix`。
    static func isBundleExecutablePath(_ executablePath: String?) -> Bool {
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
    static func appContainerPrefix(_ executablePath: String?) -> (prefix: String, strict: Bool)? {
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
    /// 判定只有这一份;P1 可升级为真实读取 launchd 任务清单。
    static func isLaunchdDomainExecutablePath(_ executablePath: String?) -> Bool {
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
    let id: GroupIdentity
    let name: String
}

extension Attribution {
    /// 兜底三分类的固定组:同名进程聚合进各自类别的单一组。
    static let systemGroup = Attribution(id: .system, name: "系统")
    static let backgroundServiceGroup = Attribution(id: .backgroundService, name: "后台服务")
    static let orphanGroup = Attribution(id: .orphan, name: "孤儿进程")
}

/// 一次 `groups` 调用私有的判定器:持有快照 / 登记表 / 配置与逐 pid 记忆化缓存。
/// 生命周期限于单次调用,引擎整体仍是纯函数。
private final class Resolver {
    private let configuration: GroupingConfiguration
    /// 归一化并按长度降序的项目根:多根命中取最长(最具体)根。
    private let normalizedRoots: [String]
    private let processesByPID: [pid_t: RawProcess]
    private let lineage: LineageRegistry
    /// pid → 三层归属解析结果(nil = 无三层归属)。缓存含"经继承得到的归属"。
    private var layerMemo: [pid_t: LayerResolution] = [:]

    /// 三层归属的解析结果 + 活链是否途经存活的 launchd(后台服务判定信号)。
    private struct LayerResolution {
        let attribution: Attribution?
        let reachedLiveLaunchd: Bool
    }

    init(snapshot: ProcessSnapshot, lineage: LineageRegistry, configuration: GroupingConfiguration) {
        self.configuration = configuration
        self.normalizedRoots = configuration.projectRoots
            .map(PathNormalization.normalize)
            .sorted { $0.count > $1.count }
        self.processesByPID = snapshot.processesByPID
        self.lineage = lineage
    }

    // MARK: 最终归属(三层 + 兜底)

    func finalAttribution(for process: RawProcess) -> Attribution {
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
        // (出生时或现在)且可执行位于 launchd 域;其余——含父为 launchd 但
        // 可执行不在域内的重启后无名者——一律孤儿进程。
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
        return underLaunchd && GroupingEngine.isLaunchdDomainExecutablePath(domainCandidatePath)
            ? .backgroundServiceGroup
            : .orphanGroup
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

    private func layerSelf(_ process: RawProcess) -> Attribution? {
        layerSelf(process.identity)
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
        let root: String
        let worktreeName: String?
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
