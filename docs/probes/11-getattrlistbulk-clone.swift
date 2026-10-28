// 11-getattrlistbulk-clone.swift — p4-cleaner/01 探针①
// 问:getattrlistbulk 字段形状 / cmnext(PRIVATESIZE·CLONE_REFCNT)可用性 / APFS 克隆口径 / firmlink st_dev / dataless / EINTR
// 环境:macOS 27.0.1(26A434)。常量全部来自本机 SDK attr.h 实测(2026-10-28 抠出,勿凭记忆改):
//   common 组: NAME=0x1 DEVID=0x2 OBJTYPE=0x8 FLAGS=0x40000 FILEID=0x02000000 RETURNED_ATTRS=0x80000000
//   file  组: LINKCOUNT=0x1 TOTALSIZE=0x2 ALLOCSIZE=0x4 ; dir 组: ALLOCSIZE=0x8
//   cmnext 组(位放 attrlist.forkattr 字段 + 选项 FSOPT_ATTR_CMN_EXTENDED=0x20):
//     PRIVATESIZE=0x08 CLONEID=0x100 CLONE_REFCNT=0x1000
//   SF_DATALESS=0x40000000(stat.h)
// 运行:swiftc 11-getattrlistbulk-clone.swift -o /tmp/p4probe11 && /tmp/p4probe11
//
// ===== 结论(2026-10-28 跑完回填,喂 02/03 票) =====
// ① macOS 27 上 getattrlistbulk 必须带 ATTR_CMN_RETURNED_ATTRS,否则一律 EINVAL(文档写"或",实测是"且")。
// ② 条目布局 = [len u32][attribute_set_t 5×u32=20B][定长属性按 4 字节紧凑排布][名字尾置,条目补齐到 8]
//    (FILEID 宽 8B=64 位对象 ID;attrref 偏移基准 = entry+24 即首 attrref 位;一切宽度由 0x48/0x58 连续条目逐字节验证)。
// ③ cmnext 可用且批量可用:位放 attrlist.forkattr + 选项 FSOPT_ATTR_CMN_EXTENDED(0x20);不带旗 → EINVAL。
//    单发路径的 cmnext 记录自带 u32 长度头(值在偏移 4)。
// ④ PRIVATESIZE 官方语义 = "删此文件立即释放、不被克隆/快照困住的字节数"——克隆实验逐条兑现:
//    8MB 原件=8388608B/克隆未改=0B/克隆 CoW 后=1MB/原件(克隆在场)=0B。CLONE_REFCNT 1→2→1 同步印证。
//    ⇒ 引擎"真实可回收量"= 直接求和 PRIVATESIZE,克隆记账文件系统原生完成,无需自研。
// ⑤ firmlink:根卷与 Data 卷 st_dev 完全相同(16777229)——dust 的 st_dev 剪枝在本机不成立;
//    防双计靠 (dev,fileid) 目录访问集 + 文件级硬链接去重(同键)。/home 等 autofs 合成挂载 dev 不同,剪枝仍可发现外族。
// ⑥ dataless:本机 iCloud Mobile Documents 顶层 45 项全目录、SF_DATALESS=0;检测路径(FLAGS 位)已带在属性集里,回源风险=跳过 objType=VREG+SF_DATALESS
// 项。
// ⑦ EINTR:~200 项 Caches 两层 walk 零 EINTR;唯一 errno 是权限类。999 上限仅网络卷防御保留。
// ⑧ /Applications 顶层全目录 priv=0、/etc 文件 total 与 lstat 逐条吻合(mismatch=0)——解析器可直接进 02 票。
import Darwin
import Foundation

let FSOPT_CMN_EXT: UInt32 = 0x20
let CMN_NAME: UInt32 = 0x1, CMN_DEVID: UInt32 = 0x2, CMN_OBJTYPE: UInt32 = 0x8,
    CMN_FLAGS: UInt32 = 0x40000, CMN_FILEID: UInt32 = 0x0200_0000, CMN_RETURNED: UInt32 = 0x8000_0000
let F_LINKCOUNT: UInt32 = 0x1, F_TOTALSIZE: UInt32 = 0x2, F_ALLOCSIZE: UInt32 = 0x4
let D_ALLOCSIZE: UInt32 = 0x8
let NX_PRIVATESIZE: UInt32 = 0x08, NX_CLONEID: UInt32 = 0x100, NX_CLONE_REFCNT: UInt32 = 0x1000
let SF_DATALESS_FLAG: UInt32 = 0x4000_0000

func section(_ s: String) {
    print("\n========== \(s) ==========")
}

func hexdump(_ b: [UInt8], _ n: Int) -> String {
    (0 ..< min(n, b.count)).map { String(format: "%02x", b[$0]) }.joined(separator: " ")
}

/// 手写小端读数(绕开 loadUnaligned 的工具链差异;对齐由调用方管)
func rd32(
    _ b: [UInt8],
    _ o: Int
) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

func rd64(_ b: [UInt8], _ o: Int) -> Int64 {
    Int64(bitPattern: UInt64(rd32(b, o)) | UInt64(rd32(b, o + 4)) << 32)
}

func singleGetattr(
    _ path: String,
    common: UInt32,
    file: UInt32 = 0,
    dir: UInt32 = 0,
    fork: UInt32 = 0,
    options: UInt32 = 0,
    bufSize: Int = 256
) -> (buf: [UInt8], err: Int32) {
    var al = attrlist()
    al.bitmapcount = 5
    al.commonattr = common
    al.fileattr = file
    al.dirattr = dir
    al.forkattr = fork
    var buf = [UInt8](repeating: 0, count: bufSize)
    let r = path
        .withCString { p in buf.withUnsafeMutableBytes { getattrlist(p, &al, $0.baseAddress, bufSize, options) } }
    return (buf, r == 0 ? 0 : errno)
}

struct LStat { var dev: UInt32 = 0
    var ino: UInt64 = 0
    var size: Int64 = 0
    var blocks: Int64 = 0
    var flags: UInt32 = 0
    init?(_ p: String) {
        var s = stat()
        guard stat(p, &s) == 0 else { return nil }
        dev = UInt32(truncatingIfNeeded: s.st_dev)
        ino = s.st_ino
        size = s.st_size
        blocks = s.st_blocks
        flags = s.st_flags
    }
}

/// ---------- 0. 对齐定标:file 组 LINKCOUNT(u32)+TOTALSIZE(off_t) ----------
func calibrateAlignment() -> Bool {
    section("0. 返回缓冲对齐规则定标(file 组 LINKCOUNT u32 + TOTALSIZE off_t)")
    let tmp = NSTemporaryDirectory() + "/p4probe_align_\(getpid()).txt"
    try! Data(repeating: 0x41, count: 100_000).write(to: URL(fileURLWithPath: tmp))
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let (buf, err) = singleGetattr(tmp, common: 0, file: F_LINKCOUNT | F_TOTALSIZE)
    if err != 0 {
        print("  getattrlist 失败 errno=\(err)")
        return true
    }
    print("  raw[0..24]: \(hexdump(buf, 24))")
    print("  按 4 字节对齐解读: linkcount=\(rd32(buf, 0)) total=\(rd64(buf, 4))")
    print("  按自然对齐解读:   linkcount=\(rd32(buf, 0)) total=\(rd64(buf, 8)) | 真值 size=100000 linkcount=1")
    let isNat = rd32(buf, 0) == 1 && rd64(buf, 8) == 100_000
    let is4 = rd32(buf, 0) == 1 && rd64(buf, 4) == 100_000
    print("  判定: \(isNat ? "自然对齐(off_t 8B)" : is4 ? "4 字节对齐" : "两种都不匹配——人工看 raw")")
    return isNat
}

/// ---------- 1. 单发 cmnext 形状 ----------
func probeSingleCmnext(_ path: String) {
    section("1. 单发 getattrlist + cmnext(样本 \(path))")
    for (name, bit, expectWidth) in [
        ("PRIVATESIZE", NX_PRIVATESIZE, "off_t 8B"),
        ("CLONE_REFCNT", NX_CLONE_REFCNT, "u32 4B?"),
        ("CLONEID", NX_CLONEID, "u64 8B?"),
    ] {
        let (buf, err) = singleGetattr(path, common: 0, fork: bit, options: FSOPT_CMN_EXT)
        if err != 0 {
            print("  \(name): 失败 errno=\(err) (\(String(cString: strerror(err))))")
        } else {
            print(
                "  \(name): OK 长度头=\(rd32(buf, 0)) 值@4=\(UInt64(bitPattern: rd64(buf, 4))) 预期宽=\(expectWidth) raw=\(hexdump(buf, 16))"
            )
        }
    }
    let (_, err2) = singleGetattr(path, common: 0, fork: NX_PRIVATESIZE, options: 0)
    print("  不带 FSOPT_ATTR_CMN_EXTENDED 请求 PRIVATESIZE → errno=\(err2)(期望 EINVAL=22,证明旗必须)")
}

/// ---------- 2. 克隆实验 ----------
func probeClone() {
    section("2. APFS 克隆口径(clonefile + PRIVATESIZE/CLONE_REFCNT)")
    let dir = NSTemporaryDirectory() + "/p4probe_clone_\(getpid())"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let orig = dir + "/orig.bin", clone = dir + "/clone.bin"
    var rnd = [UInt8](repeating: 0, count: 8 << 20)
    SecRandomCopyBytes(kSecRandomDefault, rnd.count, &rnd)
    try! Data(rnd).write(to: URL(fileURLWithPath: orig))

    func report(_ label: String, _ path: String) {
        guard let st = LStat(path) else { print("  \(label): stat 失败")
            return
        }
        let (ps, errP) = singleGetattr(path, common: 0, fork: NX_PRIVATESIZE, options: FSOPT_CMN_EXT)
        let (rc, errR) = singleGetattr(path, common: 0, fork: NX_CLONE_REFCNT, options: FSOPT_CMN_EXT)
        let priv = errP == 0 ? rd64(ps, 4) : -1 // cmnext 记录 = u32 长度头 + 值
        let refc = errR == 0 ? UInt64(rd32(rc, 4)) : UInt64.max
        print(
            "  \(label): size=\(st.size) blocks=\(st.blocks)(alloc=\(st.blocks * 512)B) | PRIVATESIZE=\(priv)B\(errP != 0 ? "(errno=\(errP))" : "") | CLONE_REFCNT=\(refc == .max ? "err\(errR)" : String(refc))"
        )
    }
    report("原件(8MB 随机写入)     ", orig)
    let cr = orig.withCString { s in clone.withCString { d in clonefile(s, d, 0) } }
    if cr != 0 {
        print("  clonefile 失败 errno=\(errno)")
        return
    }
    report("克隆(clonefile 后未改) ", clone)
    if let fh = FileHandle(forWritingAtPath: clone) {
        _ = try? fh.seekToEnd()
        fh.write(Data(repeating: 0x42, count: 1 << 20))
        try? fh.close()
    }
    report("克隆(追加 1MB 触发 CoW)", clone)
    report("原件(克隆改写后复测)   ", orig)
    print("  验证目标:删任一副本能回收的 ≈ 各自 PRIVATESIZE;共享块谁都不独占")
}

/// ---------- 3. firmlink / st_dev ----------
func probeFirmlink() {
    section("3. firmlink 与 st_dev(根卷=密封系统卷,数据卷=Data)")
    for p in [
        "/",
        "/System",
        "/System/Volumes/Data",
        "/Users",
        "/Library",
        "/private/var",
        "/Applications",
        "/Users/aa00930",
        "/private/tmp",
    ] {
        guard let st = LStat(p) else { print("  \(p): stat 失败")
            continue
        }
        print("  \(p.padding(toLength: 26, withPad: " ", startingAt: 0)) dev=\(st.dev) ino=\(st.ino)")
    }
    print("  —— 根目录一级子项里 dev ≠ 根 dev 的(firmlink 跳变)——")
    if let kids = try? FileManager.default.contentsOfDirectory(atPath: "/"), let rootDev = LStat("/")?.dev {
        var jumps = 0
        for k in kids where jumps < 12 {
            if let st = LStat("/" + k), st.dev != rootDev {
                print("    /\(k): dev=\(st.dev)")
                jumps += 1
            }
        }
        print("    (共 \(kids.count) 个一级子项,跳变列出 ≤12 个)")
    }
}

/// ---------- 4. bulk 形状(27 实测:必须带 CMN_RETURNED_ATTRS,每条目开头回赠 24B attrlist) ----------
struct BulkEntry { var name = ""
    var objType: UInt32 = 0
    var fileid: UInt32 = 0
    var devid: UInt32 = 0
    var flags: UInt32 = 0
    var totalSize: Int64 = 0
    var allocSize: Int64 = 0
    var linkCount: UInt32 = 0
    var privateSize: Int64 = -1
}

func bulkParse(_ buf: [UInt8], entryOffset: Int) -> BulkEntry {
    var e = BulkEntry()
    var cur = entryOffset + 4 // 跳过 entry length(u32)
    // attribute_set_t = 5×u32 = 20B;一切定长属性按 4 字节紧凑排布(u64/off_t 也不对齐到 8,实测条目逐字节验证)
    let retCommon = rd32(buf, cur), retDir = rd32(buf, cur + 8)
    let retFile = rd32(buf, cur + 12), retFork = rd32(buf, cur + 16)
    cur += 20
    var nameRel = 0, nameLen = 0
    if retCommon & CMN_NAME != 0 { // attrref(8)
        nameRel = Int(rd32(buf, cur))
        nameLen = Int(rd32(buf, cur + 4))
        cur += 8
    }
    if retCommon & CMN_DEVID != 0 {
        e.devid = rd32(buf, cur)
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
        e.fileid = UInt32(rd64(buf, cur))
        cur += 8
    } // FILEID 宽 8B(64 位对象 ID)
    if retDir & D_ALLOCSIZE != 0 {
        e.allocSize = rd64(buf, cur)
        cur += 8
    }
    if retFile & F_LINKCOUNT != 0 {
        e.linkCount = rd32(buf, cur)
        cur += 4
    }
    if retFile & F_TOTALSIZE != 0 {
        e.totalSize = rd64(buf, cur)
        cur += 8
    }
    if retFile & F_ALLOCSIZE != 0 {
        cur += 8
    }
    if retFork & NX_PRIVATESIZE != 0 {
        e.privateSize = rd64(buf, cur)
        cur += 8
    }
    if nameLen > 0 {
        let s = entryOffset + 24 + nameRel // 偏移基准实测 = entry+24(首条 attrref 位)
        var t = s
        while t < buf.count, buf[t] != 0, t < s + nameLen {
            t += 1
        }
        e.name = String(bytes: buf[s ..< t], encoding: .utf8) ?? "?"
    }
    return e
}

func probeBulk(_ dirPath: String, limit: Int = 8) {
    section("4. getattrlistbulk(\(dirPath)):27 上须带 RETURNED_ATTRS;cmnext 走批量")
    let fd = open(dirPath, O_RDONLY)
    guard fd >= 0 else { print("  open 失败 errno=\(errno)")
        return
    }
    defer { close(fd) }
    var al = attrlist()
    al.bitmapcount = 5
    al.commonattr = CMN_RETURNED | CMN_NAME | CMN_DEVID | CMN_OBJTYPE | CMN_FLAGS | CMN_FILEID
    al.fileattr = F_LINKCOUNT | F_TOTALSIZE | F_ALLOCSIZE
    al.dirattr = D_ALLOCSIZE
    var buf = [UInt8](repeating: 0, count: 1 << 16)

    // 4a: 基线逐条解析 + lstat 对拍
    var printed = 0, mismatch = 0
    while printed < limit {
        let bufSize = buf.count
        let r = buf.withUnsafeMutableBytes { raw in getattrlistbulk(fd, &al, raw.baseAddress, bufSize, 0) }
        if r <= 0 {
            print("  [4a] r=\(r) errno=\(r < 0 ? errno : 0)(0=目录迭代完)")
            break
        }
        var off = 0
        for _ in 0 ..< r where printed < limit {
            let len = Int(rd32(buf, off))
            let e = bulkParse(buf, entryOffset: off)
            let ls = LStat(dirPath + "/" + e.name)
            let ok = ls != nil && (ls!.size == e.totalSize || e.objType == 2)
            if !ok {
                mismatch += 1
            }
            print(
                "    \(e.name.prefix(22).padding(toLength: 22, withPad: " ", startingAt: 0)) \(e.objType == 2 ? "VDIR" : e.objType == 1 ? "VREG" : "t\(e.objType)") fileid=\(e.fileid) flags=\(String(format: "%#x", e.flags)) total=\(e.totalSize) priv=\(e.privateSize) lstat=\(ls?.size ?? -99) \(ok ? "✓" : "✗")"
            )
            printed += 1
            off += len
        }
    }
    if printed > 0 {
        print("  [4a] 首条 raw: \(hexdump(Array(buf[0 ..< 64]), 64))")
    }
    print("  [4a] 解析 \(printed) 条 mismatch=\(mismatch)")

    // 4b: 同一 fd 重开 + cmnext PRIVATESIZE 走批量
    let fd2 = open(dirPath, O_RDONLY)
    guard fd2 >= 0 else { return }
    defer { close(fd2) }
    al.forkattr = NX_PRIVATESIZE
    var got = 0
    while got < limit {
        let bufSize2 = buf.count
        let r2 = buf.withUnsafeMutableBytes { raw in getattrlistbulk(
            fd2,
            &al,
            raw.baseAddress,
            bufSize2,
            UInt64(FSOPT_CMN_EXT)
        ) }
        if r2 <= 0 {
            print("  [4b] r=\(r2) errno=\(r2 < 0 ? errno : 0)")
            break
        }
        var off = 0
        for _ in 0 ..< r2 where got < limit {
            let len = Int(rd32(buf, off))
            let e = bulkParse(buf, entryOffset: off)
            print("    [cmnext] \(e.name.prefix(30)) priv=\(e.privateSize >= 0 ? "\(e.privateSize)B" : "无(目录?)")")
            got += 1
            off += len
        }
    }
    print("  [4b] bulk+cmnext 解析 \(got) 条(priv=-1 表示该条目没给,如目录)")
}

/// ---------- 5. dataless ----------
func probeDataless() {
    section("5. dataless(SF_DATALESS):~/Library/Mobile Documents")
    let root = NSHomeDirectory() + "/Library/Mobile Documents"
    var st = stat()
    guard stat(root, &st) == 0 else { print("  目录不存在(无 iCloud 数据)")
        return
    }
    let fd = open(root, O_RDONLY)
    guard fd >= 0 else { print("  open 失败 errno=\(errno)")
        return
    }
    defer { close(fd) }
    var al = attrlist()
    al.bitmapcount = 5
    al.commonattr = CMN_RETURNED | CMN_NAME | CMN_OBJTYPE | CMN_FLAGS
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    var total = 0, dataless = 0, dirs = 0
    while total < 20000 {
        let bsz = buf.count
        let r = buf.withUnsafeMutableBytes { raw in getattrlistbulk(fd, &al, raw.baseAddress, bsz, 0) }
        if r <= 0 {
            if r < 0 {
                print("  bulk errno=\(errno)")
            }
            break
        }
        var off = 0
        for _ in 0 ..< r {
            let len = Int(rd32(buf, off))
            let e = bulkParse(buf, entryOffset: off)
            total += 1
            if e.objType == 2 {
                dirs += 1
            }
            if e.flags & SF_DATALESS_FLAG != 0 {
                dataless += 1
            }
            off += len
        }
    }
    print("  扫描 \(total) 项(目录 \(dirs)):SF_DATALESS 置位 = \(dataless) 项 \(total >= 20000 ? "(触2万上限)" : "")")
}

/// ---------- 6. EINTR / errno 台账 ----------
func probeErrno(_ dirPath: String) {
    section("6. EINTR/errno 台账:两层 walk \(dirPath)")
    var hist: [Int32: Int] = [:]
    var entries = 0
    func walkDir(_ path: String, depth: Int) {
        guard depth < 2, entries < 50000 else { return }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { hist[errno, default: 0] += 1
            return
        }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = 5
        al.commonattr = CMN_RETURNED | CMN_NAME | CMN_OBJTYPE
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
        defer { buf.deallocate() }
        while true {
            let r = getattrlistbulk(fd, &al, buf, 1 << 16, 0)
            if r > 0 {
                var off = 0
                for _ in 0 ..< r {
                    entries += 1
                    off += Int(buf[off]) | Int(buf[off + 1]) << 8 | Int(buf[off + 2]) << 16 | Int(buf[off + 3]) << 24
                }
                continue
            }
            if r == 0 {
                break
            }
            hist[errno, default: 0] += 1
            if errno == EINTR {
                continue
            }
            break
        }
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for k in kids.prefix(60) {
                var s = stat()
                let full = path + "/" + k
                if stat(full, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR {
                    walkDir(full, depth: depth + 1)
                }
            }
        }
    }
    walkDir(dirPath, depth: 0)
    print(
        "  条目=\(entries) errno 直方图=\(hist.map { "errno[\($0.key)]=\($0.value)" }.sorted { $0 < $1 }.joined(separator: " "))(EINTR=4;为 0 → 本机常态无 EINTR)"
    )
}

// ---------- main ----------
setvbuf(stdout, nil, _IONBF, 0)
print("env: \(ProcessInfo.processInfo.operatingSystemVersionString) · probe 11 · p4-cleaner/01")
_ = calibrateAlignment()
let probeFile = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/etc/hosts"
probeSingleCmnext(probeFile)
probeClone()
probeFirmlink()
probeBulk("/Applications")
probeBulk("/etc")
probeDataless()
probeErrno(NSHomeDirectory() + "/Library/Caches")
