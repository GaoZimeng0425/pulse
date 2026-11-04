import Foundation

// MARK: - 残留候选引擎(p4-uninstaller/02):两把键精确匹配,纯值生成探测清单

//
// 职责分工:本文件纯值——把 bundle id / 应用名两把键展开成**待探测路径清单**
// (不查盘);Live 侧逐条 stat 存在性 + 聚合大小,不存在的丢弃。「目录名全等才
// 命中」由构造保证:路径里的键段就是键本身,无前缀 / 子串 / 模糊匹配。
//
// 键的适用面(spec「键 = bundle id 与应用名」+ 各位置括号特例):
//   两把键:Application Support / Caches / WebKit / Logs / LaunchAgents——
//     这些位置真实世界里两种命名都常见(如 ~/Library/Application Support/Bitwarden)。
//   仅 bundle id:Preferences(<bid>.plist)/ Containers / Saved Application State
//     (<bid>.savedState)/ HTTPStorages(<bid> 目录 + <bid>.binarycookies 文件)/
//     Application Scripts——这些位置按平台定义就是 bid 域名形状,应用名目录
//     不构成合法条目,探测它纯属噪声(不误中的前提是不去碰不可能的形状)。
//   Group Containers:目录名 = <团队id>.<bid>,团队 id 构造时未知 → 后缀谓词
//     (matchesGroupContainer),Live 枚举该目录后匹配;前缀必须是团队 id 形状
//     (10 位大写字母数字),防普通目录名恰好以 .<bid> 结尾误中。
// LaunchAgents 恒「先检查」档(spec);PrivilegedHelperTools 永不生成(root 域,
// ADR-0009——不在清单里出现,连探测都不做)。
// brew 收据 zap 路径(spec「优先取收据,未覆盖处落回通用位置」):并集去重,
// 同路径 zap 胜;**只收家域(~ 开头)**——/Library 层残留 v1 不碰(root 域纪律,
// 宁可漏列,记档票面)。
// 无 bundle id 的 app:残留清单如实为空(02 票拍板口径)——只剩应用名一把键,
// 在 ~/Library 里按名字撞目录误中风险高于收益,不硬猜。

/// 残留位置(展示分组与说明的原料)。
public enum LeftoverSite: String, Sendable, Equatable, CaseIterable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case preferences = "Preferences"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case savedAppState = "Saved Application State"
    case httpStorages = "HTTPStorages"
    case webKit = "WebKit"
    case logs = "Logs"
    case applicationScripts = "Application Scripts"
    case launchAgents = "LaunchAgents"

    /// 人话副标(Q4 拍板):残留行先说「这是什么」,再说「删了会怎样」。
    /// 文案不含实现术语(路径段 / 目录名)——登记完整性测试断言。
    public var plainTitle: String {
        switch self {
        case .applicationSupport: "应用数据"
        case .caches: "缓存"
        case .preferences: "设置"
        case .containers: "容器沙盒数据"
        case .groupContainers: "应用组共享数据"
        case .savedAppState: "窗口状态"
        case .httpStorages: "网络存储"
        case .webKit: "内嵌浏览器数据"
        case .logs: "日志"
        case .applicationScripts: "脚本数据"
        case .launchAgents: "后台代理"
        }
    }

    /// 「删了会怎样」一句话(客观后果,不吓唬也不淡化)。
    public var consequenceNote: String {
        switch self {
        case .applicationSupport: "删了应用回到首次启动状态(登录、本地数据要重来)"
        case .caches: "删了下次启动自动重建"
        case .preferences: "删了回到出厂设置"
        case .containers: "删了下次启动自动重建沙盒"
        case .groupContainers: "删了共享它的应用都回到首次启动状态"
        case .savedAppState: "删了应用忘记窗口位置与未保存的界面状态"
        case .httpStorages: "删了网站的本地登录态要重来"
        case .webKit: "删了内嵌网页的登录态与浏览数据要重来"
        case .logs: "删了历史诊断记录不可回查"
        case .applicationScripts: "删了下次启动自动重建"
        case .launchAgents: "删了它不再随登录启动——先确认你认识它"
        }
    }
}

/// 候选来源:通用位置规则 / cask 收据 zap 段(界面 tooltip 供查证)。
public enum LeftoverSource: String, Sendable, Equatable {
    case generic
    case caskZap
}

/// 一条待探测的候选(固定路径)或 Group Containers 后缀谓词。
public enum LeftoverProbe: Sendable, Equatable {
    case path(
        String,
        site: LeftoverSite,
        key: String,
        isFile: Bool,
        checkFirst: Bool,
        source: LeftoverSource
    )
    /// Group Containers:枚举该目录后按 `matchesGroupContainer` 匹配。
    case groupContainers(bundleID: String)

    public var fixedPath: String? {
        if case let .path(path, _, _, _, _, _) = self {
            return path
        }
        return nil
    }
}

/// 探测后落单的残留行(Live 填存在性与大小;不存在的候选不产行)。
public struct AppLeftoverRow: Sendable, Equatable, Identifiable {
    public var id: String {
        path
    }

    public var path: String
    public var site: LeftoverSite
    /// 命中的键(bundle id 或应用名;GC = "<团队id>.<bundleID>")。
    public var matchKey: String
    public var source: LeftoverSource
    /// LaunchAgents 恒 true(spec)。
    public var isCheckFirst: Bool
    public var sizeBytes: Int64?
    public var isPartial: Bool

    public init(
        path: String,
        site: LeftoverSite,
        matchKey: String,
        source: LeftoverSource,
        isCheckFirst: Bool = false,
        sizeBytes: Int64? = nil,
        isPartial: Bool = false
    ) {
        self.path = path
        self.site = site
        self.matchKey = matchKey
        self.source = source
        self.isCheckFirst = isCheckFirst
        self.sizeBytes = sizeBytes
        self.isPartial = isPartial
    }
}

public enum AppLeftovers {
    /// 展开两把键 → 待探测清单。`brewZapPaths` 只在 app 带 brew 徽标时由调用方传入。
    /// 无 bundle id → 空清单(见文件头口径)。
    public static func probes(bundleID: String?, appName: String?, brewZapPaths: [String] = []) -> [LeftoverProbe] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let name = (appName ?? "").isEmpty ? nil : appName
        let library = NSHomeDirectory() + "/Library"

        var result: [LeftoverProbe] = []
        // 两把键的平名位置
        for key in keys(bundleID: bundleID, appName: name) {
            result.append(.path(
                library + "/Application Support/\(key)",
                site: .applicationSupport,
                key: key,
                isFile: false,
                checkFirst: false,
                source: .generic
            ))
            result.append(.path(
                library + "/Caches/\(key)",
                site: .caches,
                key: key,
                isFile: false,
                checkFirst: false,
                source: .generic
            ))
            result.append(.path(
                library + "/WebKit/\(key)",
                site: .webKit,
                key: key,
                isFile: false,
                checkFirst: false,
                source: .generic
            ))
            result.append(.path(
                library + "/Logs/\(key)",
                site: .logs,
                key: key,
                isFile: false,
                checkFirst: false,
                source: .generic
            ))
            // LaunchAgents 恒「先检查」;应用名的 .plist 同样合法(老 app 常见)。
            result.append(.path(
                library + "/LaunchAgents/\(key).plist",
                site: .launchAgents,
                key: key,
                isFile: true,
                checkFirst: true,
                source: .generic
            ))
        }
        // 仅 bundle id 的平台域形状
        result.append(.path(
            library + "/Preferences/\(bundleID).plist",
            site: .preferences,
            key: bundleID,
            isFile: true,
            checkFirst: false,
            source: .generic
        ))
        result.append(.path(
            library + "/Containers/\(bundleID)",
            site: .containers,
            key: bundleID,
            isFile: false,
            checkFirst: false,
            source: .generic
        ))
        result.append(.path(
            library + "/Saved Application State/\(bundleID).savedState",
            site: .savedAppState,
            key: bundleID,
            isFile: false,
            checkFirst: false,
            source: .generic
        ))
        result.append(.path(
            library + "/HTTPStorages/\(bundleID)",
            site: .httpStorages,
            key: bundleID,
            isFile: false,
            checkFirst: false,
            source: .generic
        ))
        result.append(.path(
            library + "/HTTPStorages/\(bundleID).binarycookies",
            site: .httpStorages,
            key: bundleID,
            isFile: true,
            checkFirst: false,
            source: .generic
        ))
        result.append(.path(
            library + "/Application Scripts/\(bundleID)",
            site: .applicationScripts,
            key: bundleID,
            isFile: false,
            checkFirst: false,
            source: .generic
        ))
        result.append(.groupContainers(bundleID: bundleID))

        // 收据 zap 段:只收家域(/Library 层 v1 不碰,root 域纪律);与通用清单
        // 并集去重——**同路径以收据声明为准**(通用行改标 caskZap,不重复成行),
        // 通用覆盖不到的 zap 路径独立成行。
        let homePrefix = NSHomeDirectory() + "/"
        var zapAll = Set<String>()
        var zapExtra: [String] = []
        var seen = Set(result.compactMap(\.fixedPath))
        for raw in brewZapPaths {
            let path = CaskReceipt.expandTilde(raw)
            guard path.hasPrefix(homePrefix), zapAll.insert(path).inserted else { continue }
            if seen.insert(path).inserted {
                zapExtra.append(path)
            }
        }
        if !zapAll.isEmpty {
            result = result.map { probe in
                guard case let .path(path, site, key, isFile, checkFirst, _) = probe,
                      zapAll.contains(path)
                else { return probe }
                return .path(path, site: site, key: key, isFile: isFile, checkFirst: checkFirst, source: .caskZap)
            }
            for path in zapExtra {
                result.append(.path(
                    path,
                    site: .caskZapSite(for: path),
                    key: bundleID,
                    isFile: false,
                    checkFirst: false,
                    source: .caskZap
                ))
            }
        }
        return result
    }

    /// Group Containers 目录名谓词:`<团队id>.<bid>` 全等(团队 id = 10 位大写
    /// 字母数字,Apple Developer 分配形状;前缀不是这个形状 = 普通目录碰巧同尾,
    /// 不误中)。`com.bitwarden.desktop`(无前缀)与
    /// `TEAMID1234.com.bitwarden.desktop.helper`(尾不对)都不命中。
    public static func matchesGroupContainer(directoryName: String, bundleID: String) -> Bool {
        guard directoryName.count > 11 else { return false } // 前缀 10 + "." 至少还要 1 字符
        let suffix = "." + bundleID
        guard directoryName.hasSuffix(suffix) else { return false }
        let teamID = String(directoryName.dropLast(suffix.count))
        // 数字无大小写(isUppercase=false),字母才判大写——否则带数字的团队 id 被误拒。
        return teamID.count == 10 && teamID.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) }
    }

    static func keys(bundleID: String, appName: String?) -> [String] {
        var keys = [bundleID]
        if let appName, appName != bundleID, !keys.contains(appName) {
            keys.append(appName)
        }
        return keys
    }

    /// 残留行展示序:大小降序(读不到大小的排最后),同大小按路径稳定序。
    /// 不确定性来源只剩内容本身,排序本身可测(输入乱序输出确定)。
    public static func sortedRows(_ rows: [AppLeftoverRow]) -> [AppLeftoverRow] {
        rows.sorted { lhs, rhs in
            switch (lhs.sizeBytes, rhs.sizeBytes) {
            case let (l?, r?): l != r ? l > r : lhs.path < rhs.path
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.path < rhs.path
            }
        }
    }
}

private extension LeftoverSite {
    /// zap 声明的任意路径没有天然位置名;按路径落一个近似位置(展示分组用,
    /// 无匹配时给 caskZap 让界面知道这是收据声明的)。
    static func caskZapSite(for path: String) -> LeftoverSite {
        let library = NSHomeDirectory() + "/Library/"
        guard path.hasPrefix(library) else { return .applicationSupport }
        let rest = String(path.dropFirst(library.count))
        let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
        return LeftoverSite(rawValue: first) ?? .applicationSupport
    }
}
