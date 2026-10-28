import Foundation

// MARK: - 清理系统边界(p4-cleaner/02,spec「唯一新接缝」,用户 2026-10-28 确认)

// 三件事:枚举目录 / 废纸篓执行 / 进程活动查询。
// 真实现(Live)在 app target:getattrlistbulk 扫描器(03 票)、NSWorkspace(04/08 票,
// 探针 12:recycle 吃 [URL] 回赠 原→新 URL 字典)、采样器快照(05 票)。
// 测试假实现同票交付(PulseCoreTestSupport:内存文件系统 / spy / 活动表)。

/// 目录枚举的一条快照记录。字段形状由探针 11 定死(docs/probes/11:macOS 27 布局与常量)。
public struct FsEntrySnapshot: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case file // VREG
        case directory // VDIR
        case symlink // VLNK——不跟随(spec:扫描器不跟符号链接)
        case other // 套接字 / FIFO 等
    }

    public var name: String
    public var kind: Kind
    /// st_dev。探针 11 ⑤:根卷与 Data 卷 st_dev 相同——设备号**不能**当剪枝键,只当身份键的一半。
    public var deviceID: UInt32
    /// 64 位对象 ID(探针 11:ATTR_CMN_FILEID 宽 8B)。与 deviceID 合成唯一身份。
    public var fileID: UInt64
    /// ATTR_FILE_TOTALSIZE(表观长度,仅对照展示用)。
    public var logicalSize: Int64
    /// block 口径占用(分配块 × 512)。克隆共享时**会重复计**,只作回退口径。
    public var allocatedSize: Int64
    /// cmnext PRIVATESIZE:删此文件立即释放、不被克隆/快照困住的字节数(探针 11 ④,
    /// 克隆实验逐条兑现)。nil = 文件系统没给(非 APFS / cmnext 缺席),引擎回退 block
    /// 口径并在节点上如实标记——绝不伪造 0(CODING_STANDARDS 防御性数据纪律)。
    public var reclaimableSize: Int64?
    public var linkCount: UInt32
    /// SF_DATALESS(iCloud 仅云端壳)。getattrlistbulk 不触发回源;计数上屏提示(03 票)。
    public var isDataless: Bool

    public init(
        name: String,
        kind: Kind,
        deviceID: UInt32,
        fileID: UInt64,
        logicalSize: Int64 = 0,
        allocatedSize: Int64 = 0,
        reclaimableSize: Int64? = nil,
        linkCount: UInt32 = 1,
        isDataless: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.deviceID = deviceID
        self.fileID = fileID
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.reclaimableSize = reclaimableSize
        self.linkCount = linkCount
        self.isDataless = isDataless
    }
}

// MARK: 枚举失败分类(错误台账的条目形状)

public enum CleanEnumerateFailure: Sendable, Equatable {
    case permissionDenied
    /// 枚举中途消失(扫描期间被删/改名)——不算错误环境,如实入册即可。
    case vanished
    /// 超出引擎深度护栏(dust 教训:递归遍历换平铺后的防御位,见 docs/research/dust-reference.md §2.2)。
    case tooDeep
    case other(errno: Int32)
}

public struct CleanEnumerateError: Error, Sendable, Equatable {
    public var path: String
    public var reason: CleanEnumerateFailure

    public init(path: String, reason: CleanEnumerateFailure) {
        self.path = path
        self.reason = reason
    }
}

// MARK: - 三件边界

/// ① 目录枚举:列出一个目录的直接子项(不含 `.` / `..`)。
/// 抛错 = 整个目录枚举失败,引擎记台账、标 partial、继续走别的目录。
public protocol CleanDirectoryEnumerator: Sendable {
    func entries(ofDirectory path: String) async throws -> [FsEntrySnapshot]
}

/// ② 废纸篓执行:移入 / 清空。见 ADR-0008:全系统唯二的删除出口,实现只许这两种模式。
public protocol CleanTrashExecutor: Sendable {
    /// 移入废纸篓。结果按路径逐项给出,失败项如实上报(探针 12:真实现回赠 原→新 URL 字典)。
    func recycleToTrash(_ paths: [String]) async -> TrashRecycleOutcome
    /// 清空用户可写的所有废纸篓;无权限项跳过并如实计数(08 票;探针 12:本机仅 ~/.Trash)。
    func emptyTrash() async -> TrashEmptySummary
}

/// 单次「移入废纸篓」的结果。
public struct TrashRecycleOutcome: Sendable, Equatable {
    /// 原 path → 废纸篓内去向路径。
    public var recycled: [String: String]
    /// 原 path → 失败原因(人话,进确认结果的失败清单)。
    public var failures: [String: String]

    public init(recycled: [String: String] = [:], failures: [String: String] = [:]) {
        self.recycled = recycled
        self.failures = failures
    }
}

/// 一个卷的废纸篓清空战报。
public struct TrashVolumeEmptySummary: Sendable, Equatable {
    public var volume: String
    public var emptiedItems: Int
    public var freedBytes: Int64
    public var skippedItems: Int

    public init(volume: String, emptiedItems: Int, freedBytes: Int64, skippedItems: Int = 0) {
        self.volume = volume
        self.emptiedItems = emptiedItems
        self.freedBytes = freedBytes
        self.skippedItems = skippedItems
    }
}

/// 全部卷的清空战报(确认文案的数字来源:所有卷汇总,票 01 拍板)。
public struct TrashEmptySummary: Sendable, Equatable {
    public var volumes: [TrashVolumeEmptySummary]

    public init(volumes: [TrashVolumeEmptySummary]) {
        self.volumes = volumes
    }

    public var totalItems: Int {
        volumes.reduce(0) { $0 + $1.emptiedItems }
    }

    public var totalFreedBytes: Int64 {
        volumes.reduce(0) { $0 + $1.freedBytes }
    }

    public var totalSkipped: Int {
        volumes.reduce(0) { $0 + $1.skippedItems }
    }
}

/// ③ 进程活动查询:此刻有终端 / 构建进程在用的路径前缀。
/// 05 票在用保护(三路判定)的输入;真实现复用采样器快照,零新采集。
/// 返回的是**前缀**:任一可删项路径落在某前缀之下即在用。
public protocol CleanActivitySource: Sendable {
    func activePathPrefixes() -> [String]
}
