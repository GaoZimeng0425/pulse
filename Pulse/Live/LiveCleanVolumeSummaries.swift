import Foundation
import PulseCore

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
            // "/"(SSV 密封系统卷)也算:上面 statfs 的 root 就是它;其余同盘 apfs 卷一并。
            let used = (Int64(fs.f_blocks) - Int64(fs.f_bfree)) * Int64(fs.f_bsize)
            guard used > 0 else { continue }
            out.append(SpaceMapVolumeSummary(
                label: (mountPoint as NSString).lastPathComponent,
                usedBytes: used
            ))
        }

        // SSV 本体("/" 挂载的密封系统卷)单独补上:系统文件所在地,必须进密封块。
        let ssvUsed = (Int64(root.f_blocks) - Int64(root.f_bfree)) * Int64(root.f_bsize)
        if ssvUsed > 0 {
            out.append(SpaceMapVolumeSummary(label: "SSV", usedBytes: ssvUsed))
        }
        return out
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
