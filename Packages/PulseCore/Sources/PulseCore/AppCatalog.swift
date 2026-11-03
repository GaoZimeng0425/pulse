import Foundation

// MARK: - 应用清单域(p4-uninstaller/01):清单纯值内核,Live 收集事实后喂进来

//
// 职责分工(传感器家族同款):本文件纯值——Apple 签名过滤、灰行态、brew 徽标、
// 运行中前缀判定、排序;Live 侧(app target)负责枚举 .app、调 Security.framework
// 判签名、读 Info.plist、access(W_OK) 判可删、扫 Caskroom 收据。
// 排除口径(spec):Apple 签名的系统应用永不进清单;签名判不了的也不进(「永不进
// 清单」是硬要求,判定不可靠时宁可少列)——两者进台账计数,界面如实披露。

/// Live 收集到的一个候选 app 的原始事实(全部可合成夹具)。
public struct AppCatalogCandidate: Sendable, Equatable {
    /// .app 目录全路径,如 "/Applications/Bitwarden.app"。
    public var path: String
    /// .app 目录名,如 "Bitwarden.app"(brew 收据 app 键与此全等比对)。
    public var directoryName: String
    /// Info.plist CFBundleIdentifier;读不到 = nil(残留引擎 02 票按「无 bundle id」处理)。
    public var bundleID: String?
    /// Info.plist CFBundleDisplayName / CFBundleName;nil = 用目录名去 .app 后缀。
    public var displayName: String?
    /// Security.framework `anchor apple` 验证通过(2026-11-03 探针:team=nil 不是判据,
    /// CleanMyMac 的老 DigiCert 签名同样无 team id,必须走 requirement 验证)。
    public var isAppleSigned: Bool
    /// 签名验证本身失败(包损坏 / 读不了)——与「验证了且非 Apple」是两回事,单列台账。
    public var signatureUnverifiable: Bool
    /// 父目录 access(W_OK)——删 .app 要写父目录;/Applications 对 admin 组成员可写。
    public var isDeletable: Bool

    public init(
        path: String,
        directoryName: String,
        bundleID: String? = nil,
        displayName: String? = nil,
        isAppleSigned: Bool = false,
        signatureUnverifiable: Bool = false,
        isDeletable: Bool = true
    ) {
        self.path = path
        self.directoryName = directoryName
        self.bundleID = bundleID
        self.displayName = displayName
        self.isAppleSigned = isAppleSigned
        self.signatureUnverifiable = signatureUnverifiable
        self.isDeletable = isDeletable
    }
}

/// 灰行态(spec 固定两种;不提供退出 / 终止按钮,灰行只是陈述)。
public enum UninstallRowState: Sendable, Equatable {
    case normal
    /// 正在运行——「先退出」。
    case running
    /// 父目录不可写——「无权限」。与 running 并存时以 noPermission 示人:
    /// 无权限是更根本的拒绝(退出了也删不了),对用户更诚实。
    case noPermission
}

/// 清单里的一行(纯值;大小由 Live 的空间扫描聚合后注入,口径 = GLOSSARY「实际占用」)。
public struct UninstallAppEntry: Sendable, Equatable, Identifiable {
    public var id: String {
        path
    }

    public var name: String
    public var path: String
    public var bundleID: String?
    /// nil = 大小未知(Live 尚未聚合到;不伪造 0)。
    public var sizeBytes: Int64?
    /// 大小聚合时子树有目录没扫到(部分扫描,如实上屏)。
    public var isPartial: Bool
    /// brew 徽标(nil = 非 brew 或收据对不上;漏标不误标)。
    public var brewCaskName: String?
    public var rowState: UninstallRowState

    public init(
        name: String,
        path: String,
        bundleID: String? = nil,
        sizeBytes: Int64? = nil,
        isPartial: Bool = false,
        brewCaskName: String? = nil,
        rowState: UninstallRowState = .normal
    ) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.sizeBytes = sizeBytes
        self.isPartial = isPartial
        self.brewCaskName = brewCaskName
        self.rowState = rowState
    }
}

/// 排除台账(界面披露口径:如实上屏,不静默消失)。
public struct AppCatalogLedger: Sendable, Equatable {
    public var excludedAppleSigned = 0
    public var excludedUnverifiableSignature = 0

    public init() {}
}

public struct AppCatalogOutput: Sendable, Equatable {
    /// 按名排序(localizedCaseInsensitive;spec「按名排序」)。
    public var entries: [UninstallAppEntry]
    public var ledger: AppCatalogLedger

    public init(entries: [UninstallAppEntry], ledger: AppCatalogLedger) {
        self.entries = entries
        self.ledger = ledger
    }
}

public enum AppCatalog {
    /// - Parameters:
    ///   - appSizes: path → (实际占用, 是否部分扫描),由 Live 的 SpaceScanEngine 聚合。
    ///   - brewAppNames: "Bitwarden.app" → cask 名(CaskReceiptIndex 产出,目录名全等)。
    ///   - runningExecutablePaths: 进程快照的可执行路径全集(判定不缓存:每次清单
    ///     重建时 Live 重新取快照,删除前 03 票还要再重查一次)。
    public static func build(
        candidates: [AppCatalogCandidate],
        appSizes: [String: (bytes: Int64, partial: Bool)] = [:],
        brewAppNames: [String: String] = [:],
        runningExecutablePaths: [String] = []
    ) -> AppCatalogOutput {
        var ledger = AppCatalogLedger()
        var entries: [UninstallAppEntry] = []
        for candidate in candidates {
            if candidate.isAppleSigned {
                ledger.excludedAppleSigned += 1
                continue
            }
            if candidate.signatureUnverifiable {
                ledger.excludedUnverifiableSignature += 1
                continue
            }
            let size = appSizes[candidate.path]
            entries.append(
                UninstallAppEntry(
                    name: displayName(of: candidate),
                    path: candidate.path,
                    bundleID: candidate.bundleID,
                    sizeBytes: size?.bytes,
                    isPartial: size?.partial ?? false,
                    brewCaskName: brewAppNames[candidate.directoryName],
                    rowState: rowState(
                        of: candidate,
                        appPath: candidate.path,
                        runningExecutablePaths: runningExecutablePaths
                    )
                )
            )
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return AppCatalogOutput(entries: entries, ledger: ledger)
    }

    /// 显示名:Info.plist 名优先,fallback 目录名去 ".app"(空名回退目录名原样)。
    static func displayName(of candidate: AppCatalogCandidate) -> String {
        if let plistName = candidate.displayName, !plistName.isEmpty {
            return plistName
        }
        if candidate.directoryName.hasSuffix(".app") {
            let stem = String(candidate.directoryName.dropLast(4))
            if !stem.isEmpty {
                return stem
            }
        }
        return candidate.directoryName
    }

    static func rowState(
        of candidate: AppCatalogCandidate,
        appPath: String,
        runningExecutablePaths: [String]
    ) -> UninstallRowState {
        if !candidate.isDeletable {
            return .noPermission
        }
        return isRunning(appPath: appPath, executablePaths: runningExecutablePaths) ? .running : .normal
    }

    /// 运行判定 = 可执行路径落在 .app 之内(路径**组件**前缀,不是裸字符串前缀:
    /// "/Applications/Foo.app Helper.app" 会被 "/Applications/Foo.app" 的裸 hasPrefix
    /// 误中,必须比到目录分隔符)。
    public static func isRunning(appPath: String, executablePaths: [String]) -> Bool {
        executablePaths.contains { executable in
            executable == appPath || executable.hasPrefix(appPath + "/")
        }
    }
}
