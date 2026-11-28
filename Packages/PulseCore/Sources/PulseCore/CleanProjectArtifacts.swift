import Foundation

// MARK: - 项目产物(p4-cleaner/05):按名匹配、按项目分组、年龄口径

//
// 与全局工具缓存(04,JunkRules.swift)同一条安全边界线上的第二个规则域:
// 用户配置的**清理扫描根**(独立于归组的项目根,两套配置解耦——用户拍板)之下,
// 项目 = 扫描根的直接子目录(扫描根本身也算一个项目:只认它的直接产物);
// 产物 = 项目子树内**目录名全等**命中规则的目录,嵌套产物(monorepo 子包的
// node_modules)不重复列——外层产物的字节数已经含着它。
//
// 规则表(p7-cleaner/10 自 purge-app 的 `ProjectArtifactCatalog` 全量搬运;MIT,可移植):上游
// 一张表 47 行,这边 38 条——同名的几行(target、_build、.gradle、Pods、build)合成一条,标记取
// 并集。每条带四样东西,都是上游的形状:
//   · 根标记(`markers`):旁边的工程文件证明「这真是构建产物」。上游相对项目根写,这里相对
//     产物所在的目录写。上游带子目录的产物里,`ios/Pods`、`android/.gradle` 的工程文件就在产物
//     旁边(同级文件);只有 sbt 的 `project/target` 的工程文件在再上一级(`parentSibling`)。没有
//     固定文件名的工程文件按扩展名认(`siblingExtension`)。
//   · 拒绝条件(`refuseWhenPresent`):产物里只要有这些文件之一就整个不列(`.terraform` 里
//     偶尔会有的状态文件——丢了它等于丢了对真实基础设施的跟踪)。
//   · 重建说明(`reinstall`):怎么把它装回来,随说明一起给用户看。
//   · 出处(`source`)。
// 档位:上游 medium → 先检查;上游 safe 而我们表达不了它的根标记的、或有意更严的(目录名太
// 通用的 build / dist 不设标记)→ 先检查。逐行的下落由 `ProjectArtifactPortLedgerTests` 的
// 搬运账本钉住。
//
// 年龄口径(票面钉死):项目年龄 = 项目内**文件** mtime 的最大值,但**跳过产物
// 子树**——「重装依赖不刷新年龄」;含 git 活动:.git 下的文件(FETCH_HEAD 等)
// 也是文件,天然计入。目录自身 mtime 有意不算(引擎侧就没聚合,见
// `SpaceNode.newestChangeEpoch`)。

/// 项目标记:佐证「这个同名目录真是构建产物」的盘上事实(cleaner-hardening/02)。
/// 扫描树只留目录节点,标记要现查盘——经 `fileExists` / `fileExtensions` 注入,本文件仍无 IO。
public enum ArtifactMarker: Sendable, Equatable {
    /// 产物旁边的同级文件(`target` 旁的 `Cargo.toml`;可以带一级子目录,如 `ProjectSettings/ProjectVersion.txt`)。
    case sibling(String)
    /// 产物所在目录的上一级里的文件:sbt 的元构建 `project/target`,工程文件 `build.sbt` 在项目根,
    /// 也就是产物所在目录的上一级(上游的根标记一律相对项目根写)。
    case parentSibling(String)
    /// 产物里面的文件(`.venv/pyvenv.cfg`)。
    case inside(String)
    /// 产物旁边任一文件带这个扩展名:没有固定文件名的工程文件(`bin` 旁的 `.csproj` / `.sln`、
    /// `.terraform` 旁的 `.tf`、Unreal 的 `.uproject`)。不分大小写。
    case siblingExtension(String)

    /// 这个标记在盘上成不成立。
    /// - Parameters:
    ///   - artifactPath: 产物目录的路径。
    ///   - fileExists: 路径上有东西(文件或目录)。
    ///   - fileExtensions: 某个目录的直接子项里,文件扩展名(小写)的集合;读不了 = 空。
    func isSatisfied(
        artifactPath: String,
        fileExists: (String) -> Bool,
        fileExtensions: (String) -> Set<String>
    ) -> Bool {
        let parent = (artifactPath as NSString).deletingLastPathComponent
        switch self {
        case let .sibling(name):
            return fileExists(parent + "/" + name)
        case let .parentSibling(name):
            return fileExists((parent as NSString).deletingLastPathComponent + "/" + name)
        case let .inside(name):
            return fileExists(artifactPath + "/" + name)
        case let .siblingExtension(fileExtension):
            return fileExtensions(parent).contains(fileExtension.lowercased())
        }
    }
}

/// 项目产物规则:目录名全等匹配 + 安全档 + 说明与重建说明 + 根标记 + 拒绝条件 + 出处。
/// 一条目录名只许有一条规则(引擎按目录名建表;同名的几种工程合成一条,标记取并集)。
public struct ProjectArtifactRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var directoryName: String
    public var tier: CleanSafetyTier
    /// 说明:这是什么、清了会怎样。
    public var rationale: String
    /// 拒绝条件:产物目录里只要有这些文件之一,整个不列。
    public var refuseWhenPresent: [String]
    /// 重建说明:怎么把它装回来(一句话)。
    public var reinstall: String
    /// 根标记(任一成立即算命中;空 = 不要求——只许用于「先检查」档,安全档必须带标记,有测试钉住)。
    public var markers: [ArtifactMarker]
    /// 出处:上游(MIT,可移植)或 Pulse 自定。
    public var source: String
    public var symbolName: String

    public init(
        id: String,
        directoryName: String,
        tier: CleanSafetyTier,
        rationale: String,
        refuseWhenPresent: [String] = [],
        reinstall: String,
        markers: [ArtifactMarker] = [],
        source: String,
        symbolName: String
    ) {
        self.id = id
        self.directoryName = directoryName
        self.tier = tier
        self.rationale = rationale
        self.refuseWhenPresent = refuseWhenPresent
        self.reinstall = reinstall
        self.markers = markers
        self.source = source
        self.symbolName = symbolName
    }

    /// 给用户看的说明:是什么 + 重建办法。
    public var displayedRationale: String {
        "\(rationale)。重建:\(reinstall)。"
    }
}

/// 内置规则表。**新增规则必须能在 `ProjectArtifactPortLedgerTests` 的账本里找到上游的行**
/// (登记完整性:每条规则都要被 `ProjectArtifactTests` 的正例命中,上游的行要逐个对上标记)。
/// 表由脚本自上游源码生成后粘入(目录名与标记逐字取自上游,防手抄错字);想加上游没有的,
/// 在那条上方注明「Pulse 自定」,并在账本测试里点名放行。
public enum ProjectArtifactRuleTable {
    public static let builtin: [ProjectArtifactRule] = [
        ProjectArtifactRule(
            id: "artifact.node_modules",
            directoryName: "node_modules",
            tier: .safe,
            rationale: "npm / pnpm / yarn 的依赖包",
            reinstall: "在项目目录运行 npm install(按锁文件也可能是 pnpm install 或 yarn)",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "shippingbox"
        ),

        // 上游的同名几行由这一条担保(标记取并集):Pods(xcode)、ios/Pods(xcode)
        ProjectArtifactRule(
            id: "artifact.pods",
            directoryName: "Pods",
            tier: .safe,
            rationale: "CocoaPods 的依赖",
            reinstall: "在 Podfile 所在目录运行 pod install",
            markers: [.sibling("Podfile")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "cube"
        ),

        ProjectArtifactRule(
            id: "artifact.venv",
            directoryName: "venv",
            tier: .safe,
            rationale: "Python 虚拟环境(装着这个项目的包)",
            reinstall: "按项目平时的步骤重建(pip install -r requirements.txt、uv sync 等),需要联网",
            markers: [.inside("pyvenv.cfg")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "cube"
        ),

        ProjectArtifactRule(
            id: "artifact.dot-venv",
            directoryName: ".venv",
            tier: .safe,
            rationale: "Python 虚拟环境(装着这个项目的包)",
            reinstall: "按项目平时的步骤重建(pip install -r requirements.txt、uv sync 等),需要联网",
            markers: [.inside("pyvenv.cfg")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "cube"
        ),

        // 上游的同名几行由这一条担保(标记取并集):target(rust)、target(maven)、target(sbt)、project/target(sbt)
        ProjectArtifactRule(
            id: "artifact.target",
            directoryName: "target",
            tier: .safe,
            rationale: "Rust / Maven / sbt 的编译产物",
            reinstall: "cargo build / mvn package / sbt compile",
            markers: [
                .sibling("Cargo.toml"),
                .sibling("pom.xml"),
                .sibling("build.sbt"),
                .parentSibling("build.sbt"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.swiftpm-build",
            directoryName: ".build",
            tier: .safe,
            rationale: "Swift Package Manager 的构建产物",
            reinstall: "swift build",
            markers: [.sibling("Package.swift")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.next-cache",
            directoryName: ".next",
            tier: .safe,
            rationale: "Next.js 编译出的页面与资源",
            reinstall: "重新构建(npm run build 等)",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        // 上游的同名几行由这一条担保(标记取并集):build(flutter)、build(gradleJVM)、build(cmake)
        ProjectArtifactRule(
            id: "artifact.gradle-build",
            directoryName: "build",
            tier: .checkFirst,
            rationale: "构建输出目录;个别项目把源码或资源放在 build 下,先检查",
            reinstall: "运行项目平时的构建(./gradlew build、flutter build、cmake --build 等)",
            markers: [],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        // Pulse 自定:上游表里没有这一行(目录名太通用的分发输出)
        ProjectArtifactRule(
            id: "artifact.dist",
            directoryName: "dist",
            tier: .checkFirst,
            rationale: "分发输出;多数是构建产物,但也有仓库直接把它当产物库,先检查",
            reinstall: "运行项目平时的构建",
            markers: [],
            source: JunkRuleTable.pulseCustom,
            symbolName: "shippingbox"
        ),

        ProjectArtifactRule(
            id: "artifact.nuxt-build",
            directoryName: ".nuxt",
            tier: .safe,
            rationale: "Nuxt 的临时构建文件",
            reinstall: "重新构建(npm run build)",
            markers: [
                .sibling("nuxt.config.ts"),
                .sibling("nuxt.config.js"),
                .sibling("nuxt.config.mjs"),
                .sibling("nuxt.config.cjs"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.nuxt-output",
            directoryName: ".output",
            tier: .safe,
            rationale: "Nuxt 构建出来、用于部署的站点",
            reinstall: "重新构建(npm run build)",
            markers: [
                .sibling("nuxt.config.ts"),
                .sibling("nuxt.config.js"),
                .sibling("nuxt.config.mjs"),
                .sibling("nuxt.config.cjs"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.sveltekit-build",
            directoryName: ".svelte-kit",
            tier: .safe,
            rationale: "SvelteKit 在多次构建之间保留的生成文件",
            reinstall: "重新运行或构建项目",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.astro-build",
            directoryName: ".astro",
            tier: .safe,
            rationale: "Astro 的临时构建文件",
            reinstall: "重新运行或构建项目",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.angular-cache",
            directoryName: ".angular",
            tier: .safe,
            rationale: "Angular CLI 的构建缓存",
            reinstall: "下次构建自动重建",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.turbo-cache",
            directoryName: ".turbo",
            tier: .safe,
            rationale: "Turborepo 的构建缓存",
            reinstall: "下次构建从头来,慢一点",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.parcel-cache",
            directoryName: ".parcel-cache",
            tier: .safe,
            rationale: "Parcel 打包器的构建缓存",
            reinstall: "下次运行 Parcel 构建时重建",
            markers: [.sibling("package.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.pytest-cache",
            directoryName: ".pytest_cache",
            tier: .safe,
            rationale: "pytest 的测试结果与查找缓存",
            reinstall: "下次跑测试自动重建",
            markers: [
                .sibling("requirements.txt"),
                .sibling("pyproject.toml"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.mypy-cache",
            directoryName: ".mypy_cache",
            tier: .safe,
            rationale: "mypy 类型检查的缓存",
            reinstall: "下次运行 mypy 重建",
            markers: [
                .sibling("requirements.txt"),
                .sibling("pyproject.toml"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.ruff-cache",
            directoryName: ".ruff_cache",
            tier: .safe,
            rationale: "Ruff 代码检查的缓存",
            reinstall: "下次运行 ruff 重建",
            markers: [
                .sibling("requirements.txt"),
                .sibling("pyproject.toml"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.tox",
            directoryName: ".tox",
            tier: .checkFirst,
            rationale: "tox 为跑测试搭的一次性 Python 环境",
            reinstall: "运行 tox(重新下载依赖,较慢)",
            markers: [.sibling("tox.ini")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "cube"
        ),

        ProjectArtifactRule(
            id: "artifact.dart-tool",
            directoryName: ".dart_tool",
            tier: .safe,
            rationale: "Dart / Flutter 开发工具的临时目录",
            reinstall: "flutter pub get",
            markers: [.sibling("pubspec.yaml")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        // 上游的同名几行由这一条担保(标记取并集):.gradle(androidGradle)、android/.gradle(androidGradle)
        ProjectArtifactRule(
            id: "artifact.gradle-project-state",
            directoryName: ".gradle",
            tier: .safe,
            rationale: "Gradle 给这个项目记的状态(文件哈希、构建历史);下载的库不在这里,在用户目录的 .gradle 下",
            reinstall: "下次构建自动重建",
            markers: [
                .sibling("build.gradle"),
                .sibling("build.gradle.kts"),
                .sibling("settings.gradle"),
                .sibling("settings.gradle.kts"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        // 上游的同名几行由这一条担保(标记取并集):_build(elixir)、_build(ocamlDune)
        ProjectArtifactRule(
            id: "artifact.mix-build",
            directoryName: "_build",
            tier: .safe,
            rationale: "Elixir(Mix)/ OCaml(Dune)的编译产物",
            reinstall: "mix compile / dune build",
            markers: [
                .sibling("mix.exs"),
                .sibling("dune-project"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.elixir-deps",
            directoryName: "deps",
            tier: .safe,
            rationale: "Mix 为 Elixir / Erlang 项目下载的依赖源码",
            reinstall: "mix deps.get",
            markers: [.sibling("mix.exs")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "shippingbox"
        ),

        ProjectArtifactRule(
            id: "artifact.stack-work",
            directoryName: ".stack-work",
            tier: .checkFirst,
            rationale: "Stack 为这个 Haskell 项目留的编译产物与依赖",
            reinstall: "stack build(可能要一阵)",
            markers: [.sibling("stack.yaml")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.cabal-dist",
            directoryName: "dist-newstyle",
            tier: .checkFirst,
            rationale: "Cabal 为这个 Haskell 项目编译出的产物",
            reinstall: "cabal build(可能要一阵)",
            markers: [.siblingExtension("cabal")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.zig-cache",
            directoryName: ".zig-cache",
            tier: .safe,
            rationale: "Zig 的编译缓存",
            reinstall: "zig build",
            markers: [.sibling("build.zig")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.zig-cache-legacy",
            directoryName: "zig-cache",
            tier: .safe,
            rationale: "Zig 的编译缓存(旧版 Zig 的目录名)",
            reinstall: "zig build",
            markers: [.sibling("build.zig")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.zig-out",
            directoryName: "zig-out",
            tier: .safe,
            rationale: "Zig 构建出的程序与库",
            reinstall: "zig build",
            markers: [.sibling("build.zig")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "shippingbox"
        ),

        ProjectArtifactRule(
            id: "artifact.dotnet-bin",
            directoryName: "bin",
            tier: .safe,
            rationale: ".NET 构建出的程序与库",
            reinstall: "dotnet build",
            markers: [
                .siblingExtension("csproj"),
                .siblingExtension("fsproj"),
                .siblingExtension("vbproj"),
                .siblingExtension("sln"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "shippingbox"
        ),

        ProjectArtifactRule(
            id: "artifact.dotnet-obj",
            directoryName: "obj",
            tier: .safe,
            rationale: ".NET 编译过程的中间文件",
            reinstall: "dotnet build",
            markers: [
                .siblingExtension("csproj"),
                .siblingExtension("fsproj"),
                .siblingExtension("vbproj"),
                .siblingExtension("sln"),
            ],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.composer-vendor",
            directoryName: "vendor",
            tier: .safe,
            rationale: "Composer 下载的第三方 PHP 包",
            reinstall: "composer install(需要联网)",
            markers: [.sibling("composer.json")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "shippingbox"
        ),

        ProjectArtifactRule(
            id: "artifact.terraform-plugins",
            directoryName: ".terraform",
            tier: .checkFirst,
            rationale: "Terraform 下载的提供者插件与模块。注意:后端有时把状态文件与所选工作区也写在这里,丢了状态等于丢了对真实运行中基础设施的跟踪——里面有这些文件的,整个不列",
            refuseWhenPresent: ["terraform.tfstate", "terraform.tfstate.backup", "environment"],
            reinstall: "terraform init",
            markers: [.siblingExtension("tf")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "shippingbox"
        ),

        ProjectArtifactRule(
            id: "artifact.godot-cache",
            directoryName: ".godot",
            tier: .safe,
            rationale: "Godot 为这个项目导入的资源与编辑器数据",
            reinstall: "用 Godot 打开项目时自动重建",
            markers: [.sibling("project.godot")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.unity-library",
            directoryName: "Library",
            tier: .checkFirst,
            rationale: "Unity 给这个项目建的导入资源数据库;大项目重新导入可能要很久",
            reinstall: "用 Unity 打开工程时自动重新导入(大工程很久)",
            markers: [.sibling("ProjectSettings/ProjectVersion.txt")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.unity-temp",
            directoryName: "Temp",
            tier: .checkFirst,
            rationale: "Unity 编辑器运行时写的草稿文件;工程正在 Unity 里开着时不要清",
            reinstall: "下次用 Unity 打开工程时自动重建",
            markers: [.sibling("ProjectSettings/ProjectVersion.txt")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.unreal-intermediate",
            directoryName: "Intermediate",
            tier: .checkFirst,
            rationale: "Unreal 编译项目时生成的构建文件",
            reinstall: "下次构建 Unreal 项目时重建(比平时慢)",
            markers: [.siblingExtension("uproject")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),

        ProjectArtifactRule(
            id: "artifact.unreal-derived-data",
            directoryName: "DerivedDataCache",
            tier: .checkFirst,
            rationale: "Unreal 为项目缓存的烘焙资源与编译好的着色器",
            reinstall: "下次构建时重建(第一次会非常慢)",
            markers: [.siblingExtension("uproject")],
            source: JunkRuleTable.purgeAppArtifacts,
            symbolName: "hammer"
        ),
    ]
}

/// 项目产物匹配器:跑在扫描树上(与 04 同一棵树,不二次扫盘)。纯值、无 IO。
public enum ProjectArtifactMatcher {
    /// - Parameters:
    ///   - trees: 扫描产出(`SpaceScanResult.trees`)。
    ///   - roots: 清理扫描根(用户配置;不在树覆盖内的根静默跳过——多半没扫到)。
    ///   - excludedPathPrefixes: 排除目录(GLOSSARY)——与 04 同款双保险,扫后新加的排除即时生效。
    ///   - fileExists: 根标记与拒绝条件的探测(Live 传 FileManager;只对目录名已命中的少数目录调用)。
    ///   - fileExtensions: 按扩展名认的根标记要的目录清单(某目录的直接子项里文件扩展名的集合)。
    ///     只在规则带 `siblingExtension` 标记时才调用;默认空集 = 这种标记永不成立(不传就不认)。
    /// - Returns: 每个产物一个候选(按项目分组语义由 `projectName` 携带),
    ///   组内大到小;`newestChangeEpoch` = 项目年龄(不是产物自身的)。
    public static func artifacts(
        in trees: [SpaceNode],
        roots: [String],
        rules: [ProjectArtifactRule] = ProjectArtifactRuleTable.builtin,
        excludedPathPrefixes: [String] = [],
        fileExists: (String) -> Bool,
        fileExtensions: (String) -> Set<String> = { _ in [] }
    ) -> [JunkCandidate] {
        let rulesByName = Dictionary(uniqueKeysWithValues: rules.map { ($0.directoryName, $0) })
        var out: [JunkCandidate] = []
        // 目录清单按目录记住:同一次匹配里一个目录只列一次(一条规则可以带好几个按扩展名认的标记,
        // 同一个目录下也可以有几个产物——bin、obj 并排)。
        var listedExtensions: [String: Set<String>] = [:]
        let extensionsOf: (String) -> Set<String> = { directory in
            if let listed = listedExtensions[directory] {
                return listed
            }
            let value = fileExtensions(directory)
            listedExtensions[directory] = value
            return value
        }

        for root in roots {
            let rootPath = PathNormalization.normalize(root)
            guard rootPath.count > 1 else { continue } // "/" 不许当项目扫描根(那就是全卷)
            guard let rootNode = SpaceNode.locate(path: rootPath, in: trees) else { continue }

            // 扫描根本身是一个项目:只认直接产物子目录(DFS 会把子项目的产物全吞进来)。
            appendArtifacts(
                ofDirectChildrenOf: rootNode,
                rulesByName: rulesByName,
                excluded: excludedPathPrefixes,
                fileExists: fileExists,
                fileExtensions: extensionsOf,
                into: &out
            )

            // 直接子目录各是一个项目,项目内 DFS 找产物(monorepo 嵌套也收,产物内部不再下潜)。
            for project in rootNode.children where project.kind == .directory {
                var stack = [project]
                while let node = stack.popLast() {
                    appendArtifacts(
                        ofDirectChildrenOf: node,
                        rulesByName: rulesByName,
                        excluded: excludedPathPrefixes,
                        fileExists: fileExists,
                        fileExtensions: extensionsOf,
                        into: &out
                    )
                    for child in node.children
                        where child.kind == .directory && rulesByName[child.name] == nil {
                        stack.append(child)
                    }
                }
            }
        }

        return out.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path
        }
    }

    /// 一个目录的直接子项里命中规则的 → 候选;零字节非部分不列(与 04 同款噪音纪律)。
    /// 命中 = 目录名对上 + 根标记成立(或不要求)+ 拒绝条件一个都不成立。
    ///
    /// projectName 携带产物**直接父目录的完整路径**(cleaner-junk-card-fixes/02):
    /// 完整路径键两头都对——同一路径必同卡,不同路径(哪怕末段同名,如两个仓库
    /// 各自的 apps/desktop)必异卡。历史:05 用 DFS 顶层项目名,worktree 产物冒名
    /// (2026-11-05 实报);当天改成 `node.name`(末段名)修了冒名,又漏了同名
    /// 异路并卡与同项目拆卡(2026-11-09 实报)。年龄按直接父目录算,口径不变。
    private static func appendArtifacts(
        ofDirectChildrenOf node: SpaceNode,
        rulesByName: [String: ProjectArtifactRule],
        excluded: [String],
        fileExists: (String) -> Bool,
        fileExtensions: (String) -> Set<String>,
        into out: inout [JunkCandidate]
    ) {
        for child in node.children where child.kind == .directory {
            guard let rule = rulesByName[child.name], !CleanExclusions.isExcluded(child.path, by: excluded),
                  child.accountedBytes > 0 || child.isPartial,
                  rule.markers.contains(where: {
                      $0.isSatisfied(artifactPath: child.path, fileExists: fileExists, fileExtensions: fileExtensions)
                  }) || rule.markers.isEmpty,
                  !rule.refuseWhenPresent.contains(where: { fileExists(child.path + "/" + $0) })
            else { continue }
            out.append(JunkCandidate(
                ruleID: rule.id,
                group: .projectArtifacts,
                title: rule.directoryName,
                path: child.path,
                tier: rule.tier,
                bytes: child.accountedBytes,
                fileCount: child.fileCount,
                isPartial: child.isPartial,
                allReclaimableAccounting: child.allReclaimableAccounting,
                rationale: rule.displayedRationale,
                symbolName: rule.symbolName,
                projectName: node.path,
                newestChangeEpoch: projectAge(of: node, rulesByName: rulesByName),
                modifiedAtScan: child.ownModifiedEpoch
            ))
        }
    }

    /// 生产用的目录清单:某个目录的直接子项里,**普通文件**扩展名(小写)的集合;读不了 = 空。
    /// 只认普通文件——目录名带点(`.terraform.d`)、符号链接都不算工程文件。放在核心包是为了能直接测
    /// (只依赖 Foundation;这一处列目录就是本文件全部的 IO)。调用方经 `fileExtensions` 注入。
    public static func fileExtensions(ofDirectory path: String) -> Set<String> {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )) ?? []
        return Set(children.compactMap { child -> String? in
            guard let isRegular = try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular else { return nil }
            let fileExtension = child.pathExtension.lowercased()
            return fileExtension.isEmpty ? nil : fileExtension
        })
    }

    /// 项目年龄:项目子树内文件 mtime 最大值,**跳过产物子树**(重装依赖不刷新年龄)。
    /// 口径 = 逐层 DFS 取每个非产物目录的**直属文件** mtime 聚合
    /// (`SpaceNode.newestChangeEpoch` 只含直属文件,见引擎侧注释)——不用子树
    /// 聚合是为了产物内部的 mtime 一点都不漏进来。nil = 项目内没有已知 mtime。
    static func projectAge(
        of project: SpaceNode,
        rulesByName: [String: ProjectArtifactRule]
    ) -> Double? {
        var newest: Double?
        var stack: [SpaceNode] = [project]
        while let node = stack.popLast() {
            if let epoch = node.newestChangeEpoch {
                newest = max(newest ?? epoch, epoch)
            }
            for child in node.children {
                guard child.kind == .directory else { continue }
                if rulesByName[child.name] != nil {
                    continue
                } // 产物子树整体跳过
                stack.append(child)
            }
        }
        return newest
    }
}
