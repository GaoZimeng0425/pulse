import Foundation

// MARK: - 通用发现 + 保护名单(p7-cleaner/02;ADR-0013)

//
// 方向与规则表相反:规则表问「这目录在不在名单上」,通用发现问「这三处里还有谁没被
// 认领」。它是安全白名单之外的兜底——产出的条目一律「先检查」、带「未识别」条目标志,
// 永不进自动勾选(GLOSSARY「通用发现」)。
// 只管三处:缓存目录一级条目、日志目录一级条目、应用数据目录各应用目录里名字明确的
// 缓存子目录。放着进行中工作的临时目录等不进通用发现,只在规则表里按工具点名。
// 扫描树 → 候选是纯值、零 IO,与卸载残留检测同形:跑在已扫出的扫描树上。
// 「所属应用此刻在运行」不在扫描快照里判:扫描之后才启动的应用,它的缓存不该还列着。
// 它是另一个纯函数(`excludingRunningApps`),由调用方每次读清单时现查现传,与在用保护
// 同一个「判定不缓存」的纪律。
// 对齐对象在这条路上的事故教训只借事实(路径、条件),零搬码。

/// 运行中的应用的身份(「在运行应用」判定的输入;Live 从系统的工作区应用列表采集)。
/// 纯值:采集在 app 侧,判定在这里。
public struct RunningAppIdentity: Sendable, Equatable {
    /// bundle id;没有 bundle id 的应用为 nil。
    public let bundleID: String?
    /// 应用名(应用包文件名去掉 .app、界面显示名),原样大小写。
    public let names: [String]

    public init(bundleID: String?, names: [String]) {
        self.bundleID = bundleID
        self.names = names
    }
}

public enum GenericDiscovery {
    /// 通用发现产出的候选共用的规则 id(清理历史按它区分来源)。
    public static let ruleID = "app-generic"

    /// 行悬停说明:说不出它属于谁,只说清「清了会怎样、为什么不会自动勾」。
    static let rationale = "名单外的目录:名字看起来是缓存,但说不出属于哪个工具。清了通常会自动重建;不确定里面有没有还要用的东西,所以只列在「先检查」,不会被自动勾选。"

    /// 应用数据目录下算得上「名字明确的缓存」的子目录名(小写比较——磁盘默认不分大小写)。
    /// 只收定义上就是可重建缓存的:Chromium / Electron 系的渲染进程缓存一族,加通用的
    /// Cache / Caches。对照过对齐对象的名单并补全(三个 Dawn 系);它另有 Crashpad 的
    /// 已完成崩溃报告,那是日志不是缓存,不在此列。
    static let cacheSubtreeNames: Set<String> = [
        "cache", "caches", "code cache", "gpucache", "dawncache", "grshadercache", "shadercache",
        "cacheddata", "graphitedawncache", "dawngraphitecache", "dawnwebgpucache",
    ]

    /// 扫描树 → 通用发现的候选。不判「在运行」(那是现查的事,见文件头)。
    /// - Parameters:
    ///   - trees: 扫描产出(`SpaceScanResult.trees`)。
    ///   - home: 用户家目录(定位 ~/Library 三处)。
    ///   - claimed: 规则表 / 项目产物 / 卸载残留已产出的候选——与它们路径相等或互为
    ///     祖孙的条目让位,不重复产出。
    ///   - excludedPathPrefixes: 排除目录(与另两个规则域同款)。
    public static func detect(
        in trees: [SpaceNode],
        home: String,
        claimedBy claimed: [JunkCandidate],
        excludedPathPrefixes: [String]
    ) -> [JunkCandidate] {
        let homePath = PathNormalization.normalize(home)
        guard let library = SpaceNode.locate(path: homePath + "/Library", in: trees) else { return [] }
        func domain(_ name: String) -> SpaceNode? {
            library.children.first { $0.name == name && $0.kind == .directory }
        }
        // 三处共用的闸:右键排除、零字节纪律、保护名单。
        func passesGates(_ node: SpaceNode) -> Bool {
            // 噪音纪律(与另两个规则域同款):右键排除照收;零字节且非部分扫描不列——
            // 没有可回收量,列出来纯占屏。部分扫描的零字节如实列(数字未知,不敢说没有)。
            // 保护名单:永不列出,连「先检查」都不给。
            guard !CleanExclusions.isExcluded(node.path, by: excludedPathPrefixes),
                  node.accountedBytes > 0 || node.isPartial,
                  !DiscoveryProtectionList.isProtected(name: node.name)
            else { return false }
            return true
        }

        var out: [JunkCandidate] = []
        // 缓存目录、日志目录:一级条目,一个目录一条。
        for rootName in ["Caches", "Logs"] {
            guard let root = domain(rootName) else { continue }
            for child in root.children where child.kind == .directory {
                guard passesGates(child) else { continue }
                out.append(candidate(child, title: child.name))
            }
        }
        // 应用数据目录:这里装着登录态、本地数据库、离线资源,只收各应用目录下**名字明确
        // 是缓存**的子目录,一个子目录一条——资料目录、数据库、工作区状态一律轮不到。
        // 应用目录本身过不了闸的,下面一律不进。
        if let appSupport = domain("Application Support") {
            for appDirectory in appSupport.children where appDirectory.kind == .directory {
                guard passesGates(appDirectory) else { continue }
                for subdirectory in appDirectory.children where subdirectory.kind == .directory {
                    guard cacheSubtreeNames.contains(subdirectory.name.lowercased()),
                          passesGates(subdirectory)
                    else { continue }
                    // 光写「Cache」分不清是谁的:标题带上应用目录名。
                    out.append(candidate(subdirectory, title: "\(appDirectory.name) · \(subdirectory.name)"))
                }
            }
        }

        // 去重让位:与规则表 / 项目产物 / 卸载残留路径相等或互为祖孙就让位——那一侧
        // 的说明与档位是逐条担保过的,比「名单外」的推断更准。规则与孤儿让位同一个函数。
        return OrphanLeftoverDetector.excludingOverlaps(
            out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path },
            claimedBy: claimed
        )
    }

    /// 现查过滤:通用发现的条目里,所属应用此刻在运行的,此刻不出现(它的缓存此刻在用,
    /// 视同在用)。每次读清单时调用——答案随时间变,不进扫描结果。非通用发现的条目原样通过。
    public static func excludingRunningApps(
        _ candidates: [JunkCandidate],
        runningApps: [RunningAppIdentity]
    ) -> [JunkCandidate] {
        guard !runningApps.isEmpty else { return candidates }
        let running = RunningAppNames(runningApps: runningApps)
        return candidates.filter { candidate in
            candidate.ruleID != ruleID || !running.owns(directoryName: ownerDirectoryName(of: candidate))
        }
    }

    /// 通用发现条目的「所属目录名」:缓存 / 日志条目就是它自己;应用数据目录的缓存子目录
    /// 是它上面那层应用目录(`…/Application Support/<应用>/Cache`)。
    static func ownerDirectoryName(of candidate: JunkCandidate) -> String {
        let parts = candidate.path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[parts.count - 3] == "Application Support" {
            return parts[parts.count - 2]
        }
        return parts.last ?? candidate.path
    }

    /// 通用发现的候选:一律「先检查」+「未识别」,归应用缓存组。
    private static func candidate(_ node: SpaceNode, title: String) -> JunkCandidate {
        JunkCandidate(
            ruleID: ruleID,
            group: .appCache,
            title: title,
            path: node.path,
            tier: .checkFirst,
            bytes: node.accountedBytes,
            fileCount: node.fileCount,
            isPartial: node.isPartial,
            allReclaimableAccounting: node.allReclaimableAccounting,
            rationale: rationale,
            symbolName: "questionmark.folder",
            // 「按新旧」排序用子树内任何文件的最新变动(与卸载残留同口径):缓存目录
            // 自身和直属文件的时间不反映深处的写入。
            newestChangeEpoch: OrphanLeftoverDetector.subtreeNewestChangeEpoch(of: node),
            modifiedAtScan: node.ownModifiedEpoch,
            flags: [.unidentified]
        )
    }
}

/// 运行中应用的读数:一小段时间内的重复读共用一次采集。
/// 采集有成本(逐应用读属性,本机两百来个应用约 2 毫秒),而一次渲染会把清单读好几遍。
/// 新鲜 = 距采集不满 `freshness`,且「谁在运行」的版本号没变(`revision` 由调用方在
/// 应用启动 / 退出、生成确认清单前递增)。时间由调用方传:纯值,零时钟。
public struct RunningAppsReading {
    private let freshness: TimeInterval
    private var snapshot: (value: [RunningAppIdentity], collectedAt: Date, revision: Int)?

    public init(freshness: TimeInterval = 1) {
        self.freshness = freshness
    }

    public mutating func value(
        at now: Date,
        revision: Int,
        collect: () -> [RunningAppIdentity]
    ) -> [RunningAppIdentity] {
        if let snapshot, snapshot.revision == revision,
           now.timeIntervalSince(snapshot.collectedAt) < freshness {
            return snapshot.value
        }
        let value = collect()
        snapshot = (value, now, revision)
        return value
    }
}

/// 「哪些目录名属于正在运行的应用」。运行中应用的每段标识(bundle id、应用名、知识库
/// 登记的别名)都登记进来,一个目录名算它的有三种对应,**都认到段边界为止**:
///   · 整段相等:目录名就是它的 bundle id 或应用名(不分大小写);
///   · 目录名是某段标识的开头一段:目录「MyGo」之于应用名「MyGo Music」(本机实案:
///     缓存目录只取了应用名的前半截,整名相等对不上);
///   · 某段标识是目录名的开头一段:目录 `com.running.app.helper` 之于 bundle id
///     `com.running.app`(子组件 / 助手的缓存)。
/// 段边界 = 点或空格:`com.running.applicate` 与 `com.running.app` 只是前几个字符相同,不算。
/// 知识库别名闭包:条目登记的目录名里有运行中应用的标识,它登记的其它目录名也算它的
/// (Arc 的条目同时登记「Arc」与它的 bundle id)。宁可多藏,不可误列。
struct RunningAppNames {
    /// 每段标识与它开头的各段。
    private let heads: Set<String>
    /// 每段标识本身。
    private let identifiers: Set<String>

    init(runningApps: [RunningAppIdentity]) {
        var identifiers = Set<String>()
        for app in runningApps {
            if let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty {
                identifiers.insert(bundleID)
            }
            for name in app.names {
                let lowered = name.lowercased()
                if !lowered.isEmpty {
                    identifiers.insert(lowered)
                }
            }
        }
        for entry in AppCacheCatalog.entries {
            let aliases = Set(entry.names.map { $0.lowercased() })
            guard !aliases.isDisjoint(with: identifiers) else { continue }
            identifiers.formUnion(aliases)
        }
        self.identifiers = identifiers
        heads = Set(identifiers.flatMap { $0.leadingSegments.map(String.init) })
    }

    func owns(directoryName: String) -> Bool {
        let lowered = directoryName.lowercased()
        if heads.contains(lowered) {
            return true
        }
        // 目录名比标识长:逐段缩短,再比整段。
        var remainder = Substring(lowered)
        while let boundary = remainder.lastIndex(where: { $0 == "." || $0 == " " }) {
            remainder = remainder[..<boundary]
            if identifiers.contains(String(remainder)) {
                return true
            }
        }
        return false
    }
}

private extension String {
    /// 自己与开头的各段(段边界 = 点或空格):`com.running.app` → com / com.running / com.running.app。
    var leadingSegments: [Substring] {
        var segments: [Substring] = []
        var index = startIndex
        while let boundary = self[index...].firstIndex(where: { $0 == "." || $0 == " " }) {
            segments.append(self[..<boundary])
            index = self.index(after: boundary)
        }
        segments.append(self[...])
        return segments
    }
}
