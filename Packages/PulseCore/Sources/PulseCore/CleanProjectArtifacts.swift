import Foundation

// MARK: - 项目产物(p4-cleaner/05):按名匹配、按项目分组、年龄口径

//
// 与全局工具缓存(04,JunkRules.swift)同一条安全边界线上的第二个规则域:
// 用户配置的**清理扫描根**(独立于归组的项目根,两套配置解耦——用户拍板)之下,
// 项目 = 扫描根的直接子目录(扫描根本身也算一个项目:只认它的直接产物);
// 产物 = 项目子树内**目录名全等**命中规则的目录,嵌套产物(monorepo 子包的
// node_modules)不重复列——外层产物的字节数已经含着它。
//
// 年龄口径(票面钉死):项目年龄 = 项目内**文件** mtime 的最大值,但**跳过产物
// 子树**——「重装依赖不刷新年龄」;含 git 活动:.git 下的文件(FETCH_HEAD 等)
// 也是文件,天然计入。目录自身 mtime 有意不算(引擎侧就没聚合,见
// `SpaceNode.newestChangeEpoch`)。

/// 项目标记:佐证「这个同名目录真是构建产物」的文件(cleaner-hardening/02)。
/// 扫描树只留目录节点,标记要现查盘——经 `fileExists` 注入,本文件仍无 IO。
public enum ArtifactMarker: Sendable, Equatable {
    /// 产物旁边的同级文件(`target` 旁的 `Cargo.toml`)。
    case sibling(String)
    /// 产物里面的文件(`.venv/pyvenv.cfg`)。
    case inside(String)

    func path(forArtifactAt artifactPath: String) -> String {
        switch self {
        case let .sibling(name): (artifactPath as NSString).deletingLastPathComponent + "/" + name
        case let .inside(name): artifactPath + "/" + name
        }
    }
}

/// 项目产物规则:目录名全等匹配 + 安全档 + 说明 + 项目标记(任一存在即算命中;
/// 空 = 不要求——只许用于「先检查」档,安全档必须带标记,有测试钉住)。
public struct ProjectArtifactRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var directoryName: String
    public var tier: CleanSafetyTier
    public var rationale: String
    public var symbolName: String
    public var markers: [ArtifactMarker]

    public init(
        id: String,
        directoryName: String,
        tier: CleanSafetyTier,
        rationale: String,
        symbolName: String,
        markers: [ArtifactMarker] = []
    ) {
        self.id = id
        self.directoryName = directoryName
        self.tier = tier
        self.rationale = rationale
        self.symbolName = symbolName
        self.markers = markers
    }
}

/// 内置规则表。**新增规则必须在 `ProjectArtifactRuleTableTests.positiveExamples`
/// 补正例**(登记完整性测试,ADR-0008 的安全边界本体:没被正例覆盖的规则过不了测试)。
/// 档位判断:重建一条命令、目录名无歧义的 = 可安全清理;目录名可能装着源码 / 仓库
/// 直接存产物的 = 先检查。
public enum ProjectArtifactRuleTable {
    public static let builtin: [ProjectArtifactRule] = [
        ProjectArtifactRule(
            id: "artifact.node_modules",
            directoryName: "node_modules",
            tier: .safe,
            rationale: "npm / pnpm / yarn 依赖,删除后重新 install 重建",
            symbolName: "shippingbox",
            markers: [.sibling("package.json")]
        ),
        ProjectArtifactRule(
            id: "artifact.pods",
            directoryName: "Pods",
            tier: .safe,
            rationale: "CocoaPods 依赖,删除后 pod install 重建",
            symbolName: "cube",
            markers: [.sibling("Podfile")]
        ),
        ProjectArtifactRule(
            id: "artifact.venv",
            directoryName: "venv",
            tier: .safe,
            rationale: "Python 虚拟环境,重建即可",
            symbolName: "cube",
            markers: [.inside("pyvenv.cfg")]
        ),
        ProjectArtifactRule(
            id: "artifact.dot-venv",
            directoryName: ".venv",
            tier: .safe,
            rationale: "Python 虚拟环境,重建即可",
            symbolName: "cube",
            markers: [.inside("pyvenv.cfg")]
        ),
        ProjectArtifactRule(
            id: "artifact.cargo-target",
            directoryName: "target",
            tier: .safe,
            rationale: "Rust / Cargo 构建产物,删除后 cargo build 重建",
            symbolName: "hammer",
            markers: [.sibling("Cargo.toml")]
        ),
        ProjectArtifactRule(
            id: "artifact.swiftpm-build",
            directoryName: ".build",
            tier: .safe,
            rationale: "SwiftPM 构建产物,删除后 swift build 重建",
            symbolName: "hammer",
            markers: [.sibling("Package.swift")]
        ),
        ProjectArtifactRule(
            id: "artifact.next-cache",
            directoryName: ".next",
            tier: .safe,
            rationale: "Next.js 构建缓存,重新构建时再生",
            symbolName: "hammer",
            markers: [.sibling("package.json")]
        ),
        ProjectArtifactRule(
            id: "artifact.gradle-build",
            directoryName: "build",
            tier: .checkFirst,
            rationale: "构建输出目录;个别项目把源码或资源放在 build 下,先检查",
            symbolName: "hammer"
        ),
        ProjectArtifactRule(
            id: "artifact.dist",
            directoryName: "dist",
            tier: .checkFirst,
            rationale: "分发输出;多数是构建产物,但也有仓库直接把它当产物库,先检查",
            symbolName: "shippingbox"
        ),
    ]
}

/// 项目产物匹配器:跑在扫描树上(与 04 同一棵树,不二次扫盘)。纯值、无 IO。
public enum ProjectArtifactMatcher {
    /// - Parameters:
    ///   - trees: 扫描产出(`SpaceScanResult.trees`)。
    ///   - roots: 清理扫描根(用户配置;不在树覆盖内的根静默跳过——多半没扫到)。
    ///   - excludedPathPrefixes: 排除目录(GLOSSARY)——与 04 同款双保险,扫后新加的排除即时生效。
    ///   - fileExists: 项目标记探测(Live 传 FileManager;只对目录名已命中的少数目录调用)。
    /// - Returns: 每个产物一个候选(按项目分组语义由 `projectName` 携带),
    ///   组内大到小;`newestChangeEpoch` = 项目年龄(不是产物自身的)。
    public static func artifacts(
        in trees: [SpaceNode],
        roots: [String],
        rules: [ProjectArtifactRule] = ProjectArtifactRuleTable.builtin,
        excludedPathPrefixes: [String] = [],
        fileExists: (String) -> Bool
    ) -> [JunkCandidate] {
        let rulesByName = Dictionary(uniqueKeysWithValues: rules.map { ($0.directoryName, $0) })
        var out: [JunkCandidate] = []

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
    ///
    /// projectName 用 `node.name`(产物的**直接父目录**),不用 DFS 顶层项目名
    /// (用户实报 2026-11-05:worktree 里的 node_modules 全标了主项目名,
    /// 同组冒出三个同名行)。monorepo 场景同理:packages/app1/node_modules
    /// 归 "app1" 不归 monorepo 顶层。年龄也按直接父目录算,口径一致。
    private static func appendArtifacts(
        ofDirectChildrenOf node: SpaceNode,
        rulesByName: [String: ProjectArtifactRule],
        excluded: [String],
        fileExists: (String) -> Bool,
        into out: inout [JunkCandidate]
    ) {
        for child in node.children where child.kind == .directory {
            guard let rule = rulesByName[child.name], !CleanExclusions.isExcluded(child.path, by: excluded),
                  child.accountedBytes > 0 || child.isPartial,
                  rule.markers.isEmpty || rule.markers
                      .contains(where: { fileExists($0.path(forArtifactAt: child.path)) })
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
                rationale: rule.rationale,
                symbolName: rule.symbolName,
                projectName: node.name,
                newestChangeEpoch: projectAge(of: node, rulesByName: rulesByName),
                modifiedAtScan: child.ownModifiedEpoch
            ))
        }
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
