// 探针② fs_snapshot_list 免 root 可列 —— Pulse P1 工单 01(.scratch/p1-history/issues/01-probes.md)
// 问题:调研文档 §5 开放问题 4 —— macOS 26 上 fs_snapshot_list 是否仍免 root 可列;
//       attrlist 缺 ATTR_CMN_RETURNED_ATTRS 是否如 petal 注释所言 EINVAL(负对照)。
// 来源(MIT,翻译):petal src/disk.rs:75-107(snapshots)、:129-146(read_u32/parse_snapshot)。
// 记录布局(实测):[u32 总长][attribute_set_t 20B][attrreference_t 8B(名称 offset+length)][timespec 16B]…
//   名称数据按 attr_dataoffset 相对 attrreference_t 起始定位,长度含结尾 NUL,故取 length−1。
// 只读、瞬时、无负载。运行:swiftc 02-fs-snapshot-list.swift -o probe02 && ./probe02

import Darwin
import Foundation

// sys/snapshot.h 不在 Swift Darwin 模块面里,手写声明(与 petal 在 Rust 的 extern 同理)
@_silgen_name("fs_snapshot_list")
func fs_snapshot_list(_ dirfd: Int32, _ alist: UnsafeMutablePointer<attrlist>?, _ buf: UnsafeMutableRawPointer?, _ size: Int, _ flags: UInt32) -> Int32

// sys/attr.h 的 C 宏不进 Swift,照 SDK 头手抄(/usr/include/sys/attr.h:91,409,418,456)
let ATTR_BIT_MAP_COUNT = 5
let ATTR_CMN_NAME: attrgroup_t = 0x00000001
let ATTR_CMN_CRTIME: attrgroup_t = 0x00000200
let ATTR_CMN_RETURNED_ATTRS: attrgroup_t = 0x80000000

struct Snap { let name: String; let created: Int64 }

func kind(_ name: String) -> String {
    if name.hasPrefix("com.apple.TimeMachine.") { return "Time Machine" }
    if name.hasPrefix("com.apple.os.update") { return "macOS update" }
    if name.hasPrefix("com.bombich.ccc") { return "Carbon Copy Cloner" }
    return "Other app"
}

func listSnapshots(_ mount: String, attrs: attrlist) -> (snaps: [Snap], rc: Int32, errno: Int32) {
    let fd = open(mount, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { return ([], -2, errno) }   // -2 = open 就失败
    defer { close(fd) }
    let size = 64 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<Int>.alignment)
    defer { buf.deallocate() }
    var alist = attrs
    var out: [Snap] = []
    let nameRef = 4 + MemoryLayout<attribute_set_t>.size      // 24
    let timeOff = nameRef + MemoryLayout<attrreference_t>.size // 32
    var lastRc: Int32 = 0
    while true {
        lastRc = fs_snapshot_list(fd, &alist, buf, size, 0)
        guard lastRc > 0 else { break }   // rc==0 = 成功但空列表;rc==-1 = 出错(看 errno)
        var at = 0
        for _ in 0..<lastRc {
            guard at + 4 <= size else { break }
            let length = Int(buf.load(fromByteOffset: at, as: UInt32.self))
            guard length >= 4 + MemoryLayout<attribute_set_t>.size + MemoryLayout<attrreference_t>.size, at + length <= size else { break }
            let off = buf.load(fromByteOffset: at + nameRef, as: Int32.self)
            let nlen = Int(buf.load(fromByteOffset: at + nameRef + 4, as: UInt32.self))
            var name = ""
            let start = at + nameRef + Int(off)
            if nlen > 0, off >= 0, start + nlen <= at + length {
                name = String(decoding: UnsafeRawBufferPointer(start: buf + start, count: nlen - 1), as: UTF8.self)
            }
            let sec = buf.load(fromByteOffset: at + timeOff, as: Int64.self)
            out.append(Snap(name: name, created: sec))
            at += length
        }
    }
    return (out.sorted { $0.created < $1.created }, lastRc, errno)
}

func fullAttrs() -> attrlist {
    attrlist(bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0,
             commonattr: ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_CRTIME,
             volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
}

let fmt = { (sec: Int64) -> String in
    ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(sec)), timeZone: .current, formatOptions: [.withInternetDateTime])
}

print("uid=\(getuid())(非 root)  探针②:fs_snapshot_list 可列性 + attrlist 负对照")
for m in ["/System/Volumes/Data", "/"] {
    let (snaps, rc, err) = listSnapshots(m, attrs: fullAttrs())
    print("\n== \(m):\(snaps.count) 个快照 (最后一次调用 rc=\(rc),errno=\(err)) ==")
    for s in snaps.prefix(20) {
        print("  \(fmt(s.created))  [\(kind(s.name))]  \(s.name)")
    }
    if snaps.count > 20 { print("  …共 \(snaps.count) 个") }
    // 负对照:去掉 RETURNED_ATTRS 位,petal 注释称内核拒收(EINVAL)
    var bad = fullAttrs()
    bad.commonattr &= ~ATTR_CMN_RETURNED_ATTRS
    let (_, badRc, badErr) = listSnapshots(m, attrs: bad)
    print("  负对照(缺 RETURNED_ATTRS):rc=\(badRc),errno=\(badErr)\(badErr == EINVAL ? " → EINVAL,petal 注释成立" : badRc >= 0 ? " → 竟然成功,注释过时?" : "")")
}
