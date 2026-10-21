// 探针① purgeable 两口径对照 —— Pulse P1 工单 01(.scratch/p1-history/issues/01-probes.md)
// 问题:调研文档 §5 开放问题 3 —— CSDiskSpaceGetRecoveryEstimate(stats 路径)与
//       CFURL 两 key 差值(petal 路径)在 macOS 26 数值是否一致、哪个与 Finder「可用」一致。
// 来源(均 MIT,翻译对照):
//   stats  Modules/Disk/readers.swift:123-140  CSDiskSpaceGetRecoveryEstimate(原实现缓存 60s,探针不缓存)
//   petal  src/disk.rs:129-163                 important − free 两 key 差值
// 只读、瞬时、无负载。运行:swiftc 01-purgeable-two-sources.swift -o probe01 && ./probe01

import CoreServices
import Foundation

func fsTypeName(_ tuple: (
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar,
    CChar
)) -> String {
    withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// statfs 口径:total=f_blocks、avail=f_bavail(非 root 可用)、used=f_blocks−f_bfree(容器共享口径)
func statfsInfo(_ path: String) -> (total: Int64, used: Int64, avail: Int64, fs: String)? {
    var st = statfs()
    guard statfs(path, &st) == 0 else { return nil }
    let bs = Int64(st.f_bsize)
    return (
        Int64(st.f_blocks) * bs,
        Int64(st.f_blocks - st.f_bfree) * bs,
        Int64(st.f_bavail) * bs,
        fsTypeName(st.f_fstypename)
    )
}

/// stats 路径:recovery estimate(文档原话:"quick, conservative, rough estimate")
func csRecoveryEstimate(_ path: String) -> UInt64 {
    CSDiskSpaceGetRecoveryEstimate(URL(fileURLWithPath: path) as CFURL)
}

/// petal 路径:important − free;读前先清缓存(stats 同款,保证同刻新鲜值)
func cfValues(_ path: String) -> (free: Int64?, important: Int64?) {
    var url = URL(fileURLWithPath: path)
    url.removeAllCachedResourceValues()
    let free: Int64? = ((try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity)
        .map { Int64($0) }
    let important: Int64? = ((try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage).map { Int64($0) }
    return (free, important)
}

func gb(_ b: Int64) -> String {
    String(format: "%.2f GB", Double(b) / 1e9)
}

let mounts = ["/", "/System/Volumes/Data"]
print("uid=\(getuid())(非 root)  探针①:purgeable 两口径同刻对照")
for m in mounts {
    let st = statfsInfo(m)
    let cf = cfValues(m)
    let cs = csRecoveryEstimate(m)
    print("\n== 卷 \(m) (fs=\(st?.fs ?? "?")) ==")
    if let st {
        print(
            "  statfs       total=\(gb(st.total))  used(f_blocks-f_bfree)=\(gb(st.used))  avail(f_bavail)=\(gb(st.avail))"
        )
    }
    print("  CSDiskSpaceGetRecoveryEstimate          = \(gb(Int64(cs)))   (stats 路径,仅估计值)")
    if let free = cf.free, let imp = cf.important {
        let purgeable = max(0, imp - free)
        print("  CFURL AvailableCapacity(free)           = \(gb(free))   (petal 的 free 口径)")
        print("  CFURL AvailableCapacityForImportantUsage= \(gb(imp))   (petal 注释:即 Finder「可用」)")
        print("  ⇒ petal 两 key 差值 purgeable            = \(gb(purgeable))")
        if let st {
            print("  ⇒ stats 口径 free = f_bavail + estimate = \(gb(st.avail + Int64(cs)))  (与上行 important 对照)")
            print(
                "  ⇒ 两口径 estimate vs 两 key 差值          = \(gb(Int64(cs))) vs \(gb(purgeable))  Δ=\(gb(abs(Int64(cs) - purgeable)))"
            )
        }
    } else {
        print("  CFURL 读数失败 free=\(String(describing: cf.free)) important=\(String(describing: cf.important))")
    }
}

print("\nFinder 对照提示:访达对启动盘显示的「可用空间」按十进制 GB 报数;")
print("与上行 importantUsage 一致则 petal 口径即 Finder 口径,与 f_bavail 一致则裸 statfs 口径即 Finder 口径。")
