import Foundation
import PulseCore
import Security

// MARK: - Live 应用清单事实源(p4-uninstaller/01)

//
// 三件事实收集(全部离线、零 brew 命令):候选 .app 枚举 + 签名 / Info.plist / 可删判定;
// Caskroom 收据读取。判定依据全部出自 2026-11-03 探针:
//   签名:SecStaticCode + requirement "anchor apple" 验证(Safari/Calculator = true;
//   Bitwarden/DockDoor = -67050;**team=nil 不是判据**——CleanMyMac 的老 DigiCert
//   签名同样无 team id,实测反例)。验证器自身报错(包损坏 / 读不了)= unverifiable,
//   与「验证了且非 Apple」严格分开,Core 按「永不进清单 + 台账」处理。
//   收据:/opt/homebrew 与 /usr/local 双候选,每 cask 恰一份
//   <cask>/.metadata/INSTALL_RECEIPT.json(brew 7.0.12 实测;旧版 brew 的
//   .metadata/<version>/<hash>/ 层级已不存在,缺收据 = 漏标不误标)。
// 大小聚合不在此文件:复用 SpaceScanEngine(roots = app 路径集),口径与空间地图一致。

struct LiveAppCatalogFacts: Sendable {
    var candidates: [AppCatalogCandidate]
    /// "Bitwarden.app" → cask 名(目录名全等;冲突名已在 Core 侧丢弃)。
    var brewAppNames: [String: String]
}

struct LiveAppCatalogSource {
    /// 清单根(spec):/Applications(Utilities 单列)+ ~/Applications。顺序即清单顺序候选源。
    static let applicationRoots = [
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// 全量收集。同步重活(数百次 SecStaticCode / Info.plist 读)由调用方放后台 Task。
    /// 无存储属性(struct 纯函数集合,Sendable 由编译器自动合成;FileManager 不做
    /// 存储正是为此——它非 Sendable,存了整 struct 就过不了跨 actor 检查)。
    func collectFacts() -> LiveAppCatalogFacts {
        let fileManager = FileManager.default
        var candidates: [AppCatalogCandidate] = []
        var seenPaths = Set<String>()
        for root in Self.applicationRoots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else {
                continue // 根不存在(~/Applications 常缺)不是错误
            }
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                guard seenPaths.insert(path).inserted else { continue }
                candidates.append(candidate(at: path, directoryName: entry))
            }
        }
        return LiveAppCatalogFacts(
            candidates: candidates,
            brewAppNames: CaskReceiptIndex.build(collectReceipts())
        )
    }

    /// .app 实际占用聚合:复用空间扫描引擎(口径 = GLOSSARY「实际占用」,克隆 / 硬链接
    /// 去重、目录粒度即可)。app 清单不吃用户排除——那是目录垃圾扫描的语义(收窄的是
    /// 缓存目录候选),不适用于「这台机器装了什么」的事实枚举。
    func scanAppSizes(
        appPaths: [String],
        progress: (@Sendable (ScanStats) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> [String: (bytes: Int64, partial: Bool)] {
        guard !appPaths.isEmpty else { return [:] }
        let options = SpaceScanOptions(
            roots: appPaths,
            excludedPathPrefixes: [],
            maxDepth: 64,
            retainFileNodes: false,
            maxConcurrency: 6
        )
        let result = await SpaceScanEngine().scan(
            options,
            using: LiveCleanDirectoryEnumerator(),
            progress: progress,
            isCancelled: isCancelled
        )
        var sizes: [String: (bytes: Int64, partial: Bool)] = [:]
        for tree in result.trees {
            sizes[tree.path] = (tree.accountedBytes, tree.isPartial)
        }
        return sizes
    }

    // MARK: - 单个候选

    private func candidate(at path: String, directoryName: String) -> AppCatalogCandidate {
        let url = URL(fileURLWithPath: path)
        let signature = appleSignatureState(of: url)
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        let bundleID = (plist?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plistName = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleName"] as? String)
        return AppCatalogCandidate(
            path: path,
            directoryName: directoryName,
            bundleID: bundleID,
            displayName: plistName.flatMap { $0.isEmpty ? nil : $0 },
            isAppleSigned: signature.isApple,
            signatureUnverifiable: signature.unverifiable,
            isDeletable: isDeletable(atPath: path)
        )
    }

    /// 删 .app 要写父目录:access(parent, W_OK)。/Applications 对 admin 组成员可写
    /// (组写位 + ACL),普通账户则如实灰行「无权限」。
    private func isDeletable(atPath appPath: String) -> Bool {
        let parent = (appPath as NSString).deletingLastPathComponent
        return access(parent, W_OK) == 0
    }

    private func appleSignatureState(of url: URL) -> (isApple: Bool, unverifiable: Bool) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return (false, true)
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return (false, true) // requirement 造不出(理论不可达)→ 保守按验证不了
        }
        let status = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        )
        if status == errSecSuccess {
            return (true, false)
        }
        if status == errSecCSReqFailed {
            return (false, false) // 验证完成,不满足 apple 锚 = 非 Apple 签名
        }
        return (false, true) // 包损坏 / 读不了等 = 验证器自身失败
    }

    // MARK: - 收据

    private func collectReceipts() -> [CaskReceipt] {
        let fileManager = FileManager.default
        var receipts: [CaskReceipt] = []
        for caskroom in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            guard let caskDirectories = try? fileManager.contentsOfDirectory(atPath: caskroom) else {
                continue // 无 brew / 无 cask:清单照常,只是无徽标
            }
            for caskName in caskDirectories.sorted() {
                let receiptPath = caskroom + "/" + caskName + "/.metadata/INSTALL_RECEIPT.json"
                guard let data = fileManager.contents(atPath: receiptPath),
                      let receipt = CaskReceipt.parse(caskName: caskName, data: data)
                else {
                    continue // 读不了 / 解析不了 = 漏标不误标(GLOSSARY「cask 收据」)
                }
                receipts.append(receipt)
            }
        }
        return receipts
    }
}
