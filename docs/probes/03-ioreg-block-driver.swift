// 探针③ IORegistry 块存储驱动统计对 NVMe 的覆盖 —— Pulse P1 工单 01(.scratch/p1-history/issues/01-probes.md)
// 问题:调研文档 §2.1 vs §4 —— stats 的 IORegistry 差分路径(kIOBlockStorageDriverStatisticsKey)
//       在本机(Apple Silicon NVMe)能否拿到系统级 Bytes Read/Written(含内核 IO,
//       不受 rusage 只算用户进程的口径限制),作为 P2/P1 吞吐源备选的可行性。
// 来源(MIT,参考):stats Modules/Disk/readers.swift:248-257(Statistics 字典差分)、:284-321(向上找 driver)。
// 键名照 SDK IOKit/storage/IOBlockStorageDriver.h:kIOBlockStorageDriverStatisticsBytesWrittenKey
//   = "Bytes (Write)"(不是 "Written")。
// 只读、瞬时(两次采样间隔 2s,无负载)。运行:swiftc 03-ioreg-block-driver.swift -o probe03 && ./probe03

import Foundation
import IOKit

let driverClass = "IOBlockStorageDriver"
let mediaClass = "IOMedia"
let statsKey = "Statistics"
let bytesReadKey = "Bytes (Read)"
let bytesWrittenKey = "Bytes (Write)"

func className(_ entry: io_registry_entry_t) -> String {
    var buf = [CChar](repeating: 0, count: 128)
    guard IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS else { return "?" }
    return String(cString: buf)
}

func mediaBSDNames(_ driver: io_registry_entry_t) -> [String] {
    var it: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var out: [String] = []
    var child = IOIteratorNext(it)
    while child != 0 {
        if IOObjectConformsTo(child, mediaClass) != 0,
           let prop = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? String {
            out.append(prop)
        }
        IOObjectRelease(child)
        child = IOIteratorNext(it)
    }
    return out
}

func parentClass(_ driver: io_registry_entry_t) -> String {
    var it: io_iterator_t = 0
    guard IORegistryEntryGetParentIterator(driver, kIOServicePlane, &it) == KERN_SUCCESS else { return "?" }
    defer { IOObjectRelease(it) }
    let parent = IOIteratorNext(it)
    guard parent != 0 else { return "?" }
    defer { IOObjectRelease(parent) }
    return className(parent)
}

func counters(_ driver: io_registry_entry_t) -> [String: UInt64] {
    guard let dict = IORegistryEntryCreateCFProperty(driver, statsKey as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any] else { return [:] }
    var out: [String: UInt64] = [:]
    for (k, v) in dict where k == bytesReadKey || k == bytesWrittenKey {
        if let n = v as? NSNumber {
            out[k] = n.uint64Value
        }
    }
    return out
}

func gb(_ b: UInt64) -> String {
    String(format: "%.2f GB", Double(b) / 1e9)
}

/// 根卷的 BSD 名,用于指认「哪条 driver 覆盖了启动盘」
func rootBSDName() -> String {
    var st = statfs()
    guard statfs("/", &st) == 0 else { return "?" }
    return withUnsafeBytes(of: st.f_mntfromname) {
        String(cString: $0.bindMemory(to: CChar.self).baseAddress!).replacingOccurrences(of: "/dev/", with: "")
    }
}

let match = IOServiceMatching(driverClass)
var iterator: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
    print("IOServiceGetMatchingServices 失败")
    exit(1)
}

defer { IOObjectRelease(iterator) }

print("uid=\(getuid())(非 root)  探针③:IORegistry 块存储驱动统计覆盖(根卷 BSD=\(rootBSDName()))")
var drivers: [(entry: io_registry_entry_t, cls: String, media: [String])] = []
var entry = IOIteratorNext(iterator)
while entry != 0 {
    drivers.append((entry, className(entry), mediaBSDNames(entry)))
    entry = IOIteratorNext(iterator)
}

print("共 \(drivers.count) 个 \(driverClass) 实例")

func snapshotAll() -> [(idx: Int, cls: String, media: [String], parent: String, c: [String: UInt64])] {
    drivers.enumerated().map { i, d in
        (i, d.cls, d.media, parentClass(d.entry), counters(d.entry))
    }
}

let root = rootBSDName()
let first = snapshotAll()
for s in first {
    let rootMark = s.media.contains(root) ? "  ← 启动盘" : ""
    let mediaStr = s.media.isEmpty ? "(无 IOMedia 子节点)" : s.media.joined(separator: ",")
    let br = s.c[bytesReadKey].map(gb) ?? "缺失"
    let bw = s.c[bytesWrittenKey].map(gb) ?? "缺失"
    print("  [\(s.idx)] \(s.cls)  父=\(s.parent)  media=\(mediaStr)\(rootMark)")
    print("       Bytes(Read)=\(br)  Bytes(Write)=\(bw)")
}

sleep(2)
let second = snapshotAll()
print("\n2 秒后差分(计数器是否在走;负值 = 回绕/重置,按 stats 规则钳 0):")
var anyDelta = false
for s in second {
    guard let p = first.first(where: { $0.idx == s.idx }) else { continue }
    let dr = s.c[bytesReadKey].flatMap { c -> UInt64? in p.c[bytesReadKey].map { c >= $0 ? c - $0 : 0 } }
    let dw = s.c[bytesWrittenKey].flatMap { c -> UInt64? in p.c[bytesWrittenKey].map { c >= $0 ? c - $0 : 0 } }
    if (dr ?? 0) + (dw ?? 0) > 0 {
        anyDelta = true
    }
    print("  [\(s.idx)] \(s.cls): Δread=\(dr.map { String($0) } ?? "?")B  Δwrite=\(dw.map { String($0) } ?? "?")B")
}

print(anyDelta ? "\n计数器在走:IORegistry 路径可作系统级吞吐源(含内核 IO)。" : "\n2s 内无增量(机器空闲也常见),但累计值非零即说明路径可用;差分逻辑见 stats:248-257。")

/// stats 同款第二段:从启动卷 IOMedia(BSD=disk3s1s1)沿父链向上找 IOBlockStorageDriver,
/// 验证"卷 → driver → Statistics"的实装遍历(stats-ref Modules/Disk/readers.swift:284-321 简化版)
func findDriverForBSD(_ bsd: String) -> io_registry_entry_t? {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(mediaClass), &it) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(it) }
    var media: io_registry_entry_t = 0
    var m = IOIteratorNext(it)
    while m != 0 {
        if (IORegistryEntryCreateCFProperty(m, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) == bsd {
            media = m
            break
        }
        IOObjectRelease(m)
        m = IOIteratorNext(it)
    }
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    // 逐层向上,环检测照 stats(visited ≤ 256)
    var frontier: [io_registry_entry_t] = [media]
    var visited: Set<UInt64> = []
    var driver: io_registry_entry_t?
    defer { frontier.forEach { IOObjectRelease($0) } }
    var i = 0
    while i < frontier.count {
        let e = frontier[i]
        i += 1
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(e, &id) == KERN_SUCCESS else { return nil }
        guard visited.insert(id).inserted, visited.count <= 256 else { continue }
        if IOObjectConformsTo(e, driverClass) != 0 {
            IOObjectRetain(e)
            driver = e
            continue // 不 break:确认唯一后仍要遍历完(与 stats 一致)
        }
        var pit: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(e, kIOServicePlane, &pit) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(pit) }
        var p = IOIteratorNext(pit)
        while p != 0 {
            frontier.append(p)
            p = IOIteratorNext(pit)
        }
    }
    return driver
}

print("\nstats 同款遍历:启动卷 \(rootBSDName()) → 向上找块驱动")
if let d = findDriverForBSD(rootBSDName()) {
    defer { IOObjectRelease(d) }
    let c = counters(d)
    print("  命中 driver=\(className(d))  父=\(parentClass(d))")
    print("  Bytes(Read)=\(c[bytesReadKey].map(gb) ?? "缺失")  Bytes(Write)=\(c[bytesWrittenKey].map(gb) ?? "缺失")")
    print(c[bytesReadKey] != nil ? "  → 卷级到驱动的映射链可用,吞吐差分可按此遍历实装。" : "  → 命中驱动但 Statistics 缺关键键,需回退。")
} else {
    print("  未命中:向上遍历失败,吞吐源需回退 rusage 求和。")
}
