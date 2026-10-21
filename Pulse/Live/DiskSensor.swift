import Darwin
import Foundation
import IOKit
import PulseCore

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

// MARK: - sys/attr.h 常量(C 宏不进 Swift,照 SDK 头手抄,探针②同款)

private let ATTR_BIT_MAP_COUNT = 5
private let ATTR_CMN_NAME: attrgroup_t = 0x0000_0001
private let ATTR_CMN_CRTIME: attrgroup_t = 0x0000_0200
private let ATTR_CMN_RETURNED_ATTRS: attrgroup_t = 0x8000_0000
private let ATTR_VOL_INFO: attrgroup_t = 0x8000_0000
private let ATTR_VOL_SPACEUSED: attrgroup_t = 0x0080_0000

/// sys/snapshot.h 不在 Swift Darwin 模块面里,手写声明(探针②同款)。
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
        let free = freeValues.flatMap(\.volumeAvailableCapacity).map(Int64.init)
        let important = importantValues.flatMap(\.volumeAvailableCapacityForImportantUsage)
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
    private static func cString(_ chars: some Any) -> String {
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
        if lastResult < 0, collected.isEmpty {
            return .unavailable
        }
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
    var cadenceSeconds: TimeInterval {
        5
    }

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
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parentIterator) == KERN_SUCCESS
            else { return nil }
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
        if registry.readCounters() != nil {
            return registry
        }
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

    var lastGood: DiskCapacityReading? {
        slot.current
    }

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

    var cadence: SensorCadence {
        .every(seconds: source.cadenceSeconds)
    }

    private let source: any DiskThroughputSource
    private let accumulator = DiskThroughputAccumulator()
    private let slot = SensorLastGoodBox<DiskThroughputReading>()

    var lastGood: DiskThroughputReading? {
        slot.current
    }

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
