import Foundation

// MARK: - 卸载残留(p5-cleaner/01):全库对账 ~/Library 尸体的孤儿检测核心

//
// 与工具缓存(JunkRules)/项目产物(CleanProjectArtifacts)同一条安全边界线上的
// 第三个规则域。方向反转:那两个问「这目录在不在白名单」,这里问
// 「这个 bundle id 命名的目录,还有没有主人在」。
//
// 定案(grill 2026-11-08,spec .scratch/p5-cleaner/spec.md):
// - 5 域只吃反域名前缀命名;Containers / Group Containers / LaunchAgents /
//   Application Scripts / PrivilegedHelperTools 五条红线 v1 不碰(不存在即不扫)。
// - 六闸(顺序即廉价优先):排除前缀 → 敏感名单 → 已装全集(含运行中,调用方
//   并好)→ 系统前缀红线 → 反域名命名 → 30 天未动。
// - 档位两态:30 天未动 = 可安全清理;30 天内动过 = 先检查;非反域名命名不列。
// - fail-closed 是调用方责任(票 02:全集采集失败整组不出);本函数只对给进的
//   全集负责,树空 / 域不存在自然产空。
//
// 参考纪律:Mole(GPL)与 Pearcleaner(Apache+Commons)机制参考零搬码;本实现
// 用扫描树做已装权威(Pulse 独有),不做 Spotlight 兜底。

/// 孤儿扫描域表(spec §1;红线域不进表——不进表即不扫)。
public enum OrphanScanDomain: String, Sendable, CaseIterable {
    case caches
    case logs
    case savedApplicationState
    case webKit
    case httpStorages

    /// 相对家目录的路径。
    public var homeRelativePath: String {
        switch self {
        case .caches: "Library/Caches"
        case .logs: "Library/Logs"
        case .savedApplicationState: "Library/Saved Application State"
        case .webKit: "Library/WebKit"
        case .httpStorages: "Library/HTTPStorages"
        }
    }

    /// 目录名后缀剥离(Saved Application State 的 `com.foo.bar.savedState`
    /// → bundle id `com.foo.bar`),其余域无。
    var nameSuffixToStrip: String? {
        self == .savedApplicationState ? ".savedState" : nil
    }
}

/// 判孤儿永不越线的名单(spec §3/§5;红线,不是档位——连「先检查」都不给)。
public enum OrphanRedlines {
    /// 系统/苹果前缀:目录由系统管理,com.apple.* 的缓存永远不是孤儿。
    public static let systemPrefixes: [String] = ["com.apple."]

    /// 敏感数据名单(Mole 同款思路):密码管理器与密钥类目录名。
    /// 1Password 双写:新 id `com.1password.*` / 旧 id `com.agilebits.onepassword`
    /// (旧 id 不含数字「1」,首版名单漏过,测试揭出)。
    public static let sensitiveNameSubstrings: [String] = [
        "1password", "onepassword", "agilebits", "keychain", "bitwarden",
        "lastpass", "keepass", "dashlane", "enpass", "ssh", "gpg", "gnupg",
    ]

    /// 反域名前缀:目录名以这些开头才可能成为候选(非规范命名 v1 不列)。
    public static let reverseDNSPrefixes: [String] = ["com.", "org.", "net.", "io."]
}

/// 孤儿检测器:纯值、无 IO,跑在扫描树上。产出语义与另两个规则域同构
/// (每目录一个 `JunkCandidate`,`projectName` 携带大卡分组键 = **完整 bundle id**
/// (savedState 剥尾后);显示名由 `displayName(ofBundleID:)` 取尾段——分组用全 id,
/// 同尾段的不同 app(`com.figma.Desktop` / `com.foo.Desktop`)才不会并进一张卡,
/// p5-cleaner/02 修正票 01 的尾段分组)。
public enum OrphanLeftoverDetector {
    /// 时间闸阈值(秒)。
    public static let quietThresholdSeconds: TimeInterval = 30 * 86400

    /// - Parameters:
    ///   - trees: 扫描产出(`SpaceScanResult.trees`)。
    ///   - home: 家目录(定位 ~/Library 各域)。
    ///   - installedBundleIDs: 已装 app 的**未过滤** bundle id 全集(须已并入
    ///     运行中 app 的 id;采集失败时调用方不得进来——fail-closed 在那一层)。
    ///   - excludedPathPrefixes: 排除目录(右键排除,与另两域同款双保险)。
    ///   - now: 当前时间(30 天闸;测试注入)。
    /// - Returns: 每个孤儿目录一个候选,大到小;`newestChangeEpoch` = 子树内
    ///   任何文件的最新变动(孤儿自己的年龄,「按新旧」排序直接可用)。
    public static func detect(
        in trees: [SpaceNode],
        home: String,
        installedBundleIDs: Set<String>,
        excludedPathPrefixes: [String],
        now: TimeInterval
    ) -> [JunkCandidate] {
        let homePath = PathNormalization.normalize(home)
        var out: [JunkCandidate] = []

        for domain in OrphanScanDomain.allCases {
            let domainPath = homePath + "/" + domain.homeRelativePath
            guard let domainNode = SpaceNode.locate(path: domainPath, in: trees) else { continue }
            for child in domainNode.children where child.kind == .directory {
                // 闸 1:右键排除。
                guard !CleanExclusions.isExcluded(child.path, by: excludedPathPrefixes) else { continue }
                var bundleID = child.name
                if let suffix = domain.nameSuffixToStrip, bundleID.hasSuffix(suffix) {
                    bundleID = String(bundleID.dropLast(suffix.count))
                }
                // 噪音纪律(与产物域同款):零字节且非部分扫描不列——没有可回收量,
                // 列出来纯占屏。部分扫描的零字节如实列(数字未知,不敢说没有)。
                guard child.accountedBytes > 0 || child.isPartial else { continue }
                // 闸 2:敏感名单(小写包含)。
                let lowered = bundleID.lowercased()
                guard !OrphanRedlines.sensitiveNameSubstrings.contains(where: lowered.contains) else { continue }
                // 闸 3:已装全集(含运行中,由调用方并入)。
                guard !installedBundleIDs.contains(bundleID) else { continue }
                // 闸 4:系统前缀红线。
                guard !OrphanRedlines.systemPrefixes.contains(where: bundleID.hasPrefix) else { continue }
                // 闸 5:反域名命名。
                guard OrphanRedlines.reverseDNSPrefixes.contains(where: bundleID.hasPrefix) else { continue }
                // 闸 6:30 天未动 → 档位;子树任何文件的最新变动为准
                // (nil = 证明不了安静,保守落「先检查」)。
                let newest = subtreeNewestChangeEpoch(of: child)
                let isQuiet = newest.map { now - $0 >= quietThresholdSeconds } ?? false

                out.append(JunkCandidate(
                    ruleID: "app-orphan",
                    group: .uninstallLeftovers,
                    title: child.name,
                    path: child.path,
                    tier: isQuiet ? .safe : .checkFirst,
                    bytes: child.accountedBytes,
                    fileCount: child.fileCount,
                    isPartial: child.isPartial,
                    allReclaimableAccounting: child.allReclaimableAccounting,
                    rationale: isQuiet
                        ? "「\(bundleID)」已不在已装应用清单,这是它留下的数据;30 天内没有文件变动"
                        : "「\(bundleID)」已不在已装应用清单,但 30 天内还有文件变动——先确认没有别的程序在用再删",
                    symbolName: "app.dashed",
                    projectName: bundleID,
                    newestChangeEpoch: newest
                ))
            }
        }

        return out.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path
        }
    }

    /// 与另两个规则域的候选去重(p5-cleaner/02 真案:规则表 `Library/Caches/org.swift.swiftpm`
    /// 是 CLI 工具缓存,没有 .app,孤儿检测会再报一遍——同路径两张卡、勾一联动二、
    /// 确认清单重复)。路径相等或互为祖孙 = 重叠,孤儿让位:规则表的说明与档位是逐条
    /// 担保过的,比「不在已装清单」的推断更准。
    public static func excludingOverlaps(
        _ orphans: [JunkCandidate],
        claimedBy claimed: [JunkCandidate]
    ) -> [JunkCandidate] {
        guard !claimed.isEmpty else { return orphans }
        let claimedPaths = claimed.map(\.path)
        return orphans.filter { orphan in
            !claimedPaths.contains { other in
                other == orphan.path || orphan.path.hasPrefix(other + "/") || other.hasPrefix(orphan.path + "/")
            }
        }
    }

    /// 大卡显示名:bundle id 尾段(`com.tencent.qq` → `qq`);没有点或尾段为空
    /// 用完整 id(不编名字)。分组键是全 id(`projectName`),这里只管显示。
    public static func displayName(ofBundleID bundleID: String) -> String {
        guard let lastDot = bundleID.lastIndex(of: "."),
              lastDot < bundleID.index(before: bundleID.endIndex)
        else { return bundleID }
        return String(bundleID[bundleID.index(after: lastDot)...])
    }

    /// 子树内任何文件的最新变动:`SpaceNode.newestChangeEpoch` 只含**直属文件**
    /// (引擎侧口径),这里 DFS 逐层取最大——目录深处的最近写入也算「动过」。
    static func subtreeNewestChangeEpoch(of node: SpaceNode) -> Double? {
        var stack = [node]
        var newest: Double?
        while let current = stack.popLast() {
            if let epoch = current.newestChangeEpoch {
                newest = max(newest ?? epoch, epoch)
            }
            stack.append(contentsOf: current.children)
        }
        return newest
    }
}
