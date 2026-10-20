import Darwin
import Foundation
import IOKit

// 容器对账算法(container_of 归约 / getmntinfo 同容器过滤 / 每卷 getattrlist 精确
// 已用 / "其他卷"差额兜底 / TM 前缀识别 / purgeable 两 key 差值)与快照记录解析
// 移植自 petal(MIT)src/disk.rs(调研 docs/research/sensor-impl-comparison.md §2.1
// 逐条钉死;依 spec 移植代码纪律注明来源)。
// 吞吐差分与向上找驱动的遍历移植自 stats(MIT)Modules/Disk/readers.swift:248-321。
// 三条实现路径均按工单 01 真机探针结论钉死(docs/probes/):
//   可清除 = CFURL 两 key 差值(Finder 口径,探针①);快照 = fs_snapshot_list 直用,
//   attrlist 必带 RETURNED_ATTRS/NAME/CRTIME,判成败看返回值不看 errno(探针②);
//   吞吐主路径 = IORegistry 内核账差分,键名 "Bytes (Read)"/"Bytes (Write)",
//   回退 = rusage 求和 + 30s 低频档(探针③)。

// MARK: - 容量对账(纯逻辑)

/// 单卷已用明细行(工单 05 各卷明细):label 是展示名(固定标签或挂载点 basename)。
struct DiskVolumeUsage: Equatable, Identifiable, Sendable {
    let label: String
    /// 挂载点(明细行的身份的一部分;展示不直接用)。
    let mountPoint: String
    let usedBytes: UInt64

    var id: String { mountPoint }
}

/// 磁盘容量卡读数(工单 05 ①②③④):容器级对账(Finder 口径)+ 可清除 +
/// Data 卷与其余卷明细 + 本地快照列表。
struct DiskCapacityReading: Equatable, Sendable {
    /// 卷的 Finder 名("Macintosh HD");读不到为 nil(标题显示占位)。
    let volumeName: String?
    /// 容器总容量(f_blocks × f_bsize)。
    let containerTotalBytes: UInt64
    /// 容器已用((f_blocks − f_bfree) × f_bsize)——与 Finder「已用」同口径
    /// (裸 statfs 的单卷空闲在 APFS 上是容器共享口径,不可信,petal 注释)。
    let containerUsedBytes: UInt64
    /// 实际可用 = importantUsage(Finder「可用」口径,探针①分毫不差);
    /// nil = 读不到,显示占位。
    let availableForImportantUsageBytes: Int64?
    /// 可清除空间 = 两 key 差值(petal:important − free,max 0)——TM 本地快照、
    /// iCloud 可回源文件、系统可清缓存等系统自行腾挪的部分;与「实际可用」
    /// 分开文案(petal 注释:它已计入 used,又在 important 口径里被放开)。
    /// nil = 任一 key 读不到,不伪造。
    let purgeableBytes: Int64?
    /// Data 卷(用户文件与 App;petal 的扫描锚点,明细首位)。
    let dataVolume: DiskVolumeUsage
    /// 其余已挂载同容器卷(密封系统卷 macOS / Preboot / 虚拟内存 / 系统更新…)。
    let otherVolumes: [DiskVolumeUsage]
    /// 对账差额:未挂载卷(通常是 Recovery)与容器元数据(petal "Other volumes"
    /// 兜底,必做——否则各卷之和与容器总数对不上)。accounted ≥ used 时为 nil。
    let unaccounted: DiskVolumeUsage?
    /// 本地快照列表(Data 卷)。
    let snapshots: DiskSnapshotListing

    /// 已对账字节合计(不变式锚点:== containerUsedBytes,单测钉死)。
    var accountedBytes: UInt64 {
        dataVolume.usedBytes
            + otherVolumes.reduce(0) { $0 + $1.usedBytes }
            + (unaccounted?.usedBytes ?? 0)
    }
}

/// 容量对账纯逻辑(spec 测试缝):源给原始读数,这里折叠出展示读数。
enum DiskCapacity {
    /// Data 卷挂载点(petal 识别锚点,disk.rs:228-232;Live 源的快照目标同此)。
    static let dataVolumeMountPoint = "/System/Volumes/Data"

    /// 设备名 → APFS 容器号(petal container_of,disk.rs:188-194):
    /// "/dev/disk3s1s1" → "disk3";"map auto_home" 之类非 /dev/ 设备返回 nil。
    static func containerOf(device: String) -> String? {
        guard let name = device.removePrefix("/dev/"), name.hasPrefix("disk") else { return nil }
        let digits = name.dropFirst(4)
        let end = digits.firstIndex(where: { !$0.isNumber }) ?? digits.endIndex
        return String(name[..<end]).isEmpty ? nil : "disk" + String(digits[..<end])
    }

    /// 已知挂载点的固定标签(petal disk.rs:226-237),其余取挂载点 basename。
    static func label(forMountPoint mountPoint: String) -> String {
        switch mountPoint {
        case "/": return "macOS"
        case dataVolumeMountPoint: return "数据卷"
        case "/System/Volumes/VM": return "虚拟内存"
        case "/System/Volumes/Preboot": return "Preboot"
        case "/System/Volumes/Update": return "系统更新"
        default: break
        }
        let name = mountPoint.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? mountPoint : name
    }

    /// 原始读数 → 展示读数(全部纯逻辑在此折叠,单测即本接缝)。
    /// 返回 nil = 非现代 APFS 系统/数据卷组(容器归约失败或 Data 卷缺席),
    /// 不伪造容量(petal startup_layout 的 None 口径)。
    static func make(from raw: DiskCapacityRawReading) -> DiskCapacityReading? {
        guard let container = containerOf(device: raw.rootDevice) else { return nil }

        // getmntinfo 全表 → 只留同容器 apfs 卷,每卷取 getattrlist 精确已用
        // (usedBytes 读失败的卷跳过,不伪造,petal `continue` 口径)。
        var data: DiskVolumeUsage?
        var others: [DiskVolumeUsage] = []
        for volume in raw.mountedVolumes {
            guard volume.fileSystem == "apfs",
                  containerOf(device: volume.device) == container,
                  let used = volume.usedBytes
            else { continue }
            if volume.mountPoint == dataVolumeMountPoint {
                data = DiskVolumeUsage(
                    label: label(forMountPoint: volume.mountPoint),
                    mountPoint: volume.mountPoint,
                    usedBytes: used
                )
            } else {
                others.append(DiskVolumeUsage(
                    label: label(forMountPoint: volume.mountPoint),
                    mountPoint: volume.mountPoint,
                    usedBytes: used
                ))
            }
        }
        guard let dataVolume = data else { return nil }

        // 对账兜底(petal disk.rs:241-245):各卷之和 < 容器已用时,
        // 差额记"其他卷"(未挂载卷 + 容器元数据);反向(超额)不造负行。
        let accounted = dataVolume.usedBytes + others.reduce(0) { $0 + $1.usedBytes }
        var unaccounted: DiskVolumeUsage?
        if raw.containerUsedBytes > accounted {
            unaccounted = DiskVolumeUsage(
                label: "其他卷",
                mountPoint: "(unaccounted)",
                usedBytes: raw.containerUsedBytes - accounted
            )
        }

        // 可清除 = 两 key 差值(petal disk.rs:129-163):important − free,max 0;
        // 任一 key 读不到 → nil,显示占位不伪造。
        let purgeable = raw.availableForImportantUsage.flatMap { important in
            raw.availableCapacity.map { free in max(0, important - free) }
        }

        return DiskCapacityReading(
            volumeName: raw.volumeName,
            containerTotalBytes: raw.containerTotalBytes,
            containerUsedBytes: raw.containerUsedBytes,
            availableForImportantUsageBytes: raw.availableForImportantUsage,
            purgeableBytes: purgeable,
            dataVolume: dataVolume,
            otherVolumes: others,
            unaccounted: unaccounted,
            snapshots: raw.snapshots
        )
    }
}

private extension String {
    /// 前缀剥离(找不到前缀返回 nil)——container_of 的第一步。
    func removePrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

// MARK: - 本地快照(纯逻辑)

/// 一个 APFS 快照:卷在某个时点的冻结副本(petal Snapshot,disk.rs:40-47)。
/// 它占着的块在快照删除前不释放——之后删除/改动的文件空间不会回来。
struct DiskSnapshot: Equatable, Identifiable, Sendable {
    let name: String
    /// Unix 秒(petal created)。
    let createdEpoch: Int64

    var id: String { name }
    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(createdEpoch)) }

    /// 本地 Time Machine 快照(macOS 自留 24 小时;petal is_time_machine,disk.rs:55-57)。
    var isTimeMachine: Bool { name.hasPrefix("com.apple.TimeMachine.") }

    /// 来源识别(petal kind,disk.rs:62-69):TM / macOS 更新 / CCC / 其他 App。
    var kindTitle: String {
        switch true {
        case isTimeMachine: "Time Machine"
        case name.hasPrefix("com.apple.os.update"): "macOS 更新"
        case name.hasPrefix("com.bombich.ccc"): "Carbon Copy Cloner"
        default: "其他应用"
        }
    }
}

/// 快照列表读数:listing(含空 = 真的没有)或 unavailable(读不到,占位不伪造)。
enum DiskSnapshotListing: Equatable, Sendable {
    /// rc < 0(未来权限收紧 / EACCES)或 open 失败或目标非 APFS:不可用。
    case unavailable
    case listing([DiskSnapshot])
}

/// fs_snapshot_list 单条记录解析(petal parse_snapshot,disk.rs:105-123;记录
/// 布局经探针②实测钉死):[u32 总长][attribute_set_t 20B][attrreference_t 8B:
/// 名称相对偏移(i32)+ 名称长度(u32,含结尾 NUL)][timespec 16B]…,名称数据按
/// 偏移相对 attrreference_t 起始定位,取 length−1 去掉 NUL。
enum DiskSnapshotRecord {
    /// 最短合法记录 = 4 + attribute_set_t + attrreference_t + timespec(16)。
    static let minimumLength = 4 + MemoryLayout<attribute_set_t>.size
        + MemoryLayout<attrreference_t>.size + 16

    private static let nameReferenceOffset = 4 + MemoryLayout<attribute_set_t>.size
    private static let timeOffset = nameReferenceOffset + MemoryLayout<attrreference_t>.size

    /// 解析单条记录;截断/越界记录返回 nil(跳过,不误读,petal 同款)。
    static func parse<S: Sequence>(_ record: S) -> DiskSnapshot? where S.Element == UInt8 {
        let bytes = Array(record)
        guard bytes.count >= minimumLength else { return nil }
        return bytes.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
            let nameOffset = base.loadUnaligned(fromByteOffset: nameReferenceOffset, as: Int32.self)
            let nameLength = Int(base.loadUnaligned(
                fromByteOffset: nameReferenceOffset + 4, as: UInt32.self
            ))
            guard nameOffset >= 0, nameLength > 0 else { return nil }
            let nameStart = nameReferenceOffset + Int(nameOffset)
            guard nameStart >= 0, nameStart + nameLength <= bytes.count else { return nil }
            let name = String(
                decoding: UnsafeRawBufferPointer(
                    start: base + nameStart, count: nameLength - 1
                ), as: UTF8.self
            )
            let created = base.loadUnaligned(fromByteOffset: timeOffset, as: Int64.self)
            return DiskSnapshot(name: name, createdEpoch: created)
        }
    }

    /// 一次调用回包里的 count 条记录(背靠背,每条以 u32 总长开头)→ 快照列表。
    /// 越界/截断记录跳过;解析结果按创建时间升序(petal:最旧在前)。
    static func parseBuffer(_ buffer: [UInt8], count: Int) -> [DiskSnapshot] {
        var snapshots: [DiskSnapshot] = []
        var at = 0
        for _ in 0..<max(0, count) {
            guard at + 4 <= buffer.count else { break }
            let length = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)
            })
            guard length >= minimumLength, at + length <= buffer.count else { break }
            if let snapshot = parse(buffer[at..<(at + length)]) {
                snapshots.append(snapshot)
            }
            at += length
        }
        return snapshots.sorted { $0.createdEpoch < $1.createdEpoch }
    }
}

// MARK: - 吞吐差分(纯逻辑)

/// 系统级累计 IO 计数(块存储驱动内核账 / rusage 求和共用形状)。
struct DiskIOCounters: Equatable, Sendable {
    let readBytes: UInt64
    let writeBytes: UInt64
    /// 采样时刻(mach 绝对时间纳秒;只用于算 elapsed,跨源不可比)。
    let atUptimeNanos: UInt64
}

/// 一轮差分出的读写速率(字节/秒)。
struct DiskRates: Equatable, Sendable {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    static let zero = DiskRates(readBytesPerSecond: 0, writeBytesPerSecond: 0)
}

/// 走势图的单点(读 + 写)。
struct DiskRatePoint: Equatable, Sendable {
    let read: Double
    let write: Double
}

/// 磁盘吞吐读数(工单 05 ⑤):当前速率 + 近窗走势(旧 → 新)。
struct DiskThroughputReading: Equatable, Sendable {
    let current: DiskRates
    let trend: [DiskRatePoint]
    /// 本轮记账增量(字节;历史落库消费,UI 形状不读,默认 0 让展示构造方
    /// 免于关心):差分成功轮 = 计数差,首读/回退/丢弃轮 = 0——与网络增量
    /// 同口径,落库只信增量,不信"速率 × 窗宽"折算。
    var readBytesDelta: UInt64 = 0
    var writeBytesDelta: UInt64 = 0

    /// 图表口径:读 + 写合计流量。
    var totalBytesPerSecond: Double {
        current.readBytesPerSecond + current.writeBytesPerSecond
    }
}

/// 吞吐差分(stats ActivityReader.activity + elapsed 防护,readers.swift:267-280):
/// 差分三件防护——首读置零(只立基线)、计数回退/重置钳零并重立基线、
/// elapsed 非有限或 ≤0 钳零。
enum DiskThroughputDiffer {
    /// 单轮速率上限(字节/秒):超过即视为计数跳变、整轮作废(不出速率、不进记账)。
    /// 现役 NVMe 顶到 ~7 GB/s,20 GB/s 留足余量;主要防 rusage 求和回退档——进程计数
    /// 上轮缺席、本轮带终身累计进账时和值一轮跳上百 GB(arch-review-2026-10-18/03 甲8,
    /// 参照 NetworkRateDiffer 的跳变防护)。
    static let maximumBytesPerSecond: Double = 20_000_000_000

    static func rates(previous: DiskIOCounters?, current: DiskIOCounters) -> DiskRates {
        guard let previous else { return .zero } // 首读:立基线,不出速率
        // 计数回退(重置/换盘/回绕)→ 本轮 0,基线以本轮为准(见 Accumulator)。
        guard current.readBytes >= previous.readBytes,
              current.writeBytes >= previous.writeBytes
        else { return .zero }
        guard current.atUptimeNanos > previous.atUptimeNanos else { return .zero }
        let elapsed = Double(current.atUptimeNanos - previous.atUptimeNanos) / 1_000_000_000
        guard elapsed > 0, elapsed.isFinite else { return .zero }
        let read = Double(current.readBytes - previous.readBytes) / elapsed
        let write = Double(current.writeBytes - previous.writeBytes) / elapsed
        guard read.isFinite, write.isFinite else { return .zero }
        guard read <= maximumBytesPerSecond, write <= maximumBytesPerSecond else { return .zero }
        return DiskRates(readBytesPerSecond: read, writeBytesPerSecond: write)
    }
}

// MARK: - 源缝协议(OS 边界,spec 六缝之磁盘两源)

/// 挂载点原始行(getmntinfo 全表,不做任何过滤——过滤是对账纯逻辑)。
struct MountedVolumeRaw: Equatable, Sendable {
    let mountPoint: String
    /// f_mntfromname 原样("/dev/disk3s1s1"、"map auto_home"…)。
    let device: String
    /// f_fstypename("apfs"…)。
    let fileSystem: String
    /// getattrlist ATTR_VOL_SPACEUSED;nil = 该卷读失败。
    let usedBytes: UInt64?
}

/// 磁盘容量源原始读数(OS 边界形状,未加工;nil 字段 = 该项读不到)。
struct DiskCapacityRawReading: Sendable {
    /// 根卷设备名(statfs("/").f_mntfromname)。
    let rootDevice: String
    let containerTotalBytes: UInt64
    let containerUsedBytes: UInt64
    /// CFURL importantUsage(Finder 口径);nil = 读不到。
    let availableForImportantUsage: Int64?
    /// CFURL AvailableCapacity(free 口径);nil = 读不到。
    let availableCapacity: Int64?
    /// 卷的 Finder 名;nil = 读不到。
    let volumeName: String?
    /// getmntinfo 全表(不过滤)。
    let mountedVolumes: [MountedVolumeRaw]
    /// Data 卷快照列表(Data 卷缺席时 unavailable)。
    let snapshots: DiskSnapshotListing
}

/// 磁盘容量源接缝:一次 read 拿全部原始字段,缝上是纯逻辑。
protocol DiskCapacitySource: Sendable {
    /// nil = 连根卷都读不到(容量卡整卡占位)。
    func read() -> DiskCapacityRawReading?
}

/// 磁盘吞吐源接缝:读累计字节计数,差分与防护全在缝上。
protocol DiskThroughputSource: Sendable {
    /// nil = 本次读不到(路径失效/键缺失),调度器跳过本轮交付。
    func readCounters() -> DiskIOCounters?
    /// 建议节奏秒数:IORegistry 主路径 5s 短档;rusage 求和回退 30s 低频档
    /// (每进程一次系统调用的成本,工单原文预案)。
    var cadenceSeconds: TimeInterval { get }
}

// MARK: - sys/attr.h 常量(C 宏不进 Swift,照 SDK 头手抄,探针②同款)

private let ATTR_BIT_MAP_COUNT = 5
private let ATTR_CMN_NAME: attrgroup_t = 0x0000_0001
private let ATTR_CMN_CRTIME: attrgroup_t = 0x0000_0200
private let ATTR_CMN_RETURNED_ATTRS: attrgroup_t = 0x8000_0000
private let ATTR_VOL_INFO: attrgroup_t = 0x8000_0000
private let ATTR_VOL_SPACEUSED: attrgroup_t = 0x0080_0000

// sys/snapshot.h 不在 Swift Darwin 模块面里,手写声明(探针②同款)。
@_silgen_name("fs_snapshot_list")
private func fs_snapshot_list(
    _ dirfd: Int32, _ alist: UnsafeMutablePointer<attrlist>?,
    _ buf: UnsafeMutableRawPointer?, _ size: Int, _ flags: UInt32
) -> Int32

// MARK: - Live 容量源

/// Darwin 薄适配器:statfs("/") 定容器 → getmntinfo 全挂载点 → 每卷 getattrlist
/// 精确已用 → CFURL 两 key(Finder 口径可用)→ fs_snapshot_list 列 Data 卷快照。
struct LiveDiskCapacitySource: DiskCapacitySource {
    func read() -> DiskCapacityRawReading? {
        var root = statfs()
        guard statfs("/", &root) == 0 else { return nil }
        let blockSize = UInt64(root.f_bsize)
        let total = UInt64(root.f_blocks) * blockSize
        let used = UInt64(root.f_blocks - root.f_bfree) * blockSize

        // getmntinfo(MNT_NOWAIT):全挂载点快照,不过滤(petal disk.rs:210-224)。
        var mountsPointer: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo(&mountsPointer, MNT_NOWAIT)
        guard mountCount > 0, let mountsPointer else { return nil }
        let mountedVolumes = Array(
            UnsafeBufferPointer(start: mountsPointer, count: Int(mountCount))
        ).map { entry -> MountedVolumeRaw in
            MountedVolumeRaw(
                mountPoint: Self.cString(entry.f_mntonname),
                device: Self.cString(entry.f_mntfromname),
                fileSystem: Self.cString(entry.f_fstypename),
                usedBytes: Self.volumeUsedBytes(atPath: Self.cString(entry.f_mntonname))
            )
        }

        // Data 卷锚点(与对账纯逻辑同一常量);缺席 = 快照不可用(整读数随后为 nil)。
        let dataMountPoint = mountedVolumes
            .first { $0.mountPoint == DiskCapacity.dataVolumeMountPoint }?
            .mountPoint
        let snapshots = dataMountPoint.map { DiskSnapshotLister.list(mount: $0) } ?? .unavailable

        // CFURL 两 key(读前清缓存保证同刻新鲜值,探针①同款):free(Int 口径)
        // 与 important(Int64 口径),统一折成 Int64;key 未回包 → nil 占位。
        var rootURL = URL(fileURLWithPath: "/")
        rootURL.removeAllCachedResourceValues()
        let freeValues = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let importantValues = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = freeValues.flatMap { $0.volumeAvailableCapacity }.map(Int64.init)
        let important = importantValues.flatMap { $0.volumeAvailableCapacityForImportantUsage }
        let volumeName: String? = (try? rootURL.resourceValues(forKeys: [.volumeLocalizedNameKey]))?
            .volumeLocalizedName ?? nil

        return DiskCapacityRawReading(
            rootDevice: Self.cString(root.f_mntfromname),
            containerTotalBytes: total,
            containerUsedBytes: used,
            availableForImportantUsage: important,
            availableCapacity: free,
            volumeName: volumeName,
            mountedVolumes: mountedVolumes,
            snapshots: snapshots
        )
    }

    /// C 定长字符数组(f_mntonname/f_mntfromname/f_fstypename)→ String。
    private static func cString<T>(_ chars: T) -> String {
        withUnsafeBytes(of: chars) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// 每卷精确已用(getattrlist ATTR_VOL_SPACEUSED,petal volume_used,disk.rs:165-186)。
    /// 回包布局(petal 12 字节 packed 结构实测成立):attrlist 不带 commonattr 位时
    /// 不写 attribute_set_t,回包 = [u32 总长][off_t 已用 @ 偏移 4]——探针②的
    /// 负对照从反向钉实了这条布局规则。读失败(含 ERANGE)返回 nil。
    private static func volumeUsedBytes(atPath path: String) -> UInt64? {
        var attrs = attrlist(
            bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0,
            commonattr: 0, volattr: ATTR_VOL_INFO | ATTR_VOL_SPACEUSED,
            dirattr: 0, fileattr: 0, forkattr: 0
        )
        var buffer = [UInt8](repeating: 0, count: 16)
        let ok = path.withCString { cPath in
            getattrlist(cPath, &attrs, &buffer, buffer.count, 0) == 0
        }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            let used = raw.loadUnaligned(fromByteOffset: 4, as: off_t.self)
            return used >= 0 ? UInt64(used) : nil
        }
    }
}

/// fs_snapshot_list 直用(探针②实现骨架;petal snapshots,disk.rs:75-103)。
/// 免 root 可列(探针②:uid=501 下 rc=0);判成败看返回值——成功空列表时
/// errno 是残留值,不可信(探针②结论)。rc < 0 且一条未得 → unavailable 占位。
enum DiskSnapshotLister {
    /// 一次读取的缓冲(探针②同款 64 KiB)。
    private static let bufferSize = 64 * 1024

    static func list(mount: String) -> DiskSnapshotListing {
        let fd = open(mount, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        // attrlist 三件套(petal disk.rs:84-87):缺 RETURNED_ATTRS 内核 EINVAL(探针②负对照)。
        var attrs = attrlist(
            bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0,
            commonattr: ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_CRTIME,
            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0
        )
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<Int>.alignment
        )
        defer { buffer.deallocate() }
        var collected: [DiskSnapshot] = []
        var lastResult: Int32 = 0
        while true {
            lastResult = fs_snapshot_list(fd, &attrs, buffer, bufferSize, 0)
            guard lastResult > 0 else { break } // 0 = 成功但无更多;负 = 出错
            let bytes = UnsafeRawBufferPointer(start: buffer, count: bufferSize)
                .prefix(Int(lastResult))
            collected.append(contentsOf: DiskSnapshotRecord.parseBuffer(Array(bytes), count: Int(lastResult)))
        }
        if lastResult < 0, collected.isEmpty { return .unavailable }
        return .listing(collected)
    }
}

// MARK: - Live 吞吐源

/// IORegistry 内核账差分源(探针③验证的主路径;stats readers.swift:248-321 翻译):
/// 根卷 BSD 名 → IOMedia → 沿父链向上找 IOBlockStorageDriver(环检测 visited ≤ 256,
/// 唯一驱动确认)→ Statistics 字典的 "Bytes (Read)"/"Bytes (Write)" 累计计数。
/// 系统级内核账:短命进程与内核回写都在,免 root。
struct IORegistryDiskThroughputSource: DiskThroughputSource {
    /// 短档:差分窗口 5s,走势 60 点 = 5 分钟。
    var cadenceSeconds: TimeInterval { 5 }

    // 键名照探针③结论(= SDK IOKit/storage/IOBlockStorageDriver.h 的
    // kIOBlockStorageDriverStatisticsBytesReadKey/WrittenKey 字面量)。
    private static let driverClass = "IOBlockStorageDriver"
    private static let mediaClass = "IOMedia"
    private static let statisticsKey = "Statistics"
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWrittenKey = "Bytes (Write)"

    func readCounters() -> DiskIOCounters? {
        guard let bsdName = Self.rootVolumeBSDName(),
              let driver = Self.findDriver(forBSDName: bsdName)
        else { return nil } // 向上遍历失败 = 回退条件之一
        defer { IOObjectRelease(driver) }
        guard
            let statistics = IORegistryEntryCreateCFProperty(
                driver, Self.statisticsKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
            let read = Self.counter(statistics, key: Self.bytesReadKey),
            let write = Self.counter(statistics, key: Self.bytesWrittenKey)
        else { return nil } // 键缺失 = 回退条件之二
        return DiskIOCounters(
            readBytes: read, writeBytes: write,
            atUptimeNanos: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// 根卷 BSD 名("disk3s1s1";statfs("/") → f_mntfromname 去 /dev/ 前缀)。
    static func rootVolumeBSDName() -> String? {
        var root = statfs()
        guard statfs("/", &root) == 0 else { return nil }
        let device = withUnsafeBytes(of: root.f_mntfromname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
    }

    /// 计数键宽容读取:OSNumber 桥来的 NSNumber 直接取(探针③同款已验证)。
    private static func counter(_ dictionary: [String: Any], key: String) -> UInt64? {
        (dictionary[key] as? NSNumber)?.uint64Value
    }

    /// 卷 IOMedia → 沿 kIOServicePlane 父链向上找块驱动(stats getDeviceIOParent,
    /// readers.swift:284-321):BFS 收敛全部祖先分支,仅当恰有一个 driver 命中时
    /// 返回(歧义 = 失败,不猜);visited ≤ 256 防环。
    static func findDriver(forBSDName bsdName: String) -> io_registry_entry_t? {
        var mediaIterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(Self.mediaClass), &mediaIterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(mediaIterator) }
        var media: io_registry_entry_t = 0
        var candidate = IOIteratorNext(mediaIterator)
        while candidate != 0 {
            if IORegistryEntryCreateCFProperty(
                candidate, "BSD Name" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String == bsdName {
                media = candidate
                break
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(mediaIterator)
        }
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        var frontier = [media]
        defer { frontier.forEach { IOObjectRelease($0) } }
        var visited: Set<UInt64> = []
        var driver: io_registry_entry_t?
        var index = 0
        while index < frontier.count {
            let entry = frontier[index]
            index += 1
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS else { return nil }
            guard visited.insert(entryID).inserted, visited.count <= 256 else { continue }
            if IOObjectConformsTo(entry, Self.driverClass) != 0 {
                guard driver == nil else { return nil } // 两个分支都命中驱动 = 歧义,不猜
                IOObjectRetain(entry)
                driver = entry
                continue // 不提前停:确认唯一仍要遍历完(与 stats 一致)
            }
            var parentIterator: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parentIterator) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(parentIterator) }
            var parent = IOIteratorNext(parentIterator)
            while parent != 0 {
                frontier.append(parent)
                parent = IOIteratorNext(parentIterator)
            }
        }
        return driver
    }
}

/// rusage 求和回退源(stats readers.swift:448-457 同款读数):全进程
/// proc_pid_rusage 的磁盘字节求和。票 A 高2 起消费心跳中继的快照——心跳
/// 每轮本就带每 pid 磁盘字节,全进程 rusage 循环全仓库只剩 LiveProcessSource
/// 一处,求和零额外系统调用。计数时刻取中继的发布时刻(采到的时刻),不取
/// 读的时刻。30s 低频档;心跳首轮前无数(读失败 → lastGood/占位,首个速率
/// 因此最多晚一档);口径只算用户态进程(不含内核回写),且新进程的终身
/// 累计会整块进账(差分防护钳不住正向跳变)——回退档如实接受,注释在此言明。
struct RusageSumDiskThroughputSource: DiskThroughputSource {
    private let heartbeat: HeartbeatRusageRelay

    /// 注入心跳中继(运行期 = SystemMonitor 持有、Sampler 每轮发布的那一个)。
    init(heartbeat: HeartbeatRusageRelay) {
        self.heartbeat = heartbeat
    }

    /// 低频档(工单原文预案;30 点 × 30s = 15 分钟走势)。
    var cadenceSeconds: TimeInterval { 30 }

    func readCounters() -> DiskIOCounters? {
        guard let latest = heartbeat.latest() else { return nil }
        var readSum: UInt64 = 0
        var writeSum: UInt64 = 0
        for process in latest.snapshot.processes where process.countersAvailable {
            readSum &+= process.diskBytesRead
            writeSum &+= process.diskBytesWritten
        }
        return DiskIOCounters(
            readBytes: readSum, writeBytes: writeSum,
            atUptimeNanos: latest.uptimeNanos
        )
    }
}

/// 吞吐源路径选择(构造期一次探测钉死,探针③结论):IORegistry 命中 → 主路径;
/// 向上遍历失败或键缺失 → rusage 求和回退(两档节奏由各自 cadenceSeconds 体现,
/// 调度器按登记节奏驱动 = spec"调度器体现分档")。回退档的表源由调用方给
/// (心跳中继,票 A 高2)。
enum LiveDiskThroughputSource {
    static func adoptingBestPath(
        fallbackHeartbeat: HeartbeatRusageRelay
    ) -> any DiskThroughputSource {
        let registry = IORegistryDiskThroughputSource()
        // 探针读(结果丢弃):只判路径可用性,基线由首轮正式读另立。
        if registry.readCounters() != nil { return registry }
        return RusageSumDiskThroughputSource(heartbeat: fallbackHeartbeat)
    }
}

// MARK: - Provider(ADR-0004)

/// 磁盘容量 provider(工单 05):低频档 `.every(seconds: 30)`(卷少变,30s
/// 足跟 Finder 对账;30–60s 区间取低值,换卷事件触发留待卷卡后续)。读失败
/// 交付 lastGood,不白屏(ADR-0004);非 APFS 系统(读数恒 nil)整卡占位。
final class DiskCapacityProvider: SensorProvider {
    typealias Reading = DiskCapacityReading

    let cadence: SensorCadence = .every(seconds: 30)

    private let source: any DiskCapacitySource
    private let slot = SensorLastGoodBox<DiskCapacityReading>()

    var lastGood: DiskCapacityReading? { slot.current }

    init(source: any DiskCapacitySource = LiveDiskCapacitySource()) {
        self.source = source
    }

    func snapshot() async -> DiskCapacityReading? {
        guard let raw = source.read(), let reading = DiskCapacity.make(from: raw) else { return nil }
        slot.store(reading)
        return reading
    }
}

/// 磁盘吞吐 provider(工单 05):短档 5s(主路径)或低频档 30s(回退),
/// 节奏随源路径(cadenceSeconds);差分状态与走势由 Accumulator 持有
/// (锁保护——provider 须 Sendable,与 SensorLastGoodBox 同款纪律)。
final class DiskThroughputProvider: SensorProvider {
    typealias Reading = DiskThroughputReading

    var cadence: SensorCadence { .every(seconds: source.cadenceSeconds) }

    private let source: any DiskThroughputSource
    private let accumulator = DiskThroughputAccumulator()
    private let slot = SensorLastGoodBox<DiskThroughputReading>()

    var lastGood: DiskThroughputReading? { slot.current }

    /// 源由调用方选定(SystemMonitor 经 adoptingBestPath 带心跳中继构造)。
    init(source: any DiskThroughputSource) {
        self.source = source
    }

    func snapshot() async -> DiskThroughputReading? {
        guard let counters = source.readCounters() else { return nil }
        let reading = accumulator.record(counters)
        slot.store(reading)
        return reading
    }
}

/// 吞吐差分状态 + 走势环形窗(锁保护的微小盒子):record 折叠
/// "差分 → 追加走势 → 交付读数"三步,基线无论成败都以本轮计数为准
/// (stats samples[id] = (bytes, time) 同款——回退/重置后下一轮自动恢复速率)。
final class DiskThroughputAccumulator: @unchecked Sendable {
    /// 走势窗容量(主路径 5s × 60 = 5 分钟;回退档 30s × 60 = 30 分钟)。
    static let trendCapacity = 60

    private let lock = NSLock()
    private var previous: DiskIOCounters?
    private var readRates = RingSeries<Double>(capacity: DiskThroughputAccumulator.trendCapacity)
    private var writeRates = RingSeries<Double>(capacity: DiskThroughputAccumulator.trendCapacity)

    func record(_ counters: DiskIOCounters) -> DiskThroughputReading {
        lock.lock()
        defer { lock.unlock() }
        let rates = DiskThroughputDiffer.rates(previous: previous, current: counters)
        // 记账增量与差分同防(网络增量同口径):速率非零 = 差分成功轮,
        // 取计数差(differ 的非负守卫保证不回退);速率为零 = 首读/回退/
        // 丢弃轮或真无 IO,增量一律 0——速率与增量同真同零,不会一半一半。
        let readBytesDelta: UInt64
        let writeBytesDelta: UInt64
        if let previous, rates != .zero {
            readBytesDelta = counters.readBytes - previous.readBytes
            writeBytesDelta = counters.writeBytes - previous.writeBytes
        } else {
            readBytesDelta = 0
            writeBytesDelta = 0
        }
        previous = counters
        readRates.append(rates.readBytesPerSecond)
        writeRates.append(rates.writeBytesPerSecond)
        let reads = readRates.values
        let writes = writeRates.values
        return DiskThroughputReading(
            current: rates,
            trend: (0..<reads.count).map { DiskRatePoint(read: reads[$0], write: writes[$0]) },
            readBytesDelta: readBytesDelta,
            writeBytesDelta: writeBytesDelta
        )
    }
}
