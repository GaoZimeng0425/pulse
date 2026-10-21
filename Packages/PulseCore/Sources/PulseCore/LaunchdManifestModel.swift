import Foundation

// MARK: - launchd 服务清单(GLOSSARY;launchd-attribution/01,ADR-0005)

/// launchd plist 目录的一次读取结果(薄源协议的载荷)。三者在健康判定里角色不同:
/// 缺席正常(~/Library/LaunchAgents 常见不存在)、不可读 = 该目录声明的服务会静默
/// 丢失(降级)、有内容 = 正常。
public enum LaunchdPlistDirectoryRead: Sendable {
    /// 目录不存在。
    case absent
    /// 目录存在但枚举失败(权限等)。
    case unreadable
    /// 目录下每个 `.plist` 文件的原始字节(可为空数组)。
    case plists([Data])
}

/// launchd plist 目录薄源协议(ADR-0004 编译期测试接缝):按目录路径返回其中每个
/// `.plist` 的原始字节。运行期只有 FileManager 一个真实现(app 侧 LiveLaunchdPlistSource);
/// 解析、并集、两层缓存、健康判定全在缝上(本文件),`swift test` 不起宿主即可覆盖。
public protocol LaunchdPlistSource: Sendable {
    func read(directory: String) -> LaunchdPlistDirectoryRead
}

/// launchd 服务清单的纯逻辑:目录常量与单 plist 解析。
public enum LaunchdServiceManifest {
    /// 密封层目录:/System 在密封系统卷上,不重启装系统更新就不可能变——进程生命周期内
    /// 只扫一次(本机 911 个 plist,冷扫约 340ms;ADR-0005)。
    public static let sealedDirectories: [String] = [
        "/System/Library/LaunchDaemons",
        "/System/Library/LaunchAgents",
    ]

    /// 可变层目录:随软件安装(/Library)、Apple 非密封组件的安全更新(/Library/Apple,
    /// XProtect / MRT / Rosetta)、用户代理(~/Library)变化,按节奏重扫。
    public static func mutableDirectories(homeDirectory: String) -> [String] {
        [
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            "/Library/Apple/System/Library/LaunchDaemons",
            "/Library/Apple/System/Library/LaunchAgents",
            homeDirectory + "/Library/LaunchAgents",
        ]
    }

    /// 单个 plist → 服务程序路径:`Program` 优先,否则 `ProgramArguments[0]`——launchd 自身
    /// 语义:两者同在时执行的是 Program,ProgramArguments 只是 argv。都没有 / 非字典 /
    /// 畸形字节 → nil(跳过该文件,不影响其余)。
    public static func executablePath(fromPlist data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        if let program = dictionary["Program"] as? String, !program.isEmpty {
            return program
        }
        if let arguments = dictionary["ProgramArguments"] as? [String],
           let first = arguments.first, !first.isEmpty {
            return first
        }
        return nil
    }
}

// MARK: - 健康态

/// 清单读取的健康三态(launchd-attribution/01):正常(每个目录要么有内容要么缺席)、
/// 降级(至少一个目录存在却不可读——它声明的服务会静默丢失)、失败(本轮尝试的目录
/// 没有一个可读,清单不可信,交付方退回上次好清单)。两种异常态都携带不可读目录,
/// 目录集合变化即视为换了一种异常(状态沿日志再记一条)。
public enum LaunchdManifestHealth: Equatable, Sendable {
    case healthy
    case degraded(unreadable: [String])
    case failed(unreadable: [String])
}

// MARK: - 组装器(两层缓存状态机)

/// 清单组装器(ADR-0005):密封层目录读出内容即冻结、此后不再读,读不到的下次继续补;
/// 可变层每次重读;结果 = 两层并集。每条程序路径同时收入字面值与其 realpath(不同才收)
/// ——引擎拿到的进程路径是 vnode 真路径(Cryptexes 代理实测与 plist 字面只经 realpath
/// 相等),realpath 经注入闭包完成,IO 留在 app 侧,与 `GroupingConfiguration.bundleDisplayName`
/// 把读取注入 Core 同款。值类型,由 provider 持有、每 tick 推进一次。
public struct LaunchdManifestAssembler: Sendable {
    /// 一次组装的产出。
    public struct Outcome: Equatable, Sendable {
        /// 本轮清单(字面 ∪ realpath);健康为失败时 nil(本轮不可信)。
        public let paths: Set<String>?
        public let health: LaunchdManifestHealth

        public init(paths: Set<String>?, health: LaunchdManifestHealth) {
            self.paths = paths
            self.health = health
        }
    }

    public let sealedDirectories: [String]
    public let mutableDirectories: [String]
    private let resolveSymlinks: @Sendable (String) -> String
    /// 已冻结的密封层目录(只增)与它们贡献的路径。
    private var frozenSealedDirectories: Set<String> = []
    private var sealedPaths: Set<String> = []

    public init(
        sealedDirectories: [String] = LaunchdServiceManifest.sealedDirectories,
        mutableDirectories: [String],
        resolveSymlinks: @escaping @Sendable (String) -> String
    ) {
        self.sealedDirectories = sealedDirectories
        self.mutableDirectories = mutableDirectories
        self.resolveSymlinks = resolveSymlinks
    }

    /// 密封层是否已全部冻结(每个密封目录都读出过内容)。
    public var isSealedTierFrozen: Bool {
        Set(sealedDirectories).isSubset(of: frozenSealedDirectories)
    }

    /// 推进一轮:读尚未冻结的密封目录 + 全部可变目录,折算健康态并产出清单。
    public mutating func assemble(using source: any LaunchdPlistSource) -> Outcome {
        var unreadable: [String] = []
        var attempted = 0

        for directory in sealedDirectories where !frozenSealedDirectories.contains(directory) {
            attempted += 1
            switch source.read(directory: directory) {
            case let .plists(plists):
                sealedPaths.formUnion(executablePaths(from: plists))
                frozenSealedDirectories.insert(directory)
            case .absent, .unreadable:
                // 密封目录缺席同样异常(/System 不可能没有它们):按不可读计,下次重试。
                unreadable.append(directory)
            }
        }

        var mutablePaths: Set<String> = []
        for directory in mutableDirectories {
            attempted += 1
            switch source.read(directory: directory) {
            case let .plists(plists):
                mutablePaths.formUnion(executablePaths(from: plists))
            case .absent:
                break
            case .unreadable:
                unreadable.append(directory)
            }
        }

        if unreadable.isEmpty {
            return Outcome(paths: sealedPaths.union(mutablePaths), health: .healthy)
        }
        if unreadable.count == attempted {
            return Outcome(paths: nil, health: .failed(unreadable: unreadable))
        }
        return Outcome(paths: sealedPaths.union(mutablePaths), health: .degraded(unreadable: unreadable))
    }

    private func executablePaths(from plists: [Data]) -> Set<String> {
        var result: Set<String> = []
        for data in plists {
            guard let literal = LaunchdServiceManifest.executablePath(fromPlist: data) else { continue }
            result.insert(literal)
            let resolved = resolveSymlinks(literal)
            if resolved != literal {
                result.insert(resolved)
            }
        }
        return result
    }
}

// MARK: - 状态沿日志

/// 清单健康的状态沿日志(transition-not-tick,沿 NettopHealthLog 惯例):三态切换才记一条
/// ——进入降级记 warn、换一组不可读目录再记、进入失败记 error、恢复正常记 info;同态静默。
/// 纯值状态机,单测钉死。
public struct LaunchdManifestHealthLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Level: Equatable, Sendable {
            case info
            case warn
            case error
        }

        public let level: Level
        public let message: String

        public init(level: Level, message: String) {
            self.level = level
            self.message = message
        }
    }

    private var last: LaunchdManifestHealth = .healthy

    /// 登记一轮健康态;返回应记的日志(nil = 同态静默)。
    public mutating func transition(to health: LaunchdManifestHealth) -> Entry? {
        guard health != last else { return nil }
        let previous = last
        last = health
        switch health {
        case .healthy:
            return Entry(
                level: .info,
                message: "launchd 服务清单恢复正常(上一态:\(Self.describe(previous)))"
            )
        case let .degraded(unreadable):
            return Entry(
                level: .warn,
                message: "launchd 服务清单降级:目录不可读 \(Self.list(unreadable))"
                    + "——其中声明的服务将落孤儿进程(此后同态静默,恢复再记)"
            )
        case let .failed(unreadable):
            return Entry(
                level: .error,
                message: "launchd 服务清单读取失败:尝试的目录全部不可读 \(Self.list(unreadable))"
                    + "——沿用上次好清单(此后同态静默,恢复再记)"
            )
        }
    }

    private static func describe(_ health: LaunchdManifestHealth) -> String {
        switch health {
        case .healthy: "正常"
        case let .degraded(unreadable): "降级,不可读 \(list(unreadable))"
        case let .failed(unreadable): "失败,不可读 \(list(unreadable))"
        }
    }

    private static func list(_ directories: [String]) -> String {
        directories.joined(separator: "、")
    }

    public init() {}
}
