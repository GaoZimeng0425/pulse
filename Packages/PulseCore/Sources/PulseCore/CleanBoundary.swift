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
    /// ATTR_CMN_MODTIME(秒,含小数纳秒;05 票项目年龄口径)。nil = 文件系统没给,
    /// 不参与年龄聚合(不伪造)。**目录自身的 mtime 不进年龄**(重装依赖会刷它)——
    /// 引擎只聚合文件条目的 mtime,见 `SpaceNode.newestChangeEpoch`;目录条目的 mtime
    /// 另作删前复核快照(`SpaceNode.ownModifiedEpoch`,p5-cleaner/03)。
    /// 换算一律走 `FsTimestamp.epoch`(扫描与删前探针同一公式,见那里)。
    public var modifiedEpoch: Double?

    public init(
        name: String,
        kind: Kind,
        deviceID: UInt32,
        fileID: UInt64,
        logicalSize: Int64 = 0,
        allocatedSize: Int64 = 0,
        reclaimableSize: Int64? = nil,
        linkCount: UInt32 = 1,
        isDataless: Bool = false,
        modifiedEpoch: Double? = nil
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
        self.modifiedEpoch = modifiedEpoch
    }
}

// MARK: 枚举失败分类(错误台账的条目形状)

public enum CleanEnumerateFailure: Sendable, Equatable {
    /// TCC 拒绝(EPERM):全盘访问可解——界面横幅的「去授权」只对这一类喊。
    case tccDenied
    /// UNIX 权限拒绝(EACCES,root/他属主目录):FDA 也无解,不引导授权,
    /// 如实计入台账并标「部分扫描」(ADR-0009:清理永不碰 root)。
    case permissionDenied
    /// 枚举中途消失(扫描期间被删/改名)——不算错误环境,如实入册即可。
    case vanished
    /// 枚举中途用户取消(批粒度检查,cleaner-scan-hang/02):目录记空 partial、
    /// 如实入台账——取消不是故障,但「这块没扫全」要可追;权限横幅只看
    /// `.tccDenied`,不受此档影响。
    case cancelled
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
    /// 删前复核探针(p5-cleaner/03):路径此刻的状态(不跟随符号链接)。只读、无副作用;
    /// 判定在 PulseCore `PreDeleteCheck`,执行器只报事实。**必填、无默认实现**——
    /// 安全闸的探针漏实现应当编译失败,而不是静默放行。
    func currentState(ofPath path: String) async -> PathSnapshot
}

/// 一条路径此刻的状态(删前复核探针的产出)。
public enum PathSnapshot: Sendable, Equatable {
    /// 路径不存在(ENOENT)。
    case missing
    /// 读不到状态(权限等;不是「不存在」,也不能当「没变」)。
    case unreadable
    /// 存在;`modifiedEpoch` = 条目自身 mtime(`FsTimestamp.epoch` 换算)。
    case present(modifiedEpoch: Double)
}

/// 文件系统时间戳 → epoch 秒的**唯一换算**(p5-cleaner/03)。扫描枚举器
/// (getattrlistbulk ATTR_CMN_MODTIME)与删前探针(lstat st_mtimespec)读的是同一个
/// inode 字段,同一公式换算才能逐位相等——两处各写一遍,迟早有一处改成别的写法,
/// 删前复核就会把没动过的目录全判成「有变动」。
public enum FsTimestamp {
    public static func epoch(seconds: Int64, nanoseconds: Int64) -> Double {
        Double(seconds) + Double(max(0, nanoseconds)) * 1e-9
    }
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

/// ③ 进程活动查询:此刻哪些路径有进程活动、是什么性质的活动。
/// 05 票在用保护(三路判定)的输入;真实现复用采样器快照,零新采集。
/// 判定口径:**活动落在项目之内**(路径前缀包含)即保护该项目——
/// 终端 cd 在项目外(哪怕家目录)不保护任何项目。
public protocol CleanActivitySource: Sendable {
    /// 每条 = 一个有活动的路径前缀 + 该前缀上观察到的原因(可叠加)。
    /// 实现必须在每次调用时重新判定(删除前重查、永不缓存,spec 在用保护口径)。
    func activeEntries() -> [CleanActivityEntry]
}

/// 一处有进程活动的路径(前缀)与原因集合。
public struct CleanActivityEntry: Sendable, Equatable {
    public var path: String
    public var reasons: CleanActivityReason

    public init(path: String, reasons: CleanActivityReason) {
        self.path = path
        self.reasons = reasons
    }
}

/// 在用原因(界面拼人话用):终端驻留 / 构建进程 / git 活动 / 路径被 argv 引用 /
/// AI 服务进程在场(p6-cleaner/02 第四路,组作用域——见 `CleanActivityDerivation`)。
public struct CleanActivityReason: OptionSet, Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let terminal = CleanActivityReason(rawValue: 1 << 0)
    public static let build = CleanActivityReason(rawValue: 1 << 1)
    public static let git = CleanActivityReason(rawValue: 1 << 2)
    public static let referenced = CleanActivityReason(rawValue: 1 << 3)
    public static let aiService = CleanActivityReason(rawValue: 1 << 4)

    /// 人话(按固定顺序拼:「终端与构建正在此项目」的原料)。
    public var title: String {
        var parts: [String] = []
        if contains(.terminal) {
            parts.append("终端")
        }
        if contains(.build) {
            parts.append("构建")
        }
        if contains(.git) {
            parts.append("git")
        }
        if contains(.referenced) {
            parts.append("进程引用其路径")
        }
        if contains(.aiService) {
            parts.append("AI 服务")
        }
        if parts.isEmpty {
            parts.append("进程")
        }
        return parts.joined(separator: "与")
    }
}
