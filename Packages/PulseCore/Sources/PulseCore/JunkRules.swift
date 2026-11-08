import Foundation

// MARK: - 安全白名单规则表(p4-cleaner/04;ADR-0008)

//
// 「能删的地方」永远等于「白名单担保过的地方」:清单只收规则命中的目录,未命中不显示、
// 不可删。规则 = 路径模式 + 安全档 + 说明文案 + 来源,纯值、无 IO;匹配跑在已扫出的
// SpaceNode 树上(全卷扫描已经走过这些目录,不二次扫盘)。
//
// 首批规则域 = 全局工具缓存(票面)。路径与档位移植自 purge-app(jithin-sabu/purge-app,
// MIT License)`purge/Services/DevScanner.swift` `globalCacheDefinitions()` 与
// `purge/Resources/explanations.json`;与上游的差异逐条标在规则旁:
//   - purge-app 三档(safe / medium / AI 待定)收成 Pulse 两档(GLOSSARY「安全档」):
//     safe → 可安全清理;medium → 先检查。
//   - 目录作为一个可删单元整体列出,不像上游对 JetBrains 逐 IDE 子目录剔 LocalHistory
//     ——因此 JetBrains 整体降为「先检查」并在文案里点明 Local History 会一起删。
//   - Docker 取 `com.docker.docker/Data`(镜像 / 容器 / 卷所在),不动容器根下的设置。
//   - 文案改写为中文,口径按 Pulse 两档定义重述,不是逐字翻译。
// 规则表是安全边界的本体:每条内置规则必须被登记完整性测试的至少一个正例命中
// (JunkRuleTableTests),新增规则不写用例过不了测试。

/// 安全档(GLOSSARY「安全档」)。
public enum CleanSafetyTier: String, Sendable, Codable, CaseIterable, Equatable {
    /// 已知可重建的缓存 / 产物:默认可勾。
    case safe
    /// 可能造成不便(重下载很慢、附带用户数据):默认不勾,须亲手勾。
    case checkFirst

    public var title: String {
        switch self {
        case .safe: "可安全清理"
        case .checkFirst: "先检查"
        }
    }
}

/// 规则域分组(清单按组分段)。全局工具缓存(04)+ 项目产物(05);
/// AI 模型 / 孤儿 worktree 归 06 票,加 case 即扩组。
/// CaseIterable 顺序即 UI 组序(卸载残留 p5-cleaner/01,grill 2026-11-08:殿后)。
public enum JunkGroup: String, Sendable, CaseIterable, Equatable {
    case globalToolCache
    case projectArtifacts
    case uninstallLeftovers

    public var title: String {
        switch self {
        case .globalToolCache: "全局工具缓存"
        case .projectArtifacts: "项目产物"
        case .uninstallLeftovers: "卸载残留"
        }
    }
}

/// 路径模式:相对家目录的分量序列。分量可为字面名或后缀匹配(如 " DeviceSupport"
/// 一条规则覆盖 iOS / watchOS / tvOS / visionOS / xrOS 五个目录)。只匹配目录。
public struct JunkPathPattern: Sendable, Equatable {
    public enum Component: Sendable, Equatable {
        case literal(String)
        case suffix(String)
    }

    public var components: [Component]

    public init(_ components: [Component]) {
        self.components = components
    }

    /// 全字面模式:`"Library/Caches/Homebrew"`。
    public init(homeRelative path: String) {
        components = path.split(separator: "/", omittingEmptySubsequences: true).map { .literal(String($0)) }
    }

    /// 从家目录节点出发匹配,返回命中的目录节点(可多个:后缀分量 / 同名不同层不会发生,
    /// 多个来自后缀分量的扇出)。
    func matches(from home: SpaceNode) -> [SpaceNode] {
        var frontier = [home]
        for component in components {
            var next: [SpaceNode] = []
            for node in frontier {
                for child in node.children where child.kind == .directory {
                    switch component {
                    case let .literal(name) where child.name == name:
                        next.append(child)
                    case let .suffix(suffix) where child.name.hasSuffix(suffix) && child.name != suffix:
                        next.append(child)
                    default:
                        break
                    }
                }
            }
            if next.isEmpty {
                return []
            }
            frontier = next
        }
        return frontier
    }

    /// 轻桥判定(p4-uninstaller/05):一条绝对路径是否落在本模式的命中域内。
    /// 与 matches(from:) 同一套组件语义(逐层对齐,不另立口径);命中含两种:
    /// 模式终点自身(matches 的产物)与其子孙(地图下钻到白名单目录里面的块,
    /// 仍属于「这块能清」的域——跳转去对应组,不做块级删除)。
    func covers(path: String, home: String) -> Bool {
        let homeParts = home.split(separator: "/").map(String.init)
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count >= homeParts.count,
              Array(parts.prefix(homeParts.count)) == homeParts
        else { return false }
        parts.removeFirst(homeParts.count)
        guard parts.count >= components.count else { return false }
        for (index, component) in components.enumerated() {
            let name = parts[index]
            switch component {
            case let .literal(expected):
                if name != expected {
                    return false
                }
            case let .suffix(suffix):
                if !(name.hasSuffix(suffix) && name != suffix) {
                    return false
                }
            }
        }
        return true
    }

    /// 是否含非字面分量(命中项的标题需带上实际目录名区分,如「iOS」)。
    var hasVariants: Bool {
        components.contains {
            if case .suffix = $0 {
                true
            } else {
                false
            }
        }
    }
}

/// 一条白名单规则。
public struct JunkRule: Sendable, Identifiable, Equatable {
    public let id: String
    public let group: JunkGroup
    public let title: String
    public let patterns: [JunkPathPattern]
    public let tier: CleanSafetyTier
    /// 说明文案:凭什么能删 / 删了会失去什么(确认清单与行悬浮用)。
    public let rationale: String
    /// 来源(移植出处或 Pulse 自定)。
    public let source: String
    /// 行首图标(SF Symbol)。
    public let symbolName: String

    public init(
        id: String,
        group: JunkGroup,
        title: String,
        patterns: [JunkPathPattern],
        tier: CleanSafetyTier,
        rationale: String,
        source: String,
        symbolName: String
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.patterns = patterns
        self.tier = tier
        self.rationale = rationale
        self.source = source
        self.symbolName = symbolName
    }
}

/// 内置规则表。
public enum JunkRuleTable {
    static let purgeApp = "purge-app (MIT) DevScanner.globalCacheDefinitions + explanations.json"

    public static let builtin: [JunkRule] = [
        JunkRule(
            id: "xcode.derivedData",
            group: .globalToolCache,
            title: "Xcode DerivedData",
            patterns: [JunkPathPattern(homeRelative: "Library/Developer/Xcode/DerivedData")],
            tier: .safe,
            rationale: "Xcode 构建的中间产物,随时可重建;删掉后下一次构建会慢一些。",
            source: purgeApp,
            symbolName: "hammer"
        ),
        // 上游 medium → 先检查:下次连设备要重新复制符号,一次几分钟。
        JunkRule(
            id: "xcode.deviceSupport",
            group: .globalToolCache,
            title: "Xcode Device Support",
            patterns: [JunkPathPattern([
                .literal("Library"),
                .literal("Developer"),
                .literal("Xcode"),
                .suffix(" DeviceSupport"),
            ])],
            tier: .checkFirst,
            rationale: "Xcode 从 iPhone / Watch / TV / Vision Pro 复制来的调试符号。不丢数据,但下次连接该设备时会重新复制,一次要几分钟。",
            source: purgeApp,
            symbolName: "iphone"
        ),
        JunkRule(
            id: "xcode.caches",
            group: .globalToolCache,
            title: "Xcode 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/com.apple.dt.Xcode")],
            tier: .safe,
            rationale: "Xcode 自身的临时缓存,下次启动自动重建。",
            source: purgeApp,
            symbolName: "hammer"
        ),
        JunkRule(
            id: "xcode.simulatorCaches",
            group: .globalToolCache,
            title: "模拟器缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Developer/CoreSimulator/Caches")],
            tier: .safe,
            rationale: "iOS 模拟器各运行时共享的缓存;下次启动模拟器时重建,那一次启动会慢。",
            source: purgeApp,
            symbolName: "ipad"
        ),
        // Pulse 自加(上游有同路径条目):本机用户是 Swift 开发者,SwiftPM 缓存量大且纯可重建。
        JunkRule(
            id: "swiftpm.cache",
            group: .globalToolCache,
            title: "Swift Package 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/org.swift.swiftpm")],
            tier: .safe,
            rationale: "Swift Package Manager 的包下载与解析缓存;下次 resolve 时重新拉取。",
            source: purgeApp,
            symbolName: "swift"
        ),
        JunkRule(
            id: "homebrew.cache",
            group: .globalToolCache,
            title: "Homebrew 下载缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/Homebrew")],
            tier: .safe,
            rationale: "Homebrew 已下载的安装包;重装或升级时会重新下载。",
            source: purgeApp,
            symbolName: "cup.and.saucer"
        ),
        JunkRule(
            id: "npm.cache",
            group: .globalToolCache,
            title: "npm 缓存",
            patterns: [JunkPathPattern(homeRelative: ".npm/_cacache")],
            tier: .safe,
            rationale: "npm 的包下载缓存;下次 npm install 时重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "npm.npx",
            group: .globalToolCache,
            title: "npx 临时包",
            patterns: [JunkPathPattern(homeRelative: ".npm/_npx")],
            tier: .safe,
            rationale: "npx 临时安装过的包;下次 npx 时重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游两处候选位:macOS 默认 Library/pnpm/store,老位置 ~/.pnpm-store。
        JunkRule(
            id: "pnpm.store",
            group: .globalToolCache,
            title: "pnpm store",
            patterns: [
                JunkPathPattern(homeRelative: "Library/pnpm/store"),
                JunkPathPattern(homeRelative: ".pnpm-store"),
            ],
            tier: .safe,
            rationale: "pnpm 跨项目共享的包仓;下次 pnpm install 时重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "cocoapods.cache",
            group: .globalToolCache,
            title: "CocoaPods 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/CocoaPods")],
            tier: .safe,
            rationale: "CocoaPods 下载的库缓存;下次 pod install 时重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游 medium(重下载很慢)→ Pulse 判「可安全清理」:纯可重建,与 DerivedData 同性质。
        JunkRule(
            id: "gradle.caches",
            group: .globalToolCache,
            title: "Gradle 缓存",
            patterns: [JunkPathPattern(homeRelative: ".gradle/caches")],
            tier: .safe,
            rationale: "Gradle 下载的依赖与构建缓存;下次构建重新下载,会慢一些。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游 safe 但逐 IDE 剔除 LocalHistory;Pulse 整目录一个单元 → 先检查并点明。
        JunkRule(
            id: "jetbrains.caches",
            group: .globalToolCache,
            title: "JetBrains IDE 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/JetBrains")],
            tier: .checkFirst,
            rationale: "JetBrains 各 IDE 的索引与编译缓存,下次打开项目时重建(要几分钟)。注意:同目录下各 IDE 的 Local History(本地文件修改历史)会一起删掉。",
            source: purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        JunkRule(
            id: "vscode.cache",
            group: .globalToolCache,
            title: "VS Code 缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Application Support/Code/Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/Code/CachedData"),
                JunkPathPattern(homeRelative: "Library/Application Support/Code/CachedExtensionVSIXs"),
            ],
            tier: .safe,
            rationale: "VS Code 的临时缓存;再次启动时重建。设置与扩展不在这里。",
            source: purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        JunkRule(
            id: "cursor.cache",
            group: .globalToolCache,
            title: "Cursor 缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Application Support/Cursor/Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/Cursor/CachedData"),
            ],
            tier: .safe,
            rationale: "Cursor 的临时缓存;再次启动时重建。设置与扩展不在这里。",
            source: purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        // 票面明确:Docker Desktop 数据以「先检查」档列出并写明后果。取 Data 子目录
        // (镜像 / 容器 / 卷所在),不动容器根下 Docker 自身的设置文件。
        JunkRule(
            id: "docker.desktopData",
            group: .globalToolCache,
            title: "Docker Desktop 数据",
            patterns: [JunkPathPattern(homeRelative: "Library/Containers/com.docker.docker/Data")],
            tier: .checkFirst,
            rationale: "Docker Desktop 的全部镜像、容器与卷——删除后全部丢失,卷里的数据库也一样。只想瘦身请在 Docker 运行时用 docker system prune。",
            source: purgeApp,
            symbolName: "square.stack.3d.up"
        ),
    ]

    /// 轻桥判定(p4-uninstaller/05):路径命中内置白名单 → 对应组;不命中 → nil。
    /// 与开发者垃圾清单**同源**(同一个规则表、同一套 JunkPathPattern 语义),
    /// 规则表变更两侧自动一致——checklist 明令不许两套口径漂移。
    public static func cleanableGroup(for path: String, home: String) -> JunkGroup? {
        for rule in builtin {
            for pattern in rule.patterns where pattern.covers(path: path, home: home) {
                return rule.group
            }
        }
        return nil
    }

    public static func rule(id: String) -> JunkRule? {
        builtin.first { $0.id == id }
    }
}

// MARK: - 匹配结果

/// 清单里的一个可删单元(= 命中规则的一个目录节点)。
public struct JunkCandidate: Sendable, Identifiable, Equatable {
    public var id: String {
        path
    }

    public let ruleID: String
    public let group: JunkGroup
    /// 规则标题;后缀模式命中时附实际目录名区分(「Xcode Device Support · iOS」)。
    public let title: String
    public let path: String
    public let tier: CleanSafetyTier
    /// 实际占用口径(GLOSSARY):节点 accountedBytes。
    public let bytes: Int64
    public let fileCount: Int
    /// 子树有目录读不到(权限 / 消失 / 超深)——数字偏小,界面标「部分」。
    public let isPartial: Bool
    /// false = 混了 block 回退口径(界面标注)。
    public let allReclaimableAccounting: Bool
    public let rationale: String
    public let symbolName: String
    /// 所属项目名(05 项目产物专用;全局缓存为 nil)。分组语义由它携带。
    public let projectName: String?
    /// 项目年龄(05:项目直属树内**非产物**文件的最后变动;全局缓存为 nil)。
    /// 界面换算成「N 天未动」;排序「按新旧」以它为准(nil 排最后)。
    public let newestChangeEpoch: Double?

    public init(
        ruleID: String,
        group: JunkGroup,
        title: String,
        path: String,
        tier: CleanSafetyTier,
        bytes: Int64,
        fileCount: Int,
        isPartial: Bool,
        allReclaimableAccounting: Bool,
        rationale: String,
        symbolName: String,
        projectName: String? = nil,
        newestChangeEpoch: Double? = nil
    ) {
        self.ruleID = ruleID
        self.group = group
        self.title = title
        self.path = path
        self.tier = tier
        self.bytes = bytes
        self.fileCount = fileCount
        self.isPartial = isPartial
        self.allReclaimableAccounting = allReclaimableAccounting
        self.rationale = rationale
        self.symbolName = symbolName
        self.projectName = projectName
        self.newestChangeEpoch = newestChangeEpoch
    }

    init(rule: JunkRule, node: SpaceNode, pattern: JunkPathPattern) {
        var title = rule.title
        if pattern.hasVariants, case let .suffix(suffix) = pattern.components.last {
            let variant = node.name.hasSuffix(suffix) ? String(node.name.dropLast(suffix.count)) : node.name
            title += " · \(variant)"
        }
        self.init(
            ruleID: rule.id,
            group: rule.group,
            title: title,
            path: node.path,
            tier: rule.tier,
            bytes: node.accountedBytes,
            fileCount: node.fileCount,
            isPartial: node.isPartial,
            allReclaimableAccounting: node.allReclaimableAccounting,
            rationale: rule.rationale,
            symbolName: rule.symbolName,
            // 08 票:目录内任何文件的最近变动(与项目年龄的 05 语义不同口径——
            // 那是「项目直属非产物文件的变动」,这个就是该缓存目录自己的动静;
            // 供「大小|新旧」排序,界面不直接展示)。
            newestChangeEpoch: node.newestChangeEpoch
        )
    }
}

// MARK: - 展示层纯值(p4-uninstaller/08:两组排序 + 项目产物按项目分组)

/// 清单排序(两组通用)。
public enum JunkSortOrder: String, Sendable, Equatable {
    /// 实际占用降序(默认,腾空间第一动机)。
    case size
    /// 新旧 = 最久未动在前(epoch 升序);epoch 未知排最后,不伪造。
    case age
}

public extension [JunkCandidate] {
    func sortedForDisplay(by order: JunkSortOrder) -> [JunkCandidate] {
        switch order {
        case .size:
            sorted { lhs, rhs in lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.path < rhs.path }
        case .age:
            sorted { lhs, rhs in
                switch (lhs.newestChangeEpoch, rhs.newestChangeEpoch) {
                case let (l?, r?): l != r ? l < r : lhs.path < rhs.path
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.path < rhs.path
                }
            }
        }
    }
}

/// 项目产物分组(08:同 projectName 聚合;无 projectName 的候选(异常)单列兜底)。
public struct ProjectJunkGroup: Sendable, Equatable, Identifiable {
    public var id: String {
        projectName
    }

    public let projectName: String
    public let items: [JunkCandidate]

    /// 项目总占用(实际占用口径)。
    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    /// 项目最近活动(组内最新 epoch;nil = 全未知,界面如实标)。
    public var newestChangeEpoch: Double? {
        items.compactMap(\.newestChangeEpoch).max()
    }

    public init(projectName: String, items: [JunkCandidate]) {
        self.projectName = projectName
        self.items = items
    }
}

public enum ProjectJunkGrouping {
    public static func group(_ candidates: [JunkCandidate]) -> [ProjectJunkGroup] {
        // 保持入参顺序为项目首现序(组内行序由调用方先排好);稳定分组不重排组间。
        var order: [String] = []
        var buckets: [String: [JunkCandidate]] = [:]
        for candidate in candidates {
            let name = candidate.projectName ?? candidate.title
            if buckets[name] == nil {
                order.append(name)
            }
            buckets[name, default: []].append(candidate)
        }
        return order.map { ProjectJunkGroup(projectName: $0, items: buckets[$0] ?? []) }
    }
}

/// 在扫描树上跑规则表。纯值、无 IO。
public enum JunkMatcher {
    /// - Parameters:
    ///   - trees: 扫描产出(`SpaceScanResult.trees`)。
    ///   - home: 用户家目录绝对路径(规则相对它展开);树里找不到家目录 → 空清单。
    ///   - excludedPathPrefixes: 排除目录(GLOSSARY)——命中项落在其下即不列。扫描侧已不下潜
    ///     被排除的目录,这里再判一次是为「扫完之后新加的排除立即生效,不必重扫」。
    /// 空目录(0 字节且非部分扫描)不列:没什么可回收,列出来只是噪音;部分扫描的即便 0
    /// 字节也列并标「部分」——不知道有多少不等于没有。
    public static func candidates(
        in trees: [SpaceNode],
        rules: [JunkRule] = JunkRuleTable.builtin,
        home: String,
        excludedPathPrefixes: [String] = []
    ) -> [JunkCandidate] {
        guard let homeNode = SpaceNode.locate(path: home, in: trees) else { return [] }
        var out: [JunkCandidate] = []
        var seenPaths = Set<String>()
        for rule in rules {
            for pattern in rule.patterns {
                for node in pattern.matches(from: homeNode) {
                    guard !seenPaths.contains(node.path), !CleanExclusions.isExcluded(
                        node.path,
                        by: excludedPathPrefixes
                    ), node.accountedBytes > 0 || node.isPartial else { continue }
                    seenPaths.insert(node.path)
                    out.append(JunkCandidate(rule: rule, node: node, pattern: pattern))
                }
            }
        }
        let groupOrder = Dictionary(uniqueKeysWithValues: JunkGroup.allCases.enumerated().map { ($1, $0) })
        return out.sorted { a, b in
            let ga = groupOrder[a.group] ?? 0, gb = groupOrder[b.group] ?? 0
            if ga != gb {
                return ga < gb
            }
            if a.bytes != b.bytes {
                return a.bytes > b.bytes
            }
            return a.path < b.path
        }
    }
}
