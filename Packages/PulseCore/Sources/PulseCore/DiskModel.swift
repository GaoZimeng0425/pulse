import Darwin
import Foundation

// 磁盘的纯值层:容量对账、本地快照记录解析、吞吐差分与累计、源接缝与 rusage 求和回退源。getattrlist / IORegistry / fs_snapshot_list 适配器在 app target(DiskSensor.swift)。

/// 单卷已用明细行(工单 05 各卷明细):label 是展示名(固定标签或挂载点 basename)。
public struct DiskVolumeUsage: Equatable, Identifiable, Sendable {
    public let label: String
    /// 挂载点(明细行的身份的一部分;展示不直接用)。
    public let mountPoint: String
    public let usedBytes: UInt64

    public var id: String {
        mountPoint
    }

    public init(label: String, mountPoint: String, usedBytes: UInt64) {
        self.label = label
        self.mountPoint = mountPoint
        self.usedBytes = usedBytes
    }
}

/// 磁盘容量卡读数(工单 05 ①②③④):容器级对账(Finder 口径)+ 可清除 +
/// Data 卷与其余卷明细 + 本地快照列表。
public struct DiskCapacityReading: Equatable, Sendable {
    /// 卷的 Finder 名("Macintosh HD");读不到为 nil(标题显示占位)。
    public let volumeName: String?
    /// 容器总容量(f_blocks × f_bsize)。
    public let containerTotalBytes: UInt64
    /// 容器已用((f_blocks − f_bfree) × f_bsize)——与 Finder「已用」同口径
    /// (裸 statfs 的单卷空闲在 APFS 上是容器共享口径,不可信,petal 注释)。
    public let containerUsedBytes: UInt64
    /// 实际可用 = importantUsage(Finder「可用」口径,探针①分毫不差);
    /// nil = 读不到,显示占位。
    public let availableForImportantUsageBytes: Int64?
    /// 可清除空间 = 两 key 差值(petal:important − free,max 0)——TM 本地快照、
    /// iCloud 可回源文件、系统可清缓存等系统自行腾挪的部分;与「实际可用」
    /// 分开文案(petal 注释:它已计入 used,又在 important 口径里被放开)。
    /// nil = 任一 key 读不到,不伪造。
    public let purgeableBytes: Int64?
    /// Data 卷(用户文件与 App;petal 的扫描锚点,明细首位)。
    public let dataVolume: DiskVolumeUsage
    /// 其余已挂载同容器卷(密封系统卷 macOS / Preboot / 虚拟内存 / 系统更新…)。
    public let otherVolumes: [DiskVolumeUsage]
    /// 对账差额:未挂载卷(通常是 Recovery)与容器元数据(petal "Other volumes"
    /// 兜底,必做——否则各卷之和与容器总数对不上)。accounted ≥ used 时为 nil。
    public let unaccounted: DiskVolumeUsage?
    /// 本地快照列表(Data 卷)。
    public let snapshots: DiskSnapshotListing

    /// 已对账字节合计(不变式锚点:== containerUsedBytes,单测钉死)。
    public var accountedBytes: UInt64 {
        dataVolume.usedBytes
            + otherVolumes.reduce(0) { $0 + $1.usedBytes }
            + (unaccounted?.usedBytes ?? 0)
    }

    public init(
        volumeName: String? = nil,
        containerTotalBytes: UInt64,
        containerUsedBytes: UInt64,
        availableForImportantUsageBytes: Int64? = nil,
        purgeableBytes: Int64? = nil,
        dataVolume: DiskVolumeUsage,
        otherVolumes: [DiskVolumeUsage],
        unaccounted: DiskVolumeUsage? = nil,
        snapshots: DiskSnapshotListing
    ) {
        self.volumeName = volumeName
        self.containerTotalBytes = containerTotalBytes
        self.containerUsedBytes = containerUsedBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.purgeableBytes = purgeableBytes
        self.dataVolume = dataVolume
        self.otherVolumes = otherVolumes
        self.unaccounted = unaccounted
        self.snapshots = snapshots
    }
}

/// 容量对账纯逻辑(spec 测试缝):源给原始读数,这里折叠出展示读数。
public enum DiskCapacity {
    /// Data 卷挂载点(petal 识别锚点,disk.rs:228-232;Live 源的快照目标同此)。
    public static let dataVolumeMountPoint = "/System/Volumes/Data"

    /// 设备名 → APFS 容器号(petal container_of,disk.rs:188-194):
    /// "/dev/disk3s1s1" → "disk3";"map auto_home" 之类非 /dev/ 设备返回 nil。
    public static func containerOf(device: String) -> String? {
        guard let name = device.removePrefix("/dev/"), name.hasPrefix("disk") else { return nil }
        let digits = name.dropFirst(4)
        let end = digits.firstIndex(where: { !$0.isNumber }) ?? digits.endIndex
        return String(name[..<end]).isEmpty ? nil : "disk" + String(digits[..<end])
    }

    /// 已知挂载点的固定标签(petal disk.rs:226-237),其余取挂载点 basename。
    public static func label(forMountPoint mountPoint: String) -> String {
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
    public static func make(from raw: DiskCapacityRawReading) -> DiskCapacityReading? {
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

/// 一个 APFS 快照:卷在某个时点的冻结副本(petal Snapshot,disk.rs:40-47)。
/// 它占着的块在快照删除前不释放——之后删除/改动的文件空间不会回来。
public struct DiskSnapshot: Equatable, Identifiable, Sendable {
    public let name: String
    /// Unix 秒(petal created)。
    public let createdEpoch: Int64

    public var id: String {
        name
    }

    public var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdEpoch))
    }

    /// 本地 Time Machine 快照(macOS 自留 24 小时;petal is_time_machine,disk.rs:55-57)。
    public var isTimeMachine: Bool {
        name.hasPrefix("com.apple.TimeMachine.")
    }

    /// 来源识别(petal kind,disk.rs:62-69):TM / macOS 更新 / CCC / 其他 App。
    public var kindTitle: String {
        switch true {
        case isTimeMachine: "Time Machine"
        case name.hasPrefix("com.apple.os.update"): "macOS 更新"
        case name.hasPrefix("com.bombich.ccc"): "Carbon Copy Cloner"
        default: "其他应用"
        }
    }

    public init(name: String, createdEpoch: Int64) {
        self.name = name
        self.createdEpoch = createdEpoch
    }
}

/// 快照列表读数:listing(含空 = 真的没有)或 unavailable(读不到,占位不伪造)。
public enum DiskSnapshotListing: Equatable, Sendable {
    /// rc < 0(未来权限收紧 / EACCES)或 open 失败或目标非 APFS:不可用。
    case unavailable
    case listing([DiskSnapshot])
}

/// fs_snapshot_list 单条记录解析(petal parse_snapshot,disk.rs:105-123;记录
/// 布局经探针②实测钉死):[u32 总长][attribute_set_t 20B][attrreference_t 8B:
/// 名称相对偏移(i32)+ 名称长度(u32,含结尾 NUL)][timespec 16B]…,名称数据按
/// 偏移相对 attrreference_t 起始定位,取 length−1 去掉 NUL。
public enum DiskSnapshotRecord {
    /// 最短合法记录 = 4 + attribute_set_t + attrreference_t + timespec(16)。
    public static let minimumLength = 4 + MemoryLayout<attribute_set_t>.size
        + MemoryLayout<attrreference_t>.size + 16

    private static let nameReferenceOffset = 4 + MemoryLayout<attribute_set_t>.size
    private static let timeOffset = nameReferenceOffset + MemoryLayout<attrreference_t>.size

    /// 解析单条记录;截断/越界记录返回 nil(跳过,不误读,petal 同款)。
    public static func parse(_ record: some Sequence<UInt8>) -> DiskSnapshot? {
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
    public static func parseBuffer(_ buffer: [UInt8], count: Int) -> [DiskSnapshot] {
        var snapshots: [DiskSnapshot] = []
        var at = 0
        for _ in 0 ..< max(0, count) {
            guard at + 4 <= buffer.count else { break }
            let length = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)
            })
            guard length >= minimumLength, at + length <= buffer.count else { break }
            if let snapshot = parse(buffer[at ..< (at + length)]) {
                snapshots.append(snapshot)
            }
            at += length
        }
        return snapshots.sorted { $0.createdEpoch < $1.createdEpoch }
    }
}

/// 系统级累计 IO 计数(块存储驱动内核账 / rusage 求和共用形状)。
public struct DiskIOCounters: Equatable, Sendable {
    public let readBytes: UInt64
    public let writeBytes: UInt64
    /// 采样时刻(mach 绝对时间纳秒;只用于算 elapsed,跨源不可比)。
    public let atUptimeNanos: UInt64

    public init(readBytes: UInt64, writeBytes: UInt64, atUptimeNanos: UInt64) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.atUptimeNanos = atUptimeNanos
    }
}

/// 一轮差分出的读写速率(字节/秒)。
public struct DiskRates: Equatable, Sendable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public static let zero = DiskRates(readBytesPerSecond: 0, writeBytesPerSecond: 0)

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

/// 走势图的单点(读 + 写)。
public struct DiskRatePoint: Equatable, Sendable {
    public let read: Double
    public let write: Double

    public init(read: Double, write: Double) {
        self.read = read
        self.write = write
    }
}

/// 磁盘吞吐读数(工单 05 ⑤):当前速率 + 近窗走势(旧 → 新)。
public struct DiskThroughputReading: Equatable, Sendable {
    public let current: DiskRates
    public let trend: [DiskRatePoint]
    /// 本轮记账增量(字节;历史落库消费,UI 形状不读,默认 0 让展示构造方
    /// 免于关心):差分成功轮 = 计数差,首读/回退/丢弃轮 = 0——与网络增量
    /// 同口径,落库只信增量,不信"速率 × 窗宽"折算。
    public var readBytesDelta: UInt64 = 0
    public var writeBytesDelta: UInt64 = 0

    /// 图表口径:读 + 写合计流量。
    public var totalBytesPerSecond: Double {
        current.readBytesPerSecond + current.writeBytesPerSecond
    }

    public init(
        current: DiskRates,
        trend: [DiskRatePoint],
        readBytesDelta: UInt64 = 0,
        writeBytesDelta: UInt64 = 0
    ) {
        self.current = current
        self.trend = trend
        self.readBytesDelta = readBytesDelta
        self.writeBytesDelta = writeBytesDelta
    }
}

/// 吞吐差分(stats ActivityReader.activity + elapsed 防护,readers.swift:267-280):
/// 差分三件防护——首读置零(只立基线)、计数回退/重置钳零并重立基线、
/// elapsed 非有限或 ≤0 钳零。
public enum DiskThroughputDiffer {
    /// 单轮速率上限(字节/秒):超过即视为计数跳变、整轮作废(不出速率、不进记账)。
    /// 现役 NVMe 顶到 ~7 GB/s,20 GB/s 留足余量;主要防 rusage 求和回退档——进程计数
    /// 上轮缺席、本轮带终身累计进账时和值一轮跳上百 GB(arch-review-2026-10-18/03 甲8,
    /// 参照 NetworkRateDiffer 的跳变防护)。
    public static let maximumBytesPerSecond: Double = 20_000_000_000

    public static func rates(previous: DiskIOCounters?, current: DiskIOCounters) -> DiskRates {
        guard let previous else { return .zero } // 首读:立基线,不出速率
        // 计数回退(重置/换盘/回绕)→ 本轮 0,基线以本轮为准(见 Accumulator)。
        guard current.readBytes >= previous.readBytes,
              current.writeBytes >= previous.writeBytes,
              current.atUptimeNanos > previous.atUptimeNanos else { return .zero }
        let elapsed = Double(current.atUptimeNanos - previous.atUptimeNanos) / 1_000_000_000
        guard elapsed > 0, elapsed.isFinite else { return .zero }
        let read = Double(current.readBytes - previous.readBytes) / elapsed
        let write = Double(current.writeBytes - previous.writeBytes) / elapsed
        guard read.isFinite, write.isFinite, read <= maximumBytesPerSecond,
              write <= maximumBytesPerSecond else { return .zero }
        return DiskRates(readBytesPerSecond: read, writeBytesPerSecond: write)
    }
}

/// 挂载点原始行(getmntinfo 全表,不做任何过滤——过滤是对账纯逻辑)。
public struct MountedVolumeRaw: Equatable, Sendable {
    public let mountPoint: String
    /// f_mntfromname 原样("/dev/disk3s1s1"、"map auto_home"…)。
    public let device: String
    /// f_fstypename("apfs"…)。
    public let fileSystem: String
    /// getattrlist ATTR_VOL_SPACEUSED;nil = 该卷读失败。
    public let usedBytes: UInt64?

    public init(mountPoint: String, device: String, fileSystem: String, usedBytes: UInt64? = nil) {
        self.mountPoint = mountPoint
        self.device = device
        self.fileSystem = fileSystem
        self.usedBytes = usedBytes
    }
}

/// 磁盘容量源原始读数(OS 边界形状,未加工;nil 字段 = 该项读不到)。
public struct DiskCapacityRawReading: Sendable {
    /// 根卷设备名(statfs("/").f_mntfromname)。
    public let rootDevice: String
    public let containerTotalBytes: UInt64
    public let containerUsedBytes: UInt64
    /// CFURL importantUsage(Finder 口径);nil = 读不到。
    public let availableForImportantUsage: Int64?
    /// CFURL AvailableCapacity(free 口径);nil = 读不到。
    public let availableCapacity: Int64?
    /// 卷的 Finder 名;nil = 读不到。
    public let volumeName: String?
    /// getmntinfo 全表(不过滤)。
    public let mountedVolumes: [MountedVolumeRaw]
    /// Data 卷快照列表(Data 卷缺席时 unavailable)。
    public let snapshots: DiskSnapshotListing

    public init(
        rootDevice: String,
        containerTotalBytes: UInt64,
        containerUsedBytes: UInt64,
        availableForImportantUsage: Int64? = nil,
        availableCapacity: Int64? = nil,
        volumeName: String? = nil,
        mountedVolumes: [MountedVolumeRaw],
        snapshots: DiskSnapshotListing
    ) {
        self.rootDevice = rootDevice
        self.containerTotalBytes = containerTotalBytes
        self.containerUsedBytes = containerUsedBytes
        self.availableForImportantUsage = availableForImportantUsage
        self.availableCapacity = availableCapacity
        self.volumeName = volumeName
        self.mountedVolumes = mountedVolumes
        self.snapshots = snapshots
    }
}

/// 磁盘容量源接缝:一次 read 拿全部原始字段,缝上是纯逻辑。
public protocol DiskCapacitySource: Sendable {
    /// nil = 连根卷都读不到(容量卡整卡占位)。
    func read() -> DiskCapacityRawReading?
}

/// 磁盘吞吐源接缝:读累计字节计数,差分与防护全在缝上。
public protocol DiskThroughputSource: Sendable {
    /// nil = 本次读不到(路径失效/键缺失),调度器跳过本轮交付。
    func readCounters() -> DiskIOCounters?
    /// 建议节奏秒数:IORegistry 主路径 5s 短档;rusage 求和回退 30s 低频档
    /// (每进程一次系统调用的成本,工单原文预案)。
    var cadenceSeconds: TimeInterval { get }
}

/// rusage 求和回退源(stats readers.swift:448-457 同款读数):全进程
/// proc_pid_rusage 的磁盘字节求和。票 A 高2 起消费心跳中继的快照——心跳
/// 每轮本就带每 pid 磁盘字节,全进程 rusage 循环全仓库只剩 LiveProcessSource
/// 一处,求和零额外系统调用。计数时刻取中继的发布时刻(采到的时刻),不取
/// 读的时刻。30s 低频档;心跳首轮前无数(读失败 → lastGood/占位,首个速率
/// 因此最多晚一档);口径只算用户态进程(不含内核回写),且新进程的终身
/// 累计会整块进账(差分防护钳不住正向跳变)——回退档如实接受,注释在此言明。
public struct RusageSumDiskThroughputSource: DiskThroughputSource {
    private let heartbeat: HeartbeatRusageRelay

    /// 注入心跳中继(运行期 = SystemMonitor 持有、Sampler 每轮发布的那一个)。
    public init(heartbeat: HeartbeatRusageRelay) {
        self.heartbeat = heartbeat
    }

    /// 低频档(工单原文预案;30 点 × 30s = 15 分钟走势)。
    public var cadenceSeconds: TimeInterval {
        30
    }

    public func readCounters() -> DiskIOCounters? {
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

/// 吞吐差分状态 + 走势环形窗(锁保护的微小盒子):record 折叠
/// "差分 → 追加走势 → 交付读数"三步,基线无论成败都以本轮计数为准
/// (stats samples[id] = (bytes, time) 同款——回退/重置后下一轮自动恢复速率)。
public final class DiskThroughputAccumulator: @unchecked Sendable {
    /// 走势窗容量(主路径 5s × 60 = 5 分钟;回退档 30s × 60 = 30 分钟)。
    public static let trendCapacity = 60

    private let lock = NSLock()
    private var previous: DiskIOCounters?
    private var readRates = RingSeries<Double>(capacity: DiskThroughputAccumulator.trendCapacity)
    private var writeRates = RingSeries<Double>(capacity: DiskThroughputAccumulator.trendCapacity)

    public func record(_ counters: DiskIOCounters) -> DiskThroughputReading {
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
            trend: (0 ..< reads.count).map { DiskRatePoint(read: reads[$0], write: writes[$0]) },
            readBytesDelta: readBytesDelta,
            writeBytesDelta: writeBytesDelta
        )
    }

    public init() {}
}

private extension String {
    /// 前缀剥离(找不到前缀返回 nil)——container_of 的第一步。
    public func removePrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
