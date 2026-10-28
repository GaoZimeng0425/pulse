// 15-volume-scan-baseline.swift — p4-cleaner/01 探针⑤:全卷扫描量级基线(单线程、限时可中断)
// 问:单线程 getattrlistbulk 扫数据卷的速率/文件数/字节数量级 → 03 票进度与并发设计基线。
// 常量与布局结论来自探针 11(27 须带 RETURNED_ATTRS;attribute_set_t 20B;定长属性 4 字节紧凑;FILEID 8B)。
// 运行:swiftc 15-volume-scan-baseline.swift -o /tmp/p4probe15 && /tmp/p4probe15 [秒数,默认30]
import Darwin
import Foundation

let CMN_RETURNED: UInt32 = 0x8000_0000, CMN_NAME: UInt32 = 0x1, CMN_OBJTYPE: UInt32 = 0x8,
    CMN_FILEID: UInt32 = 0x0200_0000, CMN_FLAGS: UInt32 = 0x40000, CMN_DEVID: UInt32 = 0x2
let NX_PRIVATESIZE: UInt32 = 0x08
let FSOPT_CMN_EXT: UInt64 = 0x20

func rd32(
    _ b: [UInt8],
    _ o: Int
) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

func rd64(_ b: [UInt8], _ o: Int) -> Int64 {
    Int64(bitPattern: UInt64(rd32(b, o)) | UInt64(rd32(b, o + 4)) << 32)
}

struct Entry { var name = ""
    var objType: UInt32 = 0
    var fileid: UInt64 = 0
    var dev: UInt32 = 0
    var flags: UInt32 = 0
    var privateSize: Int64 = -1
}

func parseEntry(_ buf: [UInt8], _ off: Int) -> Entry {
    var e = Entry()
    var cur = off + 4
    let retCommon = rd32(buf, cur), retFork = rd32(buf, cur + 16)
    cur += 20
    var nameRel = 0, nameLen = 0
    if retCommon & CMN_NAME != 0 {
        nameRel = Int(rd32(buf, cur))
        nameLen = Int(rd32(buf, cur + 4))
        cur += 8
    }
    if retCommon & CMN_DEVID != 0 {
        e.dev = rd32(buf, cur)
        cur += 4
    }
    if retCommon & CMN_OBJTYPE != 0 {
        e.objType = rd32(buf, cur)
        cur += 4
    }
    if retCommon & CMN_FLAGS != 0 {
        e.flags = rd32(buf, cur)
        cur += 4
    }
    if retCommon & CMN_FILEID != 0 {
        e.fileid = UInt64(bitPattern: rd64(buf, cur))
        cur += 8
    }
    if retFork & NX_PRIVATESIZE != 0 {
        e.privateSize = rd64(buf, cur)
    }
    if nameLen > 0 {
        let s = off + 24 + nameRel
        var t = s
        while t < buf.count, buf[t] != 0, t < s + nameLen {
            t += 1
        }
        e.name = String(bytes: buf[s ..< t], encoding: .utf8) ?? "?"
    }
    return e
}

let budget = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "30") ?? 30
let t0 = Date()
var files = 0, dirs = 0, entriesSeen = 0
var privateBytes = 0, blocksBytes = 0
var dirStack = ["/System/Volumes/Data"]
var visited = Set<UInt64>() // (dev,fileid) 已访问目录——防 firmlink 双计(探针11:dev 全盘同值,防双计靠它)
var errs = 0
var nextTick = t0.addingTimeInterval(5)

while let dir = dirStack.popLast() {
    if Date().timeIntervalSince(t0) > budget {
        print("⏱ 到达 \(Int(budget))s 预算,提前停(栈里还有 \(dirStack.count) 个目录未展开)")
        break
    }
    let fd = open(dir, O_RDONLY)
    if fd < 0 {
        errs += 1
        continue
    }
    var al = attrlist()
    al.bitmapcount = 5
    al.commonattr = CMN_RETURNED | CMN_NAME | CMN_OBJTYPE | CMN_FILEID | CMN_FLAGS | CMN_DEVID
    al.forkattr = NX_PRIVATESIZE
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    loop: while true {
        let bsz = buf.count
        let r = buf.withUnsafeMutableBytes { raw in getattrlistbulk(fd, &al, raw.baseAddress, bsz, FSOPT_CMN_EXT) }
        if r == 0 {
            break
        }
        if r < 0 {
            if errno == EINTR {
                continue
            }
            errs += 1
            break loop
        }
        var off = 0
        for _ in 0 ..< r {
            let len = Int(rd32(buf, off))
            let e = parseEntry(buf, off)
            off += len
            if e.name == "." || e.name == ".." {
                continue
            }
            entriesSeen += 1
            if e.privateSize > 0 {
                privateBytes += Int(clamping: e.privateSize)
            }
            if e.objType == 2 {
                dirs += 1
                let key = (UInt64(e.dev) << 32) | e.fileid
                if !visited.contains(key), e.fileid != 0 {
                    visited.insert(key)
                    dirStack.append(dir + "/" + e.name)
                }
            } else if e.objType == 1 {
                files += 1
            }
        }
    }
    if Date() >= nextTick {
        let el = Date().timeIntervalSince(t0)
        print(String(
            format: "  [%4.0fs] 文件 %8d · 目录 %7d · 私有字节 %10.2f GiB · 速率 %.0f 项/s",
            el,
            files,
            dirs,
            Double(privateBytes) / 1_073_741_824.0,
            Double(entriesSeen) / el
        ))
        nextTick = nextTick.addingTimeInterval(5)
    }
}

let el = Date().timeIntervalSince(t0)
print(String(format: "== 结果(单线程 getattrlistbulk,扫 /System/Volumes Data 卷,%0.fs)==", el))
print("  文件 \(files) · 目录 \(dirs) · 合计 \(entriesSeen) 项 · 错误调用 \(errs)")
print(String(format: "  PRIVATESIZE 合计 %.2f GiB(删光可释放口径,含系统文件——仅作速率基线,非清理清单)", Double(privateBytes) / 1_073_741_824.0))
print(String(
    format: "  速率 %.0f 项/s · 全卷文件数按 Data 卷 ~40 万量级外推,全扫预计 %.0f 秒(单线程)",
    Double(entriesSeen) / el,
    400_000 / (Double(entriesSeen) / el)
))
print("  布局/常量结论沿用探针 11;本探针输出喂 03 票的进度与并发设计")
