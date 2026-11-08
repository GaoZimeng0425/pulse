import Foundation
import PulseCore

// MARK: - 清理系统边界 · 测试假实现(p4-cleaner/02 同票交付)

//
// 内存文件系统 / 废纸篓 spy / 活动表三件,包内测试与 app 的 PulseTests 共用
// (Package.swift:PulseCoreTestSupport 双编)。04/05/08 票的核心测试继续从这里取。

/// ① 内存文件系统:path → 子项列表 或 枚举失败。
/// 记录每一次枚举请求路径(spy 面):断言「排除的目录没被碰」「双访目录只走了先到的路径」。
public actor FakeCleanDirectoryEnumerator: CleanDirectoryEnumerator {
    public enum Listing: Sendable {
        case entries([FsEntrySnapshot])
        case failure(CleanEnumerateFailure)
    }

    private var listings: [String: Listing]
    /// 默认给未登记目录的回包(空目录),免得每个测试都要铺全树。
    private let defaultForUnknown: Listing
    public private(set) var requestedPaths: [String] = []

    public init(listings: [String: Listing] = [:], defaultForUnknown: Listing = .entries([])) {
        self.listings = listings
        self.defaultForUnknown = defaultForUnknown
    }

    public func set(_ path: String, _ listing: Listing) {
        listings[path] = listing
    }

    public func entries(ofDirectory path: String) async throws -> [FsEntrySnapshot] {
        requestedPaths.append(path)
        switch listings[path] ?? defaultForUnknown {
        case let .entries(entries): return entries
        case let .failure(reason): throw CleanEnumerateError(path: path, reason: reason)
        }
    }

    public func requestedPathCount(_ path: String) -> Int {
        requestedPaths.filter { $0 == path }.count
    }
}

/// ② 废纸篓 spy:记录收到的路径序列,回包可配置。绝不真删——断言面就是「收到了什么」。
public actor FakeCleanTrashExecutor: CleanTrashExecutor {
    public private(set) var recycleCalls: [[String]] = []
    public private(set) var emptyCalls = 0
    /// 删前复核探针被问过的路径(按序)。
    public private(set) var stateQueries: [String] = []
    public var nextRecycleOutcome: TrashRecycleOutcome
    public var nextEmptySummary: TrashEmptySummary
    /// 删前复核探针的逐路径改写;未登记 = `.present(CleanFixture.directoryModified)`,
    /// 即与夹具目录的扫描快照一致(「扫描后没动过」)——既有清理流程测试零改动。
    public var pathStates: [String: PathSnapshot]

    public init(
        nextRecycleOutcome: TrashRecycleOutcome = TrashRecycleOutcome(),
        nextEmptySummary: TrashEmptySummary = TrashEmptySummary(volumes: []),
        pathStates: [String: PathSnapshot] = [:]
    ) {
        self.nextRecycleOutcome = nextRecycleOutcome
        self.nextEmptySummary = nextEmptySummary
        self.pathStates = pathStates
    }

    public func currentState(ofPath path: String) async -> PathSnapshot {
        stateQueries.append(path)
        return pathStates[path] ?? .present(modifiedEpoch: CleanFixture.directoryModified)
    }

    public func setPathState(_ state: PathSnapshot, for path: String) {
        pathStates[path] = state
    }

    public func recycleToTrash(_ paths: [String]) async -> TrashRecycleOutcome {
        recycleCalls.append(paths)
        return nextRecycleOutcome
    }

    public func emptyTrash() async -> TrashEmptySummary {
        emptyCalls += 1
        return nextEmptySummary
    }
}

/// ③ 活动表:可变条目集(05 票在用保护测试用它切换「项目有没有终端在里面」,
/// 以及「删除前重查」——两次调用之间改 entries 即可,判定永不缓存)。class 是
/// 刻意的:模型捕获的是同一个实例,中途改表立刻被下一次现查看见。
public final class FakeCleanActivitySource: CleanActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [CleanActivityEntry]

    public init(entries: [CleanActivityEntry] = []) {
        current = entries
    }

    public var entries: [CleanActivityEntry] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            current = newValue
        }
    }

    public func activeEntries() -> [CleanActivityEntry] {
        entries
    }
}

// MARK: - 夹具速搭

public enum CleanFixture {
    /// 夹具目录条目的默认自身 mtime(p5-cleaner/03 删前复核快照)。`FakeCleanTrashExecutor`
    /// 的探针默认报同值——扫描快照与删前状态一致,流程测试不必逐个造快照。
    public static let directoryModified: Double = 1_600_000_000

    /// 造文件条目。deviceID 默认同一台「盘」;fileID 用递减全局计数避免无意同键。
    /// `modified` = mtime epoch 秒(05 票项目年龄口径;默认 nil = 不参与年龄聚合)。
    public static func file(
        _ name: String,
        logical: Int64 = 100,
        allocated: Int64 = 512,
        reclaimable: Int64? = 512,
        device: UInt32 = 16_777_229,
        fileID: UInt64? = nil,
        dataless: Bool = false,
        modified: Double? = nil
    ) -> FsEntrySnapshot {
        FsEntrySnapshot(
            name: name,
            kind: .file,
            deviceID: device,
            fileID: fileID ?? nextFileID(),
            logicalSize: logical,
            allocatedSize: allocated,
            reclaimableSize: reclaimable,
            isDataless: dataless,
            modifiedEpoch: modified
        )
    }

    public static func directory(
        _ name: String,
        device: UInt32 = 16_777_229,
        fileID: UInt64,
        modified: Double? = directoryModified
    ) -> FsEntrySnapshot {
        FsEntrySnapshot(name: name, kind: .directory, deviceID: device, fileID: fileID, modifiedEpoch: modified)
    }

    public static func symlink(_ name: String) -> FsEntrySnapshot {
        FsEntrySnapshot(name: name, kind: .symlink, deviceID: 16_777_229, fileID: nextFileID())
    }

    /// 铺一棵假家目录(p4-cleaner/04 白名单测试的蓝本):`directories` = 家目录相对路径 →
    /// 该目录里放一个多大的文件(0 = 空目录),中间目录自动补齐。返回可直接喂
    /// `FakeCleanDirectoryEnumerator(listings:)` 的表;扫描根传 `home` 即得到以家目录为根的树。
    /// 目录 fileID 用全局计数(引擎按 (dev, fileID) 防双访,fileID 0 会被当无效跳过)。
    /// `modifiedByDir` = 相对路径 → 该目录 payload 文件的 mtime(05 票年龄测试:
    /// 项目文件老、产物文件新,年龄必须不看产物)。
    public static func homeListings(
        home: String,
        directories: [String: Int64],
        modifiedByDir: [String: Double] = [:]
    ) -> [String: FakeCleanDirectoryEnumerator.Listing] {
        var childDirs: [String: [String]] = [home: []]
        var leafBytes: [String: Int64] = [:]
        for (relative, bytes) in directories.sorted(by: { $0.key < $1.key }) {
            var parent = home
            for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
                let name = String(component)
                let child = parent + "/" + name
                if childDirs[parent]?.contains(name) != true {
                    childDirs[parent, default: []].append(name)
                }
                if childDirs[child] == nil {
                    childDirs[child] = []
                }
                parent = child
            }
            leafBytes[parent] = bytes
        }
        var listings: [String: FakeCleanDirectoryEnumerator.Listing] = [:]
        for (path, names) in childDirs {
            var entries = names.map { directory($0, fileID: nextFileID()) }
            if let bytes = leafBytes[path], bytes > 0 {
                let relative = String(path.dropFirst(home.count + 1))
                entries.append(file(
                    "payload.bin",
                    logical: bytes,
                    allocated: bytes,
                    reclaimable: bytes,
                    modified: modifiedByDir[relative]
                ))
            }
            listings[path] = .entries(entries)
        }
        return listings
    }

    // 唯一可变状态由 NSLock 串行化,锁内无 await(并发纪律;@unchecked 前提即此)。
    private static let counter = FileIDCounter()
    private static func nextFileID() -> UInt64 {
        counter.next()
    }

    private final class FileIDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var v: UInt64 = 9_000_000
        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            v += 1
            return v
        }
    }
}
