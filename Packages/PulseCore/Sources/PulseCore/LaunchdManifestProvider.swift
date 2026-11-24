import Foundation

/// launchd 服务清单 provider(ADR-0004 低频档;ADR-0005;arch-clean/06 自 app target 迁入,
/// 读目录的 Live 源由组装点注入):60 秒一档,每 tick 推进组装器
/// 一轮——密封层只在首次(及补缺时)读、可变层每次重读——交付整份路径集合。读失败
/// (本轮没有目录可读)返回 nil,调度器按 lastGood 重投上次好清单。健康态按状态沿
/// 记日志(进入降级 / 失败 / 恢复各一条,同态静默),category "Launchd"。
/// 节奏归调度器管,provider 自己不记时间(与磁盘 / nettop provider 同款分工)。
public final class LaunchdManifestProvider: SensorProvider, @unchecked Sendable {
    public typealias Reading = Set<String>

    /// 刷新间隔:清单变化(装软件)不频繁,60 秒足够;票面验收要求 ≥ 60 秒。
    public static let refreshInterval: TimeInterval = 60

    public let cadence: SensorCadence = .every(seconds: LaunchdManifestProvider.refreshInterval)

    private let source: any LaunchdPlistSource
    private let log: @Sendable (LaunchdManifestHealthLog.Entry) -> Void
    /// 组装器与健康日志都是值类型、每 tick 推进;锁保护——provider 须 Sendable。
    private let lock = NSLock()
    private var assembler: LaunchdManifestAssembler
    private var healthLog = LaunchdManifestHealthLog()
    private let slot = SensorLastGoodBox<Set<String>>()

    public var lastGood: Set<String>? {
        slot.current
    }

    public init(
        source: any LaunchdPlistSource,
        sealedDirectories: [String] = LaunchdServiceManifest.sealedDirectories,
        mutableDirectories: [String] = LaunchdServiceManifest.mutableDirectories(homeDirectory: NSHomeDirectory()),
        resolveSymlinks: @escaping @Sendable (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        },
        log: @escaping @Sendable (LaunchdManifestHealthLog.Entry) -> Void = LaunchdManifestProvider.logToCore
    ) {
        self.source = source
        self.log = log
        assembler = LaunchdManifestAssembler(
            sealedDirectories: sealedDirectories,
            mutableDirectories: mutableDirectories,
            resolveSymlinks: resolveSymlinks
        )
    }

    public func snapshot() async -> Set<String>? {
        advance()
    }

    /// 一轮推进(同步、持锁):组装 → 健康沿日志 → lastGood。拆出同步方法是因为裸 lock /
    /// unlock 不许跨越异步上下文;本方法内没有挂起点。
    private func advance() -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        let outcome = assembler.assemble(using: source)
        if let entry = healthLog.transition(to: outcome.health) {
            log(entry)
        }
        guard let paths = outcome.paths else { return nil }
        slot.store(paths)
        return paths
    }

    public static func logToCore(_ entry: LaunchdManifestHealthLog.Entry) {
        switch entry.level {
        case .info: CoreLog.info(entry.message, category: "Launchd")
        case .warn: CoreLog.warn(entry.message, category: "Launchd")
        case .error: CoreLog.error(entry.message, category: "Launchd")
        }
    }
}
