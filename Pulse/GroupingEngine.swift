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

/// 组(GLOSSARY):若干进程聚合成的一个显示实体——稳定身份、显示名、类别与聚合指标。
/// `processes` 保留进程明细(cwd / argv / 启动时刻),供下钻(工单 06)直接取用,
/// 不需回查采集层。
struct ProcessGroup: Identifiable, Equatable, Sendable {
    /// 稳定身份,跨快照可比(bundle 路径 / 项目根+worktree / 兜底键)。
    let id: String
    /// 显示名(bundle 显示名 / "项目名 @ worktree" / 兜底类别名)。
    let name: String
    let category: GroupCategory
    /// App 组的 .app bundle 目录,供 UI 取应用图标(工单 05);其余类别为 nil。
    let bundlePath: String?
    /// 组内进程,按进程 CPU% 降序(次键 pid 升序)——下钻列表的既定顺序。
    let processes: [RawProcess]
    /// 组 CPU%(GLOSSARY):组内全部进程 CPU% 之和,单核 100% 累加,可超过 100%。
    let cpuPercent: Double
    /// 组内聚合内存 = 各进程物理足迹之和(活动监视器"内存"列口径),字节。
    let memoryBytes: UInt64
}

// MARK: - 配置

/// 归组配置:项目根列表 + dev / 系统可执行文件名单 + bundle 显示名解析。
/// 全部为调用方注入的纯数据/纯函数——引擎不读磁盘:
/// CFBundleName 由 UI 层注入读取器(工单 05),缺省退化为 bundle 目录名去掉 .app 后缀。
struct GroupingConfiguration: Sendable {
    /// 项目根(GLOSSARY):用户配置的绝对路径(已展开 ~)。引擎只做路径前缀匹配。
    var projectRoots: [String]
    /// 视作"dev 类进程"的可执行文件名——项目归因的准入门槛。
    /// 名单外(且自身不在 bundle 里)的进程不做项目归因,走父链上溯与兜底。
    var devExecutableNames: Set<String>
    /// 知名系统进程的可执行文件名(kernel_task / WindowServer / launchd)。
    /// 优先于 App 归属判定(WindowServer 自身路径就在 .app bundle 里),
    /// 且系统归属不可被子进程继承——launchd 的孩子们仍按自己的链路归组。
    var systemExecutableNames: Set<String>
    /// bundle 显示名解析器:输入 .app 目录路径,返回 CFBundleName;返回 nil 则用目录名推导。
    var bundleDisplayName: @Sendable (_ bundleDirectory: String) -> String?

    init(
        projectRoots: [String] = [],
        devExecutableNames: Set<String> = GroupingConfiguration.defaultDevExecutableNames,
        systemExecutableNames: Set<String> = GroupingConfiguration.defaultSystemExecutableNames,
        bundleDisplayName: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.projectRoots = projectRoots
        self.devExecutableNames = devExecutableNames
        self.systemExecutableNames = systemExecutableNames
        self.bundleDisplayName = bundleDisplayName
    }

    /// 缺省 dev 可执行文件名单:编译器 / 构建器 / 运行时 / 测试器等通用工具。
    static let defaultDevExecutableNames: Set<String> = [
        "rustc", "cargo", "clippy-driver",
        "node", "npm", "npx", "yarn", "pnpm", "bun", "deno",
        "vitest", "jest", "mocha", "karma",
        "tsc", "tsx", "babel", "esbuild", "webpack", "vite", "next",
        "python", "python3", "pip", "pip3", "uv",
        "go", "make", "cmake", "ninja", "meson",
        "clang", "clang++", "cc", "c++", "gcc", "g++", "ld", "lld",
        "swift", "swiftc",
        "ruby", "rake", "bundle", "gem",
        "java", "javac", "gradle", "mvn", "dotnet",
        "php", "composer",
    ]

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
/// 1. App 归属——自身可执行路径含 `.app/Contents/MacOS/`(取最外层 .app,
///    Chrome Helper 的嵌套 Helper.app 因此跟随宿主 Google Chrome.app);
/// 2. 项目归因——dev 类进程按 cwd 优先、argv 中路径次之与项目根前缀匹配,
///    命中 `.worktrees/<名>` 显示"项目名 @ 名"。放在父链上溯之前:
///    验收锚点要求 rustc ← cargo ← node ← Zcode 归"项目 @ worktree",
///    而不是归到拉起它的 Zcode;
/// 3. 父链上溯——非 bundle、无项目归因的进程沿活 ppid 链向上找有归属的祖先;
///    断链(中间父进程已死 / 被重挂到 launchd)时回查出生登记的父链;
/// 4. 兜底三分类——系统(知名系统进程,优先于第 1 步)/ 后台服务(出生或现挂
///    在活 launchd 之下)/ 孤儿进程(断链且登记无归属可继承)。
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

        var membersByID: [String: [RawProcess]] = [:]
        var attributionByID: [String: Attribution] = [:]
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
                category: attribution.category,
                bundlePath: attribution.bundlePath,
                processes: sortedMembers,
                cpuPercent: cpu,
                memoryBytes: memory
            )
        }
        .sorted { $0.cpuPercent == $1.cpuPercent ? $0.id < $1.id : $0.cpuPercent > $1.cpuPercent }
    }

    /// spec App 归属判定的路径谓词:可执行路径含 `.app/Contents/MacOS/` 即 bundle 内进程。
    /// 父链面包屑(工单 06)复用同一口径,判定只有这一份。
    static func isBundleExecutablePath(_ executablePath: String?) -> Bool {
        executablePath?.contains(".app/Contents/MacOS/") ?? false
    }
}

// MARK: - 归属判定

/// 单进程的归属判定结果(聚合前)。
private struct Attribution: Equatable {
    let id: String
    let name: String
    let category: GroupCategory
    let bundlePath: String?
}

extension Attribution {
    /// 兜底三分类的固定组:同名进程聚合进各自类别的单一组。
    static let systemGroup = Attribution(id: "system", name: "系统", category: .system, bundlePath: nil)
    static let backgroundServiceGroup =
        Attribution(id: "background-service", name: "后台服务", category: .backgroundService, bundlePath: nil)
    static let orphanGroup = Attribution(id: "orphan", name: "孤儿进程", category: .orphan, bundlePath: nil)
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
            .map(Self.normalizedRootPath)
            .sorted { $0.count > $1.count }
        self.processesByPID = Dictionary(
            snapshot.processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
        // 三层全部落空 → 兜底三分类。
        if let birth = lineage.entries[process.pid] {
            // 出生时父即 launchd:launchd 域服务;出生时有真实父(现已死)且登记链
            // 无归属可继承:孤儿进程。
            return birth.parentPID == 1 ? .backgroundServiceGroup : .orphanGroup
        }
        // 无出生记录:现挂在存活的 launchd 之下按后台服务,链断在别处按孤儿。
        return resolution.reachedLiveLaunchd ? .backgroundServiceGroup : .orphanGroup
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

    /// 进程自身可判定的两层归属:App 归属(bundle)→ 项目归因(dev + 项目根前缀)。
    /// 这两层可被子进程与登记链继承;系统 / 兜底归属不可继承。
    private func layerSelf(
        executablePath: String?,
        cwd: String?,
        argv: [String]
    ) -> Attribution? {
        if let bundle = Self.outermostAppBundleDirectory(executablePath) {
            return Attribution(
                id: "bundle:" + bundle,
                name: bundleDisplayName(forBundleDirectory: bundle),
                category: .app,
                bundlePath: bundle
            )
        }
        guard configuration.devExecutableNames
            .contains(executableName(executablePath: executablePath, argv: argv))
        else { return nil }
        // 项目归因:cwd 优先,argv 中的路径次之。
        guard let match = projectMatch(cwd) ?? argvProjectMatch(argv) else { return nil }
        let projectName = Self.rootDisplayName(match.root)
        return Attribution(
            id: "project:" + match.root + (match.worktreeName.map { "@\($0)" } ?? ""),
            name: match.worktreeName.map { "\(projectName) @ \($0)" } ?? projectName,
            category: .project,
            bundlePath: nil
        )
    }

    private func layerSelf(_ process: RawProcess) -> Attribution? {
        layerSelf(executablePath: process.executablePath, cwd: process.cwd, argv: process.argv)
    }

    /// 出生登记回查(GLOSSARY 活链断裂后的归属来源):沿出生父链找有归属的祖先,
    /// 祖先的归属由其出生记录自身的字段判定。登记无该进程 / 链上无归属 → nil。
    private func registryChainAttribution(from pid: pid_t) -> Attribution? {
        var visited: Set<pid_t> = []
        var currentPID = pid
        while let entry = lineage.entries[currentPID], visited.insert(currentPID).inserted {
            guard let parent = lineage.entries[entry.parentPID] else { return nil }
            if let attribution = layerSelf(
                executablePath: parent.executablePath,
                cwd: parent.cwd,
                argv: parent.argv
            ) {
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
        let normalized = Self.normalizedRootPath(path)
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

    /// 轻量归一:去掉尾部 "/"(根路径 "/" 除外)。不做文件系统访问。
    private static func normalizedRootPath(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// 最外层 .app bundle 目录:可执行路径含 `.app/Contents/MacOS/` 即为 bundle 内进程
    /// (spec 判定规则),归属取路径中**最外层** `.app` 目录组件——嵌套 Helper.app
    /// (宿主后跟 `/Contents/Frameworks/…` 而非 `/Contents/MacOS/`)因此跟随宿主
    /// bundle(Google Chrome.app)。
    private static func outermostAppBundleDirectory(_ executablePath: String?) -> String? {
        guard let path = executablePath,
              path.contains(".app/Contents/MacOS/")
        else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() where component.hasSuffix(".app") {
            return components[...index].joined(separator: "/")
        }
        return nil
    }

    /// 项目名 = 项目根最后一级目录名。
    private static func rootDisplayName(_ root: String) -> String {
        String(root.split(separator: "/").last ?? Substring(root))
    }
}
