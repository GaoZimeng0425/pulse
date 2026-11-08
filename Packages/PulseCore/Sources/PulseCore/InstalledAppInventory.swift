import Foundation

// MARK: - 已装 bundle id 全集(p5-cleaner/02):判孤儿的权威源

//
// spec §4/§6(grill 2026-11-08):已装权威 = **未过滤**全集(含 Apple 系统应用;
// AppCatalog 隐藏 Apple 签名 app,不参与判孤儿)。三路并集——多认一个「已装」=
// 少报一个孤儿,并集只会往保守走:
//   1. 扫描树里的全部 bundle 目录(.app/.appex/.xpc,含嵌套 helper;Data 卷全卷):
//      Downloads 里直接跑的 app、DerivedData 里正在开发的 app 都算「主人还在」
//      (spec「我方架构红利:全卷扫描树做已装权威」);
//   2. 标准安装目录 Live 补扫(maxdepth 3,Mole 同款根表机制,零搬码):
//      /System/Applications 不在 Data 卷扫描里;用户也可能把 /Applications 排除出扫描;
//      输入法(/Library/Input Methods)不住 /Applications,漏了会把输入法缓存判孤儿;
//   3. 运行中 app(NSWorkspace,防「在跑但 .app 挪走」)。
// fail-closed(Mole「不完整的清单无权判孤儿」):任一 Info.plist 存在却读不了 /
// 解析不了 = 全集不完整 → 整组不出;扫描被取消(半棵树)同理。plist 合法但无 id、
// 或 bundle 根本没有 plist(iOS 包装壳等)= 跳过不失败——没有 id 就不拥有
// id 命名的残留。

/// 一次 Info.plist 读取的三态(Live 读取器产出;两种布局的回退由本层做)。
public enum InfoPlistRead: Sendable, Equatable {
    /// 这个位置没有 Info.plist(换布局再试;两处都没有 = 无 id,跳过)。
    case missing
    /// 文件在,但读不了或不是合法的字典 plist → 采集失败(fail-closed)。
    case unreadable
    /// 合法 plist;`bundleID` = CFBundleIdentifier(缺 / 空 / 非字符串 = nil)。
    case parsed(bundleID: String?)
}

/// 已装全集的采集结果。只有 `.complete` 有资格判孤儿。
public enum InstalledAppInventory: Sendable, Equatable {
    /// 采集完整:未过滤全集(已并入运行中 app)。
    case complete(Set<String>)
    /// 某个 bundle 的 Info.plist 读不了(带路径——界面如实说是哪个,用户可自查)。
    case unreadablePlist(bundlePath: String)
    /// 扫描被取消:树是半棵,树内 bundle 发现不完整。
    case incompleteScan

    /// fail-closed 出口:完整才给集合,失败态一律 nil(调用方据此整组不出)。
    public var bundleIDs: Set<String>? {
        if case let .complete(ids) = self {
            return ids
        }
        return nil
    }

    /// 失败原因人话(界面「卸载残留未检测」的说明;完整态 nil)。
    public var unavailableReason: String? {
        switch self {
        case .complete:
            nil
        case let .unreadablePlist(path):
            "「\(path)」的 Info.plist 读不了——已装应用清单不完整时不判卸载残留,免得把还在的 app 当成已卸载"
        case .incompleteScan:
            "扫描被取消,已装应用清单不完整——完整扫描一次才判卸载残留"
        }
    }

    // MARK: 采集管线(纯值;IO 由调用方注入)

    /// bundle 目录扩展名(小写比较):app 本体 + 可独立成进程、自带 bundle id 的嵌套件。
    public static let bundleExtensions: Set<String> = ["app", "appex", "xpc"]

    /// 标准目录 Live 补扫深度(find -maxdepth 3 口径:覆盖 /Applications/Setapp/X.app、
    /// Caskroom/<cask>/<版本>/X.app、iOS 包装壳 X.app/Wrapper/X.app)。
    public static let standardSearchDepth = 3

    /// 标准安装目录(Live 补扫的根;不存在的根由调用方静默跳过)。
    public static func standardDirectories(home: String) -> [String] {
        let home = PathNormalization.normalize(home)
        return [
            "/Applications",
            "/System/Applications",
            home + "/Applications",
            home + "/Library/Application Support/Setapp/Applications",
            "/opt/homebrew/Caskroom",
            "/usr/local/Caskroom",
            "/Library/Input Methods",
            home + "/Library/Input Methods",
        ]
    }

    /// 目录名是不是 bundle(扩展名 ≤5 字符才小写比较,60 万节点逐个 lowercased 太贵)。
    public static func isBundleDirectoryName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 5 else { return false }
        return bundleExtensions.contains(ext.lowercased())
    }

    /// 扫描树内全部 bundle 目录的路径(DFS,进 bundle 内部找嵌套 helper)。
    public static func bundlePaths(in trees: [SpaceNode]) -> [String] {
        var out: [String] = []
        var stack = trees
        while let node = stack.popLast() {
            guard node.kind == .directory else { continue }
            if isBundleDirectoryName(node.name) {
                out.append(node.path)
            }
            stack.append(contentsOf: node.children)
        }
        return out
    }

    /// 逐 bundle 判读并汇总。
    /// - Parameters:
    ///   - bundlePaths: 树内 ∪ 标准目录的 bundle 路径(可重复,内部去重)。
    ///   - runningBundleIDs: 运行中 app 的 bundle id(并入全集)。
    ///   - scanCancelled: 扫描被取消 → 直接 `.incompleteScan`(不读盘)。
    ///   - read: 读一个 Info.plist 文件路径(生产 Live;测试注入)。布局回退:
    ///     `Contents/Info.plist`(macOS)→ 根 `Info.plist`(iOS / 包装壳内层)。
    public static func build(
        bundlePaths: [String],
        runningBundleIDs: [String],
        scanCancelled: Bool,
        read: (String) -> InfoPlistRead
    ) -> InstalledAppInventory {
        guard !scanCancelled else { return .incompleteScan }
        var ids = Set(runningBundleIDs.filter { !$0.isEmpty })
        // 排序 = 首个失败路径确定(测试与日志可复现)。
        for bundle in Set(bundlePaths).sorted() {
            var outcome = read(bundle + "/Contents/Info.plist")
            if outcome == .missing {
                outcome = read(bundle + "/Info.plist")
            }
            switch outcome {
            case .missing:
                continue // 两种布局都没有 plist:无 id,不拥有 id 命名的残留
            case .unreadable:
                return .unreadablePlist(bundlePath: bundle)
            case let .parsed(bundleID):
                if let bundleID, !bundleID.isEmpty {
                    ids.insert(bundleID)
                }
            }
        }
        return .complete(ids)
    }
}
