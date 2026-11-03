import Foundation

// MARK: - cask 收据(p4-uninstaller/01):离线解析,不跑 brew 命令

//
// 收据形状实机定谳(2026-11-03 探针,brew 7.0.12):
//   /opt/homebrew/Caskroom/<cask>/.metadata/INSTALL_RECEIPT.json(每 cask 恰一份)
//   uninstall_artifacts = [ {"app": ["Bitwarden.app"]},
//                           {"zap": [{"trash": ["~/Library/Application Support/…"]}]},
//                           {"uninstall": [{"quit": ["com.bitwarden.desktop"]}]} ]
// 形状杂(值是数组嵌字典),用 JSONSerialization 宽松提取;解析失败 = nil 穿透,
// 调用方按 GLOSSARY「cask 收据」口径处理:对不上宁可漏标不误标。
// zap 路径带 `~` 前缀,parse 时只做 ~ 展开(不 standardize——那会解析 symlink,超出收据声明的语义)。

/// 一个 cask 的收据投影:徽标键(app 名)+ 残留路径(zap trash,02 票残留候选的优先来源)。
public struct CaskReceipt: Sendable, Equatable {
    /// Caskroom 目录名(= cask token,如 "bitwarden")。
    public var caskName: String
    /// uninstall_artifacts 里 {"app": [...]} 声明的 app 名(如 "Bitwarden.app"),可能缺。
    public var artifactAppNames: [String]
    /// zap 段 trash 声明的路径(~ 已展开),可能缺。
    public var zapTrashPaths: [String]
    /// uninstall 段 quit 声明的 bundle id(03 票卸载前可顺带核对;v1 仅记档)。
    public var quitBundleIDs: [String]

    public init(
        caskName: String,
        artifactAppNames: [String] = [],
        zapTrashPaths: [String] = [],
        quitBundleIDs: [String] = []
    ) {
        self.caskName = caskName
        self.artifactAppNames = artifactAppNames
        self.zapTrashPaths = zapTrashPaths
        self.quitBundleIDs = quitBundleIDs
    }

    /// 解析一份收据 JSON。caskName 由调用方给(Caskroom 目录名,文件内容里没有可靠字段)。
    public static func parse(caskName: String, data: Data) -> CaskReceipt? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 收据顶层还混着 homebrew_version / source / arch 等;只有 uninstall_artifacts 是我们的域。
        guard let artifacts = root["uninstall_artifacts"] as? [[String: Any]] else {
            // 无 artifacts 段(老收据 / 手动塞的)= 空投影而非 nil:目录在 Caskroom 里,
            // cask 身份成立,只是没有可提取的 app / zap 声明。
            return CaskReceipt(caskName: caskName)
        }
        var appNames: [String] = []
        var zapPaths: [String] = []
        var quitIDs: [String] = []
        for artifact in artifacts {
            if let names = artifact["app"] as? [String] {
                appNames.append(contentsOf: names)
            }
            if let zapStanzas = artifact["zap"] as? [[String: Any]] {
                for stanza in zapStanzas {
                    if let paths = stanza["trash"] as? [String] {
                        zapPaths.append(contentsOf: paths.map(expandTilde))
                    }
                }
            }
            if let uninstallStanzas = artifact["uninstall"] as? [[String: Any]] {
                for stanza in uninstallStanzas {
                    if let ids = stanza["quit"] as? [String] {
                        quitIDs.append(contentsOf: ids)
                    }
                }
            }
        }
        return CaskReceipt(
            caskName: caskName,
            artifactAppNames: appNames,
            zapTrashPaths: zapPaths,
            quitBundleIDs: quitIDs
        )
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// 收据 → 「app 名 → cask 名」索引(徽标判定)。
public enum CaskReceiptIndex {
    /// 同一 app 名被多个 cask 声明 = 对不上(歧义),整名丢弃——漏标不误标(GLOSSARY)。
    public static func build(_ receipts: [CaskReceipt]) -> [String: String] {
        var index: [String: String] = [:]
        var conflicted: Set<String> = []
        for receipt in receipts {
            for appName in receipt.artifactAppNames {
                if let existing = index[appName], existing != receipt.caskName {
                    conflicted.insert(appName)
                } else {
                    index[appName] = receipt.caskName
                }
            }
        }
        for name in conflicted {
            index[name] = nil
        }
        return index
    }
}
