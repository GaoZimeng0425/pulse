import Foundation

// MARK: - 安全白名单规则表(p4-cleaner/04;ADR-0008;p6-cleaner/01 扩六组)

//
// 「能自动勾的地方」永远等于「白名单担保过的地方」:规则命中的目录才有资格进
// 「可安全清理」档;未命中的目录不经本表——名单外的缓存与日志目录由通用发现
// (`GenericDiscovery`)兜住,一律「先检查」、须逐个手勾(ADR-0013 改写 ADR-0008 的
// 「未命中不显示」)。规则 = 路径模式 + 安全档 + 说明文案 + 来源,纯值、无 IO;匹配
// 跑在已扫出的 SpaceNode 树上(全卷扫描已经走过这些目录,不二次扫盘)。
//
// 首批规则域 = 开发工具缓存(原「全局工具缓存」,p4 票面;p6-cleaner/01 随总览品类
// 改名)。路径与档位移植自 purge-app(jithin-sabu/purge-app,
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

/// 规则域分组(清单按组分段)。开发工具 + 项目产物(p4)→ 浏览器 / 应用缓存 /
/// AI 模型三组(p6-cleaner/01,spec 定案 8;AI 组规则在 02 票落地,空组不出段)。
/// CaseIterable 顺序即 UI 组序(卸载残留 p5-cleaner/01,grill 2026-11-08)。
/// p7-cleaner/01 在其后登记「系统级」「安装包」:规则与界面由后续票落地,登记本身
/// 不改变扫描结果——空组不出段、空卡不出卡。
public enum JunkGroup: String, Sendable, CaseIterable, Equatable {
    case globalToolCache
    case browserCache
    case appCache
    case projectArtifacts
    case aiModels
    case uninstallLeftovers
    /// 系统目录里的条目,移走前要运行时授权(GLOSSARY「系统级残留」)。
    case systemLevel
    /// 下载、桌面里的安装文件(GLOSSARY「安装包」)。
    case installers

    public var title: String {
        switch self {
        case .globalToolCache: "开发工具"
        case .browserCache: "浏览器"
        case .appCache: "应用缓存"
        case .projectArtifacts: "项目产物"
        case .aiModels: "AI 模型"
        case .uninstallLeftovers: "卸载残留"
        case .systemLevel: "系统级"
        case .installers: "安装包"
        }
    }

    /// 组内是否按所有者聚合成大卡(项目产物按项目、卸载残留按 app;条目的
    /// `projectName` 即分组键)。穷举 switch:新增分组必须表态。
    public var groupsByOwner: Bool {
        switch self {
        case .globalToolCache, .browserCache, .appCache, .aiModels, .systemLevel, .installers: false
        case .projectArtifacts, .uninstallLeftovers: true
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
    static let purgeAppExplanations = "purge-app (MIT) explanations.json"
    static let pulseCustom = "Pulse 自定"
    static let purgeAppArtifacts = "purge-app (MIT) ProjectArtifactCatalog.swift"

    /// 开发工具规则(p4 首批 + p6-cleaner/01 补行 + p7-cleaner/10 自上游补差);浏览器 / 应用缓存
    /// 目录规则由 `AppCacheCatalog` 生成,固定路径条目(日志、Electron 应用的缓存)在 `appCacheFixedRules`。
    /// p7-cleaner/10 起上游 63 条全局缓存定义逐条有下落,由 `GlobalToolCachePortLedgerTests` 的账本钉住。
    static let globalToolCacheRules: [JunkRule] = [
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
        // p7-cleaner/10:com.apple.* 的缓存不自动勾(票 09 给应用缓存定的规矩,这里补齐到开发工具规则;
        // p4 时是「可安全清理」,上游也是 safe)——常驻的进程没有可靠的「在运行」信号,这个缓存很小。
        JunkRule(
            id: "xcode.caches",
            group: .globalToolCache,
            title: "Xcode 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/com.apple.dt.Xcode")],
            tier: .checkFirst,
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
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/org.swift.swiftpm"),
                // p7-cleaner/10 补:上游登记的第二个位置
                JunkPathPattern(homeRelative: ".swiftpm/cache"),
            ],
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
        // p7-cleaner/10 对齐上游档位(上游是 medium):p6 时判「可安全清理」,现在「先检查」——
        // 自己装进去的构建也要重新编译;另补上游登记的 wrapper 各版本分发目录。
        JunkRule(
            id: "gradle.caches",
            group: .globalToolCache,
            title: "Gradle 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".gradle/caches"),
                JunkPathPattern(homeRelative: ".gradle/wrapper/dists"),
            ],
            tier: .checkFirst,
            rationale: "Gradle 下载的依赖、构建缓存与 wrapper 的各个版本;不丢东西,但下次构建要重新下载、重新编译,比较慢。",
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
                // p7-cleaner/10 补:VS Code 在缓存目录下的那份(说明库 vscode 条目登记的目录名)
                JunkPathPattern(homeRelative: "Library/Caches/Code"),
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
                // p7-cleaner/10 补:Cursor 在缓存目录下的那份(说明库 cursor 条目登记的目录名)
                JunkPathPattern(homeRelative: "Library/Caches/Cursor"),
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
        // ↓ p6-cleaner/01 补行(spec 定案 12):本机实测漏网的开发缓存 + 常用位。
        // p7-cleaner/10 对齐上游档位(上游是 medium):p6 时判「可安全清理」,现在「先检查」——
        // 自己 mvn install 装进去的构建只有重新构建才回来。
        JunkRule(
            id: "maven.repository",
            group: .globalToolCache,
            title: "Maven 本地仓库",
            patterns: [JunkPathPattern(homeRelative: ".m2/repository")],
            tier: .checkFirst,
            rationale: "Maven 下载的库,以及你自己 mvn install 装进去的构建;库下次构建会重新下载,自己装的那部分只有重新构建才回来。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "cargo.registry",
            group: .globalToolCache,
            title: "Cargo 包缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".cargo/registry"),
                JunkPathPattern(homeRelative: ".cargo/git"),
            ],
            tier: .safe,
            rationale: "Rust 依赖与源码缓存;下次构建重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        // p7-cleaner/10 对齐上游档位(上游是 medium):p6 时判「可安全清理」,现在「先检查」——
        // 经 uvx 运行的工具会中断,符号链接模式装的环境会坏。
        JunkRule(
            id: "uv.cache",
            group: .globalToolCache,
            title: "uv 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/uv")],
            tier: .checkFirst,
            rationale: "Python uv 下载、编译过的包;需要时它会重新获取,但经 uvx 运行的工具会中断,用符号链接模式装的环境也会坏。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        // go.caches 在 p7-cleaner/10 拆成 go.moduleCache(先检查)与 go.buildCache(可安全清理),
        // 两条都在下面「自上游补差」那一块里:上游本来就是两行、两个档位。
        // 2026-11-09 真案漏网:pnpm 的元数据缓存在 Library/Caches/pnpm,
        // 与包仓(Library/pnpm/store,pnpm.store 规则)是两处。
        JunkRule(
            id: "pnpm.metadataCache",
            group: .globalToolCache,
            title: "pnpm 元数据缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/pnpm")],
            tier: .safe,
            rationale: "pnpm 的注册表元数据缓存(与包仓是两处);清了下次 install 重新拉取。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "corepack.cache",
            group: .globalToolCache,
            title: "Corepack 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/node/corepack")],
            tier: .safe,
            rationale: "Node 包管理器版本缓存;下次使用时重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "yarn.cache",
            group: .globalToolCache,
            title: "Yarn 缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/Yarn"),
                JunkPathPattern(homeRelative: ".yarn/berry/cache"),
            ],
            tier: .safe,
            rationale: "Yarn 的包下载缓存;下次安装重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "deno.cache",
            group: .globalToolCache,
            title: "Deno 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/deno")],
            tier: .safe,
            rationale: "Deno 的依赖与编译缓存;下次运行重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "bun.cache",
            group: .globalToolCache,
            title: "Bun 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".bun/install/cache"),
                // p7-cleaner/10 补:新版 Bun 把包缓存放在这里(本机实测,里面是 .pile 文件)
                JunkPathPattern(homeRelative: "Library/Caches/bun"),
            ],
            tier: .safe,
            rationale: "Bun 的包安装缓存;下次安装重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "electron.toolingCaches",
            group: .globalToolCache,
            title: "Electron 工具链缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/electron"),
                JunkPathPattern(homeRelative: "Library/Caches/electron-builder"),
                JunkPathPattern(homeRelative: "Library/Caches/node-gyp"),
            ],
            tier: .safe,
            rationale: "Electron 预编译二进制 / 打包器 / node-gyp 头文件缓存;下次构建重新下载。",
            source: purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游对 Archives 有「目录里没有 .xcarchive 时降 safe」的细分;我们整目录一个
        // 单元,不细分——归档不可重建,恒「先检查」并在文案点明。
        JunkRule(
            id: "xcode.archives",
            group: .globalToolCache,
            title: "Xcode Archives",
            patterns: [JunkPathPattern(homeRelative: "Library/Developer/Xcode/Archives")],
            tier: .checkFirst,
            rationale: "发布归档(.xcarchive)与 dSYM——删除后不可重建,上传 App Store、符号化崩溃都要用它;确认不再需要再清。",
            source: purgeApp,
            symbolName: "archivebox"
        ),
        JunkRule(
            id: "xcode.testDevices",
            group: .globalToolCache,
            title: "Xcode 测试设备",
            patterns: [JunkPathPattern(homeRelative: "Library/Developer/XCTestDevices")],
            tier: .safe,
            rationale: "UI 测试模拟设备的数据;删了下次跑测试自动重建。",
            source: purgeApp,
            symbolName: "iphone"
        ),
        // —— p7-cleaner/10:自上游 DevScanner.globalCacheDefinitions 补差(路径逐字取自上游源码)——
        // 上游标「先检查」(medium)的照搬是「先检查」;说明库登记在缓存目录一级的开发工具缓存也在这里。
        // 逐条的下落由 GlobalToolCachePortLedgerTests 的账本钉住。
        // 上游「Xcode Documentation Cache」
        JunkRule(
            id: "xcode.documentationCache",
            group: .globalToolCache,
            title: "Xcode 文档缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Developer/Xcode/DocumentationCache")],
            tier: .safe,
            rationale: "Xcode 浏览过的开发者文档缓存;清了再浏览文档时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "book"
        ),
        // —— 缓存目录一级的开发工具缓存 ——
        // 上游的全局缓存定义里没有这些(它们登记在说明库里、按名字认);路径按各工具的惯例位置写在本票,
        // 每一条都在账本测试的 pulseAdded 里登记了缘由。
        JunkRule(
            id: "xcode.deviceSoftwareService",
            group: .globalToolCache,
            title: "Xcode 设备支持文件缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/com.apple.dt.Xcode.ITunesSoftwareService")],
            tier: .checkFirst,
            rationale: "Xcode 往连接的苹果设备上安装、调试应用用的临时文件;清了 Xcode 可能要重新下载设备支持文件。",
            source: JunkRuleTable.purgeApp,
            symbolName: "iphone"
        ),
        // 上游「CocoaPods」
        JunkRule(
            id: "cocoapods.specRepos",
            group: .globalToolCache,
            title: "CocoaPods 规格仓库",
            patterns: [JunkPathPattern(homeRelative: ".cocoapods/repos")],
            tier: .checkFirst,
            rationale: "CocoaPods 用来查有哪些库的规格仓库;公共的那份下次 pod install 会重新拉,自己用 pod repo add 加的私有仓库要重新加。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「npm Logs」
        JunkRule(
            id: "npm.logs",
            group: .globalToolCache,
            title: "npm 日志",
            patterns: [JunkPathPattern(homeRelative: ".npm/_logs")],
            tier: .safe,
            rationale: "npm 命令写的日志;清了不影响已装的包。",
            source: JunkRuleTable.purgeApp,
            symbolName: "doc.text"
        ),
        // 上游「Dart Pub Cache」
        JunkRule(
            id: "dart.pubCache",
            group: .globalToolCache,
            title: "Dart Pub 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".pub-cache/hosted"),
                JunkPathPattern(homeRelative: ".pub-cache/git"),
            ],
            tier: .safe,
            rationale: "Dart / Flutter 下载的包(pub);下次 flutter pub get 时重新下载。dart pub global activate 装的工具不在这里。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「pre-commit Environments」
        JunkRule(
            id: "precommit.environments",
            group: .globalToolCache,
            title: "pre-commit 环境",
            patterns: [JunkPathPattern(homeRelative: ".cache/pre-commit")],
            tier: .safe,
            rationale: "pre-commit 为了跑 git 钩子搭的工具环境;清了下次提交时重新搭,那一次提交会慢。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「prek Cache」
        // 与上游的差异:上游要求 prek 空闲时清;在不在用我们这里不判,靠先检查
        JunkRule(
            id: "prek.cache",
            group: .globalToolCache,
            title: "prek 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".cache/prek/repos"),
                JunkPathPattern(homeRelative: ".cache/prek/hooks"),
                JunkPathPattern(homeRelative: ".cache/prek/tools"),
                JunkPathPattern(homeRelative: ".cache/prek/cache"),
            ],
            tier: .checkFirst,
            rationale: "prek(钩子管理工具)缓存的钩子仓库、环境与工具;要在它空闲时清,运行中的任务可能在用。下次运行时重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "prisma.cache",
            group: .globalToolCache,
            title: "Prisma 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".cache/prisma"),
                JunkPathPattern(homeRelative: "Library/Caches/prisma-nodejs"),
            ],
            tier: .safe,
            rationale: "Prisma(数据库工具)的引擎下载与临时文件;下次使用时重新生成。",
            source: JunkRuleTable.purgeApp,
            symbolName: "cylinder"
        ),
        // 上游「Expo Cache」
        JunkRule(
            id: "expo.cache",
            group: .globalToolCache,
            title: "Expo 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".expo/android-apk-cache"),
                JunkPathPattern(homeRelative: ".expo/ios-simulator-app-cache"),
                JunkPathPattern(homeRelative: ".expo/native-modules-cache"),
                JunkPathPattern(homeRelative: ".expo/schema-cache"),
                JunkPathPattern(homeRelative: ".expo/template-cache"),
                JunkPathPattern(homeRelative: ".expo/versions-cache"),
                JunkPathPattern(homeRelative: ".expo/expo-go"),
            ],
            tier: .safe,
            rationale: "Expo 工具下载的应用构建、模板与 SDK 数据;Expo 的登录信息不在这里。清了 Expo 需要时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "iphone"
        ),
        // 上游「pyenv and rbenv Downloads」
        JunkRule(
            id: "pyenv.rbenvDownloads",
            group: .globalToolCache,
            title: "pyenv / rbenv 下载缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".pyenv/cache"),
                JunkPathPattern(homeRelative: ".rbenv/cache"),
            ],
            tier: .safe,
            rationale: "pyenv / rbenv 装完某个版本后留下的源码下载;已装好的版本不动。清了重装那个版本时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Oh My Zsh Cache」
        JunkRule(
            id: "ohmyzsh.cache",
            group: .globalToolCache,
            title: "Oh My Zsh 缓存",
            patterns: [JunkPathPattern(homeRelative: ".oh-my-zsh/cache")],
            tier: .safe,
            rationale: "Oh My Zsh 的补全与更新检查文件;开新终端窗口时重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "terminal"
        ),
        // 上游「opam Download Cache」
        JunkRule(
            id: "opam.downloads",
            group: .globalToolCache,
            title: "opam 下载缓存",
            patterns: [JunkPathPattern(homeRelative: ".opam/download-cache")],
            tier: .safe,
            rationale: "opam 留着的 OCaml 包下载;已装的包不动,需要时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Puppeteer Browsers」
        JunkRule(
            id: "puppeteer.browsers",
            group: .globalToolCache,
            title: "Puppeteer 浏览器",
            patterns: [JunkPathPattern(homeRelative: ".cache/puppeteer")],
            tier: .checkFirst,
            rationale: "Puppeteer 为自动化测试下载的浏览器;清了脚本会失败,要重新 npm install 或 npx puppeteer browsers install。",
            source: JunkRuleTable.purgeApp,
            symbolName: "globe"
        ),
        // 上游「Dart Analysis Cache」
        JunkRule(
            id: "dart.analysisCache",
            group: .globalToolCache,
            title: "Dart 分析缓存",
            patterns: [JunkPathPattern(homeRelative: ".dartServer/.analysis-driver")],
            tier: .safe,
            rationale: "Dart / Flutter 语言服务器的分析结果,让项目打开得快;清了分析器重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "doc.text"
        ),
        // 上游「Hermes Agent Cache」
        // 与上游的差异:上游要求 Hermes 空闲时清(运行中的任务可能在用);在不在用我们这里不判,靠先检查
        JunkRule(
            id: "hermes.agentCache",
            group: .globalToolCache,
            title: "Hermes 智能体缓存",
            patterns: [JunkPathPattern(homeRelative: ".hermes/cache")],
            tier: .checkFirst,
            rationale: "Hermes 智能体的下载与临时工作区;要在它空闲时清(运行中的任务可能在用)。设置、密钥、会话不在这里。",
            source: JunkRuleTable.purgeApp,
            symbolName: "sparkles"
        ),
        // 上游「opencode Cache」
        // 与上游的差异:上游要求 opencode 空闲时清;在不在用我们这里不判,靠先检查
        JunkRule(
            id: "opencode.cache",
            group: .globalToolCache,
            title: "opencode 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/opencode")],
            tier: .checkFirst,
            rationale: "opencode 下载的包、工具与模型清单;要在它空闲时清,需要时重新获取。会话与登录信息不在这里。",
            source: JunkRuleTable.purgeApp,
            symbolName: "sparkles"
        ),
        // 上游「Conda Package Cache」
        // 与上游的差异:上游的说明是「用 conda clean --all 更合适」;照列,档位先检查
        JunkRule(
            id: "conda.packageCache",
            group: .globalToolCache,
            title: "Conda 包缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".conda/pkgs"),
                JunkPathPattern(homeRelative: "anaconda3/pkgs"),
                JunkPathPattern(homeRelative: "miniconda3/pkgs"),
                JunkPathPattern(homeRelative: "miniforge3/pkgs"),
                JunkPathPattern(homeRelative: "mambaforge/pkgs"),
                JunkPathPattern(homeRelative: "opt/anaconda3/pkgs"),
                JunkPathPattern(homeRelative: "opt/miniconda3/pkgs"),
            ],
            tier: .checkFirst,
            rationale: "conda 解包出来供各环境链接使用的包;环境靠链接到这些文件工作,清了实际腾出的空间比显示的少。想瘦身请用 conda clean --all。",
            source: JunkRuleTable.purgeApp,
            symbolName: "cube"
        ),
        // 上游「nvm Download Cache」
        JunkRule(
            id: "nvm.downloads",
            group: .globalToolCache,
            title: "nvm 下载缓存",
            patterns: [JunkPathPattern(homeRelative: ".nvm/.cache")],
            tier: .safe,
            rationale: "nvm 装完某个 Node 版本后留下的下载;已装的版本不动。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「giget Template Cache」
        JunkRule(
            id: "giget.cache",
            group: .globalToolCache,
            title: "giget 模板缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/giget")],
            tier: .safe,
            rationale: "giget 下载的项目模板(nuxi init 这类命令用的);下次建项目时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "doc"
        ),
        // 上游「Firebase Emulators」
        JunkRule(
            id: "firebase.emulators",
            group: .globalToolCache,
            title: "Firebase 模拟器",
            patterns: [JunkPathPattern(homeRelative: ".cache/firebase/emulators")],
            tier: .safe,
            rationale: "Firebase CLI 下载的模拟器文件;下次启动模拟器时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "flame"
        ),
        // 上游「Hex Package Cache」
        JunkRule(
            id: "hex.packages",
            group: .globalToolCache,
            title: "Hex 包缓存",
            patterns: [JunkPathPattern(homeRelative: ".hex/packages")],
            tier: .safe,
            rationale: "Hex 留着的 Elixir / Erlang 包下载,免得重复构建时重下;清了下次构建重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Rebar3 Cache」
        JunkRule(
            id: "rebar3.cache",
            group: .globalToolCache,
            title: "Rebar3 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/rebar3")],
            tier: .safe,
            rationale: "Rebar3 留着的包下载与构建插件;清了下次构建重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「NuGet Packages」
        JunkRule(
            id: "nuget.packages",
            group: .globalToolCache,
            title: "NuGet 包",
            patterns: [JunkPathPattern(homeRelative: ".nuget/packages")],
            tier: .checkFirst,
            rationale: ".NET 还原项目用的包;不丢东西,但下次还原要全部重新下载,需要联网。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Cabal Packages」
        JunkRule(
            id: "cabal.packages",
            group: .globalToolCache,
            title: "Cabal 包",
            patterns: [JunkPathPattern(homeRelative: ".cabal/packages")],
            tier: .checkFirst,
            rationale: "Cabal 下载的 Haskell 包;不丢东西,但下次构建要重新下载、重新编译,可能很久。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Stack Cache」
        JunkRule(
            id: "stack.cache",
            group: .globalToolCache,
            title: "Stack 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".stack/pantry"),
                JunkPathPattern(homeRelative: ".stack/snapshots"),
            ],
            tier: .checkFirst,
            rationale: "Stack 跨项目共享的包与预编译库;设置与已装的编译器不动。下次构建要下载、重编很多。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Bazel Cache」
        JunkRule(
            id: "bazel.cache",
            group: .globalToolCache,
            title: "Bazel 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/bazel")],
            tier: .checkFirst,
            rationale: "Bazel 在多次构建之间缓存的产出;清了下次构建从头来,可能很慢。",
            source: JunkRuleTable.purgeApp,
            symbolName: "hammer"
        ),
        // 上游「Android Build Cache」
        JunkRule(
            id: "android.buildCache",
            group: .globalToolCache,
            title: "Android 构建缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".android/cache"),
                JunkPathPattern(homeRelative: ".android/build-cache"),
            ],
            tier: .safe,
            rationale: "Android 构建工具的缓存,下次构建重建;模拟器、调试密钥与签名密钥不在这里。",
            source: JunkRuleTable.purgeApp,
            symbolName: "hammer"
        ),
        JunkRule(
            id: "zed.caches",
            group: .globalToolCache,
            title: "Zed 缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/Zed"),
                JunkPathPattern(homeRelative: "Library/Caches/zed"),
            ],
            tier: .safe,
            rationale: "Zed 编辑器的临时文件;再次启动时重建。设置与扩展不在这里。",
            source: JunkRuleTable.purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        // 上游「SBT Cache」
        JunkRule(
            id: "sbt.ivyCache",
            group: .globalToolCache,
            title: "sbt / Ivy 缓存",
            patterns: [JunkPathPattern(homeRelative: ".ivy2/cache")],
            tier: .checkFirst,
            rationale: "sbt / Ivy 下载的 Java 与 Scala 库;不丢东西,但下次构建要全部重新下载,又慢又要联网。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // None
        // 上游这一行是动态的(.gem/specs 加各 Ruby 版本目录下的 cache);只有 .gem/specs 是固定路径
        JunkRule(
            id: "rubygems.downloads",
            group: .globalToolCache,
            title: "RubyGems 下载缓存",
            patterns: [JunkPathPattern(homeRelative: ".gem/specs")],
            tier: .safe,
            rationale: "RubyGems 装完 gem 后留下的规格索引;已装的 gem 不动,需要时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Bundler Cache」
        JunkRule(
            id: "bundler.cache",
            group: .globalToolCache,
            title: "Bundler 缓存",
            patterns: [JunkPathPattern(homeRelative: ".bundle/cache")],
            tier: .safe,
            rationale: "Bundler 下载的 Ruby gem 缓存;运行 bundle install 时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Composer Cache」
        JunkRule(
            id: "composer.cache",
            group: .globalToolCache,
            title: "Composer 缓存",
            patterns: [JunkPathPattern(homeRelative: ".composer/cache")],
            tier: .safe,
            rationale: "Composer 下载的 PHP 包缓存;运行 composer install 时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Terraform Cache」
        JunkRule(
            id: "terraform.pluginCache",
            group: .globalToolCache,
            title: "Terraform 插件缓存",
            patterns: [JunkPathPattern(homeRelative: ".terraform.d/plugin-cache")],
            tier: .safe,
            rationale: "Terraform 下载的提供者插件缓存;运行 terraform init 时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「GitHub Actions Cache」
        JunkRule(
            id: "githubActions.cache",
            group: .globalToolCache,
            title: "GitHub Actions 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/act")],
            tier: .safe,
            rationale: "在本地跑 GitHub Actions(act)用的缓存文件;自动重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Vagrant Cache」
        JunkRule(
            id: "vagrant.cache",
            group: .globalToolCache,
            title: "Vagrant 缓存",
            patterns: [
                JunkPathPattern(homeRelative: ".vagrant.d/boxes"),
                JunkPathPattern(homeRelative: ".vagrant.d/tmp"),
            ],
            tier: .checkFirst,
            rationale: "Vagrant 用的虚拟机镜像;不用了可以清——重新下载要一阵。",
            source: JunkRuleTable.purgeApp,
            symbolName: "square.stack.3d.up"
        ),
        // None
        // 上游还登记了一个文件 .zcompdump;规则只认目录,那个文件很小,不收
        JunkRule(
            id: "zsh.sessions",
            group: .globalToolCache,
            title: "终端会话记录",
            patterns: [JunkPathPattern(homeRelative: ".zsh_sessions")],
            tier: .safe,
            rationale: "终端 shell 的会话恢复文件;开新终端窗口时重建。清了之后,重启终端时恢复不了上次的窗口与会话。",
            source: JunkRuleTable.purgeApp,
            symbolName: "terminal"
        ),
        // None
        // 与上游的差异:上游只列没有任何项目在用的浏览器版本(读各项目的锁文件现算);我们整目录一条、恒先检查
        JunkRule(
            id: "playwright.browsers",
            group: .globalToolCache,
            title: "Playwright 浏览器",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/ms-playwright"),
                JunkPathPattern(homeRelative: "Library/Caches/ms-playwright-go"),
            ],
            tier: .checkFirst,
            rationale: "Playwright 为自动化测试下载的浏览器(含 Go 版);清了测试会失败,要重新 npx playwright install。",
            source: JunkRuleTable.purgeApp,
            symbolName: "globe"
        ),
        JunkRule(
            id: "typescript.typeCache",
            group: .globalToolCache,
            title: "TypeScript 类型缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/typescript")],
            tier: .safe,
            rationale: "编辑器为纯 JavaScript 项目下载的类型定义(自动补全用);需要时重新下载。",
            source: JunkRuleTable.purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        JunkRule(
            id: "cypress.binaries",
            group: .globalToolCache,
            title: "Cypress 测试程序",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/Cypress")],
            tier: .checkFirst,
            rationale: "运行端到端测试的 Cypress 程序;清了测试会失败,要重新 npx cypress install。",
            source: JunkRuleTable.purgeApp,
            symbolName: "hammer"
        ),
        JunkRule(
            id: "mise.cache",
            group: .globalToolCache,
            title: "Mise 缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/mise"),
                JunkPathPattern(homeRelative: "Library/Caches/rtx"),
            ],
            tier: .safe,
            rationale: "Mise(原 rtx,管理工具版本的)缓存的版本列表等数据;已装的工具不动,Mise 需要时重新拉取。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "androidStudio.caches",
            group: .globalToolCache,
            title: "Android Studio 缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/com.google.android.studio")],
            tier: .safe,
            rationale: "Android Studio 的临时文件;再次启动时重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        JunkRule(
            id: "apple.pythonCache",
            group: .globalToolCache,
            title: "系统 Python 编译缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/com.apple.python")],
            tier: .checkFirst,
            rationale: "macOS 开发者工具自带的 Python 的编译文件;下次运行时重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "chevron.left.forwardslash.chevron.right"
        ),
        JunkRule(
            id: "simulator.runtimeCache",
            group: .globalToolCache,
            title: "模拟器运行时缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/com.apple.iphonesimulator")],
            tier: .checkFirst,
            rationale: "iOS 模拟器跑应用时产生的临时文件;下次启动模拟器时重建。",
            source: JunkRuleTable.purgeApp,
            symbolName: "ipad"
        ),
        // Pulse 自定:本机构建 Pulse 的脚本用的 SwiftPM 包缓存,上游表里没有
        JunkRule(
            id: "pulse.swiftpmCache",
            group: .globalToolCache,
            title: "Pulse 构建依赖缓存",
            patterns: [JunkPathPattern(homeRelative: "Library/Caches/pulse-swiftpm")],
            tier: .checkFirst,
            rationale: "Pulse 自己构建时缓存的 SwiftPM 依赖包;清了下次构建 Pulse 要联网重新拉取。",
            source: JunkRuleTable.pulseCustom,
            symbolName: "swift"
        ),
        // 上游「Go Module Cache」是 medium(要联网重下、缓存里改过的内容会丢);p6 时与构建缓存合成一条 go.caches
        JunkRule(
            id: "go.moduleCache",
            group: .globalToolCache,
            title: "Go 模块缓存",
            patterns: [JunkPathPattern(homeRelative: "go/pkg/mod")],
            tier: .checkFirst,
            rationale: "Go 项目下载的依赖模块;下次构建要联网重新下载。直接改过缓存里模块的话,改动会丢。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // 上游「Go Build Cache」是 safe;与上面那条模块缓存在上游就是两行两档
        JunkRule(
            id: "go.buildCache",
            group: .globalToolCache,
            title: "Go 构建缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Caches/go-build"),
                JunkPathPattern(homeRelative: ".cache/go-build"),
            ],
            tier: .safe,
            rationale: "Go 的编译缓存;下次构建重新编译。",
            source: JunkRuleTable.purgeApp,
            symbolName: "shippingbox"
        ),
        // —— p7-cleaner/10 补差结束 ——
    ]

    /// 固定路径的应用缓存条目(不在 ~/Library/Caches 一级,进不了知识库)。
    /// 日志规则含崩溃报告子目录——一条覆盖,不另开子规则(父子两张卡会重复计数)。
    static let appCacheFixedRules: [JunkRule] = [
        JunkRule(
            id: "appcache.logs",
            group: .appCache,
            title: "应用日志",
            patterns: [JunkPathPattern(homeRelative: "Library/Logs")],
            tier: .safe,
            rationale: "各 App 的运行日志与崩溃报告;排障时有用,平时可清,需要时自动重新生成。",
            source: purgeAppExplanations,
            symbolName: "doc.text"
        ),
        // p7-cleaner/10:上游把这一行放在「开发工具」里,说的却是应用的网页缓存;我们归应用缓存组。
        // 路径逐字取自上游 DevScanner.globalCacheDefinitions「Electron App Caches」。
        JunkRule(
            id: "appcache.electronApps",
            group: .appCache,
            title: "Electron 应用缓存",
            patterns: [
                JunkPathPattern(homeRelative: "Library/Application Support/Slack/Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/Slack/Code Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/discord/Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/discord/Code Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/Notion/Cache"),
                JunkPathPattern(homeRelative: "Library/Application Support/Figma/Cache"),
            ],
            tier: .safe,
            rationale: "Slack、Discord、Notion、Figma 这些用 Electron 做的应用的网页与代码缓存;应用打开时重建。登录与聊天记录不在这里。",
            source: JunkRuleTable.purgeAppExplanations,
            symbolName: "cube"
        ),
    ]

    /// AI 模型四存储位(p6-cleaner/02,spec 定案 11;全「先检查」——删的是重新
    /// 下载代价大的模型本体,不是可重建缓存)。存储位 = 各工具官方默认路径常识
    /// (非 purge-app 移植);Ollama 目录布局另有官方 docs + 本仓探针
    /// docs/probes/13 实测背书。Ollama 的「真实可回收」按内容寻址清单重算,
    /// 见 `OllamaStoreAccounting`(本表只担保「这块属于 AI 模型域」)。
    static let aiModelRules: [JunkRule] = [
        JunkRule(
            id: OllamaStoreAccounting.ruleID,
            group: .aiModels,
            title: "Ollama 模型",
            patterns: [JunkPathPattern(homeRelative: ".ollama/models")],
            tier: .checkFirst,
            rationale: "Ollama 下载的全部模型(内容寻址存储,两个模型共享的层只计一次)。删除后要用得重新 pull,大模型一次几个 GB;Ollama 服务在跑时整组列在用保护。",
            source: "Pulse 自定(存储位 = Ollama 官方默认路径 + docs/probes/13 实测布局)",
            symbolName: "brain"
        ),
        JunkRule(
            id: "ai.lmstudio",
            group: .aiModels,
            title: "LM Studio 模型",
            patterns: [JunkPathPattern(homeRelative: ".lmstudio/models")],
            tier: .checkFirst,
            rationale: "LM Studio 下载的模型文件。删除后需要重新下载;正在下载或加载模型时清理会打断它。",
            source: "Pulse 自定(存储位 = LM Studio 官方默认路径常识)",
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "ai.huggingface",
            group: .aiModels,
            title: "HuggingFace 缓存",
            patterns: [JunkPathPattern(homeRelative: ".cache/huggingface")],
            tier: .checkFirst,
            rationale: "HuggingFace 命令行工具(pipelines / transformers 脚本)下载的模型缓存。删除后重新下载;相关脚本首次运行会明显变慢。",
            source: "Pulse 自定(存储位 = HuggingFace hub 官方默认缓存路径常识)",
            symbolName: "shippingbox"
        ),
        JunkRule(
            id: "ai.gpt4all",
            group: .aiModels,
            title: "GPT4All 数据",
            patterns: [JunkPathPattern(homeRelative: "Library/Application Support/GPT4All")],
            tier: .checkFirst,
            rationale: "GPT4All 的常用数据位。注意:除模型外还可能带着聊天记录与设置,确认不再需要再清。",
            source: "Pulse 自定(存储位 = GPT4All 常用位常识,票面拍板路径)",
            symbolName: "shippingbox"
        ),
    ]

    /// 全量规则 = 开发工具 + 知识库目录规则 + 固定路径条目 + AI 模型。孤儿域收窄
    /// (`OrphanLeftovers.excludingOverlaps`)吃的就是这些候选,新规则自动生效。
    public static let builtin: [JunkRule] =
        globalToolCacheRules + AppCacheCatalog.rules + appCacheFixedRules + aiModelRules

    /// 轻桥判定(p4-uninstaller/05):路径命中内置白名单 → 对应组;不命中 → nil。
    /// 与可清理清单**同源**(同一个规则表、同一套 JunkPathPattern 语义),
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
    /// 大卡分组键(项目产物/卸载残留专用;全局缓存为 nil)。项目产物 = 产物
    /// 直接父目录完整路径、卸载残留 = 完整 bundle id(cleaner-junk-card-fixes/02,
    /// 两条语义均要求全量键:同名异路必异卡)。显示层取末段/尾段做大字,全量进元信息。
    public let projectName: String?
    /// 项目年龄(05:项目直属树内**非产物**文件的最后变动;全局缓存为 nil)。
    /// 界面换算成「N 天未动」;排序「按新旧」以它为准(nil 排最后)。
    public let newestChangeEpoch: Double?
    /// 扫描时刻目录自身 mtime(p5-cleaner/03 删前复核快照,= 节点 `ownModifiedEpoch`)。
    /// nil = 扫描没拿到(旧版缓存 / 文件系统没给)→ 删除时按「缺少扫描快照」跳过。
    public let modifiedAtScan: Double?
    /// 计入口径标注(p6-cleaner/02):Ollama 内容寻址在清单不可用时按整目录兜底,
    /// 行副标如实说明(nil = 无标注;沿用「部分扫描」附标惯例,不造新行形态)。
    public let accountingNote: String?
    /// 条目标志清单(p7-cleaner/01;GLOSSARY「条目标志」):系统级条目带
    /// 「需要管理员权限」,通用发现的条目带「未识别」。标志在候选上只有这一份(唯一出处),
    /// 存进去的已是规范形(固定序、去重);规则表匹配产出的候选恒为空。
    public let flags: [JunkCandidateFlag]

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
        newestChangeEpoch: Double? = nil,
        modifiedAtScan: Double? = nil,
        accountingNote: String? = nil,
        flags: [JunkCandidateFlag] = []
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
        self.modifiedAtScan = modifiedAtScan
        self.accountingNote = accountingNote
        self.flags = JunkCandidateFlag.normalized(flags)
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
            newestChangeEpoch: node.newestChangeEpoch,
            modifiedAtScan: node.ownModifiedEpoch
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
