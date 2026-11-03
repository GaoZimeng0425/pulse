import Foundation
import PulseCore

// attr 常量(sys/attr.h;SDK enum 不进 Swift 模块,DiskSensor 同款硬编码)
private let attrBitmapCount = UInt16(5)
private let attrVolInfo: attrgroup_t = 0x8000_0000
private let attrVolSpaceUsed: attrgroup_t = 0x0080_0000

// MARK: - Live 卷级摘要(方案 A:只读系统卷不逐文件走)

/// 非数据系统卷的卷级字节(statfs):SSV(/)、Preboot、VM、Update、Recovery 等同
/// 物理盘上的 apfs 卷,每卷一个 (f_blocks − f_bfree) × f_bsize。外置盘/异物理盘
/// 不计(空间地图的「整卷」= 内置盘口径,票 10 记档)。getmntinfo 快照 + 每卷一次
/// statfs,微秒级——扫描收尾时取一次即可。
struct LiveCleanVolumeSummaries {
    /// 排除 Data 卷本身(它走文件级扫描)。
    var excludedMounts: Set<String> = [SpaceMapTree.dataVolumePath]

    /// 同物理盘的非数据 apfs 卷摘要;读不到挂载表返回 [](地图就不出密封块,不伪造)。
    func internalSystemVolumes() -> [SpaceMapVolumeSummary] {
        var root = statfs()
        guard statfs("/", &root) == 0 else { return [] }
        // 根设备 "/dev/disk3s1s1" → 物理盘前缀 "/dev/disk3"(同盘判定)。
        guard let diskPrefix = Self.physicalDiskPrefix(of: Self.string(root.f_mntfromname)) else {
            return []
        }

        var mountsPointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mountsPointer, MNT_NOWAIT)
        guard count > 0, let mounts = mountsPointer else { return [] }

        var out: [SpaceMapVolumeSummary] = []
        for index in 0 ..< Int(count) {
            let fs = mounts[index]
            let mountPoint = Self.string(fs.f_mntonname)
            let device = Self.string(fs.f_mntfromname)
            let fileSystem = Self.string(fs.f_fstypename)
            guard fileSystem == "apfs",
                  device.hasPrefix(diskPrefix),
                  mountPoint != "/",
                  !excludedMounts.contains(mountPoint)
            else { continue }
            // 每卷精确已用:getattrlist ATTR_VOL_SPACEUSED(DiskSensor/petal volume_used
            // 同源)。**不能用 statfs 的 f_blocks−f_bfree**:APFS 各卷共享容器,这两个数
            // 是容器级的——每卷都算出「整个容器已用」,六卷叠出 2.2TB 假账(2026-11-03
            // 用户实拍 2461GB 实锤)。读失败跳过该卷(不伪造)。
            guard let used = Self.volumeUsedBytes(atPath: mountPoint), used > 0 else { continue }
            out.append(SpaceMapVolumeSummary(
                label: (mountPoint as NSString).lastPathComponent,
                usedBytes: Int64(used)
            ))
        }

        // SSV 本体("/" 挂载的密封系统卷):系统文件所在地,必须进密封块。
        if let ssvUsed = Self.volumeUsedBytes(atPath: "/"), ssvUsed > 0 {
            out.append(SpaceMapVolumeSummary(label: "SSV", usedBytes: Int64(ssvUsed)))
        }
        return out
    }

    /// 每卷精确已用(getattrlist;回包 = [u32 总长][off_t 已用 @ 偏移 4],DiskSensor 同款)。
    private static func volumeUsedBytes(atPath path: String) -> UInt64? {
        var attrs = attrlist(
            bitmapcount: attrBitmapCount, reserved: 0,
            commonattr: 0, volattr: attrVolInfo | attrVolSpaceUsed,
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

    /// "/dev/disk3s1s1" → "/dev/disk3";对不上模式(如 map 设备)返回 nil。
    private static func physicalDiskPrefix(of device: String) -> String? {
        guard device.hasPrefix("/dev/") else { return nil }
        let rest = String(device.dropFirst("/dev/".count))
        guard let range = rest.range(of: #"^disk\d+"#, options: .regularExpression) else {
            return nil
        }
        return "/dev/" + rest[range]
    }

    /// C 定长字符数组(f_mntonname 等)→ String(DiskSensor 同款)。
    private static func string(_ chars: some Any) -> String {
        withUnsafeBytes(of: chars) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
