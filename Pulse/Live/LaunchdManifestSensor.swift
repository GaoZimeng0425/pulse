import Foundation
import PulseCore

/// launchd plist 目录的真实读取(launchd-attribution/01,ADR-0005):FileManager 枚举目录、
/// 读每个 `.plist` 的字节;缺席 / 不可读 / 有内容三种结果交给 PulseCore 的缝上判定。
/// 不解析、不解符号链接——那两件事在 `LaunchdManifestAssembler` 里,包内可测。
struct LiveLaunchdPlistSource: LaunchdPlistSource {
    func read(directory: String) -> LaunchdPlistDirectoryRead {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .absent
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return .unreadable
        }
        let plists = names
            .filter { $0.hasSuffix(".plist") }
            .compactMap { fileManager.contents(atPath: directory + "/" + $0) }
        return .plists(plists)
    }
}

/// launchd 服务清单 provider(ADR-0004 低频档;ADR-0005):60 秒一档,每 tick 推进组装器
/// 一轮——密封层只在首次(及补缺时)读、可变层每次重读——交付整份路径集合。读失败
/// (本轮没有目录可读)返回 nil,调度器按 lastGood 重投上次好清单。健康态按状态沿
/// 记日志(进入降级 / 失败 / 恢复各一条,同态静默),category "Launchd"。
/// 节奏归调度器管,provider 自己不记时间(与磁盘 / nettop provider 同款分工)。
final class LaunchdManifestProvider: SensorProvider, @unchecked Sendable {
    typealias Reading = Set<String>

    /// 刷新间隔:清单变化(装软件)不频繁,60 秒足够;票面验收要求 ≥ 60 秒。
    static let refreshInterval: TimeInterval = 60

    let cadence: SensorCadence = .every(seconds: LaunchdManifestProvider.refreshInterval)

    private let source: any LaunchdPlistSource
    private let log: @Sendable (LaunchdManifestHealthLog.Entry) -> Void
    /// 组装器与健康日志都是值类型、每 tick 推进;锁保护——provider 须 Sendable。
    private let lock = NSLock()
    private var assembler: LaunchdManifestAssembler
    private var healthLog = LaunchdManifestHealthLog()
    private let slot = SensorLastGoodBox<Set<String>>()

    var lastGood: Set<String>? { slot.current }

    init(
        source: any LaunchdPlistSource = LiveLaunchdPlistSource(),
        sealedDirectories: [String] = LaunchdServiceManifest.sealedDirectories,
        mutableDirectories: [String] = LaunchdServiceManifest.mutableDirectories(homeDirectory: NSHomeDirectory()),
        resolveSymlinks: @escaping @Sendable (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        },
        log: @escaping @Sendable (LaunchdManifestHealthLog.Entry) -> Void = LaunchdManifestProvider.logToService
    ) {
        self.source = source
        self.log = log
        self.assembler = LaunchdManifestAssembler(
            sealedDirectories: sealedDirectories,
            mutableDirectories: mutableDirectories,
            resolveSymlinks: resolveSymlinks
        )
    }

    func snapshot() async -> Set<String>? {
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

    private static func logToService(_ entry: LaunchdManifestHealthLog.Entry) {
        switch entry.level {
        case .info: LogService.info(entry.message, category: "Launchd")
        case .warn: LogService.warn(entry.message, category: "Launchd")
        case .error: LogService.error(entry.message, category: "Launchd")
        }
    }
}
