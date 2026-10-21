import Foundation
import PulseCore

/// 磁盘合成夹具:核心包 DiskModelTests 与 app 侧 DiskSensorTests 共用(p1-history/05)。
public enum DiskFixture {
    /// 合成原始读数:root = disk3 的 APFS 容器,含 Data/macOS/VM/Preboot 四卷
    /// (已用合计 accounted),外加一个 disk5 异容器卷、一个非 apfs 卷、一个
    /// getattrlist 失败(nil usedBytes)的同容器卷——后三者必须被过滤/跳过。
    public static func raw(
        containerUsed: UInt64 = 300_000_000_000,
        dataUsed: UInt64 = 240_000_000_000,
        macOSUsed: UInt64 = 15_000_000_000,
        vmUsed: UInt64 = 25_000_000_000,
        prebootUsed: UInt64 = 10_000_000_000,
        unmountedRemainder: UInt64 = 10_000_000_000,
        important: Int64? = 209_550_000_000,
        free: Int64? = 202_940_000_000,
        rootDevice: String = "/dev/disk3s1s1",
        includeDataVolume: Bool = true
    ) -> DiskCapacityRawReading {
        func volume(_ mount: String, _ device: String, fs: String = "apfs", used: UInt64?) -> MountedVolumeRaw {
            MountedVolumeRaw(mountPoint: mount, device: device, fileSystem: fs, usedBytes: used)
        }
        var mounted: [MountedVolumeRaw] = [
            volume("/", rootDevice, used: macOSUsed),
            volume("/System/Volumes/VM", "/dev/disk3s3", used: vmUsed),
            volume("/System/Volumes/Preboot", "/dev/disk3s2", used: prebootUsed),
            volume("/Volumes/外置", "/dev/disk5s1", used: 999), // 异容器:过滤
            volume("/opt/homebrew", "map auto_home", fs: "autofs", used: nil), // 非 apfs:过滤
            volume("/System/Volumes/Update", "/dev/disk3s4", used: nil), // 同容器读失败:跳过
        ]
        if includeDataVolume {
            mounted.insert(volume("/System/Volumes/Data", "/dev/disk3s5", used: dataUsed), at: 0)
        }
        return DiskCapacityRawReading(
            rootDevice: rootDevice,
            containerTotalBytes: containerUsed + unmountedRemainder + 500_000_000_000,
            containerUsedBytes: containerUsed,
            availableForImportantUsage: important,
            availableCapacity: free,
            volumeName: "Macintosh HD",
            mountedVolumes: mounted,
            snapshots: .listing([
                DiskSnapshot(name: "com.apple.os.update-26.1", createdEpoch: 1_760_000_000),
                DiskSnapshot(
                    name: "com.apple.TimeMachine.2026-10-15-030000.local",
                    createdEpoch: 1_760_500_000
                ),
            ])
        )
    }

    public static func counters(read: UInt64, write: UInt64, uptime: UInt64) -> DiskIOCounters {
        DiskIOCounters(readBytes: read, writeBytes: write, atUptimeNanos: uptime)
    }
}
