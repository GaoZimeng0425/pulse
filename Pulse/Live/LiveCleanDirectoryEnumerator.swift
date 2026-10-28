import Foundation
import PulseCore

// MARK: - Live 目录枚举器(p4-cleaner/03)

//
// getattrlistbulk 真实现,挂 `CleanDirectoryEnumerator`(p4-cleaner/02 的边界协议)。
// 布局 / 常量 / 必带 RETURNED_ATTRS 全部出自探针 11(docs/probes/11,macOS 27.0.1 实测):
//   条目 = [len u32][attribute_set_t 5×u32 = 20B][定长属性按 4 字节紧凑][名字尾置,条目补齐 8];
//   cmnext 位放 attrlist.forkattr + 选项 FSOPT_ATTR_CMN_EXTENDED(0x20);FILEID 宽 8B。
//   常量硬编码的原因:SDK 里这些 ATTR_CMN_* 是 enum 不进 Swift 模块(探针 11 踩坑记录),
//   值以 docs/probes/11 头注释为准,改动前先重跑探针。
// 护栏出自 dust 调研(docs/research/dust-reference.md §2):EINTR 重试上限(999)、
// 错误分类台账;block 虚报封顶(§2.1)暂不搬——APFS 内置盘 ALLOCSIZE 可靠,
// 网络卷 / 异构挂载留观后再定(收口票复盘点)。
// 无状态 struct:枚举在调用方(引擎所在的低优先级 Task)线程同步执行,
// async 履约仅为协议形状。

struct LiveCleanDirectoryEnumerator: CleanDirectoryEnumerator {
    // attr 常量(sys/attr.h,探针 11 实测;注释见文件头)
    private static let cmnReturned: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x1
    private static let cmnDevID: UInt32 = 0x2
    private static let cmnObjType: UInt32 = 0x8
    private static let cmnFlags: UInt32 = 0x40000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let fileLinkCount: UInt32 = 0x1
    private static let fileTotalSize: UInt32 = 0x2
    private static let fileAllocSize: UInt32 = 0x4
    private static let dirAllocSize: UInt32 = 0x8
    private static let cmnextPrivateSize: UInt32 = 0x08
    private static let fsoptAttrCmnExtended: UInt64 = 0x20
    private static let sfDataless: UInt32 = 0x4000_0000

    func entries(ofDirectory path: String) async throws -> [FsEntrySnapshot] {
        try enumerate(path)
    }

    private func enumerate(_ path: String) throws -> [FsEntrySnapshot] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw mapErrno(path) }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = 5
        attrList.commonattr = Self.cmnReturned | Self.cmnName | Self.cmnDevID | Self.cmnObjType
            | Self.cmnFlags | Self.cmnFileID
        attrList.fileattr = Self.fileLinkCount | Self.fileTotalSize | Self.fileAllocSize
        attrList.dirattr = Self.dirAllocSize
        attrList.forkattr = Self.cmnextPrivateSize

        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var snapshots: [FsEntrySnapshot] = []
        snapshots.reserveCapacity(128)
        var eintrRetries = 0

        while true {
            let size = buffer.count
            let count = buffer.withUnsafeMutableBytes { raw in
                getattrlistbulk(fd, &attrList, raw.baseAddress, size, Self.fsoptAttrCmnExtended)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                // dust §2.5:EINTR 唯一可重试;常态本机观测为 0 次(探针 11 ⑦),
                // 上限 999 防失控死循环(有些系统常态性 EINTR)。
                if errno == EINTR, eintrRetries < 999 {
                    eintrRetries += 1
                    continue
                }
                throw mapErrno(path)
            }
            var offset = 0
            for _ in 0 ..< count {
                let entryLength = Int(readU32(buffer, offset))
                snapshots.append(parseEntry(buffer, entryOffset: offset))
                offset += entryLength
            }
        }
        return snapshots
    }

    private func mapErrno(_ path: String) -> CleanEnumerateError {
        switch errno {
        case EACCES, EPERM: CleanEnumerateError(path: path, reason: .permissionDenied)
        case ENOENT: CleanEnumerateError(path: path, reason: .vanished)
        default: CleanEnumerateError(path: path, reason: .other(errno: errno))
        }
    }

    // MARK: 条目解析(探针 11 验证过的布局;改前重跑探针)

    private func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private func readI64(_ b: [UInt8], _ o: Int) -> Int64 {
        Int64(bitPattern: UInt64(readU32(b, o)) | UInt64(readU32(b, o + 4)) << 32)
    }

    private func parseEntry(_ b: [UInt8], entryOffset: Int) -> FsEntrySnapshot {
        var cursor = entryOffset + 4 // 跳过 entry length(u32)
        // attribute_set_t = 5×u32(common/vol/dir/file/fork 实际返回了什么)
        let returnedCommon = readU32(b, cursor)
        let returnedDir = readU32(b, cursor + 8)
        let returnedFile = readU32(b, cursor + 12)
        let returnedFork = readU32(b, cursor + 16)
        cursor += 20

        var nameRelative = 0, nameLength = 0
        if returnedCommon & Self.cmnName != 0 {
            nameRelative = Int(readU32(b, cursor))
            nameLength = Int(readU32(b, cursor + 4))
            cursor += 8
        }
        var deviceID: UInt32 = 0
        if returnedCommon & Self.cmnDevID != 0 {
            deviceID = readU32(b, cursor)
            cursor += 4
        }
        var objType: UInt32 = 0
        if returnedCommon & Self.cmnObjType != 0 {
            objType = readU32(b, cursor)
            cursor += 4
        }
        var flags: UInt32 = 0
        if returnedCommon & Self.cmnFlags != 0 {
            flags = readU32(b, cursor)
            cursor += 4
        }
        var fileID: UInt64 = 0
        if returnedCommon & Self.cmnFileID != 0 {
            fileID = UInt64(bitPattern: readI64(b, cursor))
            cursor += 8
        }
        // dir 组:ALLOCSIZE(off_t);file 组:LINKCOUNT(u32) → TOTALSIZE(off_t) → ALLOCSIZE(off_t)
        if returnedDir & Self.dirAllocSize != 0 {
            cursor += 8
        }
        var linkCount: UInt32 = 1
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        if returnedFile & Self.fileLinkCount != 0 {
            linkCount = readU32(b, cursor)
            cursor += 4
        }
        if returnedFile & Self.fileTotalSize != 0 {
            logicalSize = readI64(b, cursor)
            cursor += 8
        }
        if returnedFile & Self.fileAllocSize != 0 {
            allocatedSize = readI64(b, cursor)
            cursor += 8
        }
        var privateSize: Int64?
        if returnedFork & Self.cmnextPrivateSize != 0 {
            privateSize = readI64(b, cursor)
        }

        // Darwin vnode 类型:VREG=1 VDIR=2 VBLK=3 VCHR=4 VLNK=5 VSOCK=6 VFIFO=7。
        let kind: FsEntrySnapshot.Kind = switch objType {
        case 1: .file
        case 2: .directory
        case 5: .symlink
        default: .other
        }

        // 名字:attrref 偏移基准 = entry+24(首 attrref 位,探针 11 逐字节验证);
        // 非法 UTF-8 走 lossy,不丢条目(防御性数据纪律:不因解码失败装作没看见)。
        var name = "?"
        if nameLength > 0 {
            let start = entryOffset + 24 + nameRelative
            var end = start
            while end < b.count, b[end] != 0, end < start + nameLength {
                end += 1
            }
            if start <= end, end <= b.count {
                name = String(bytes: b[start ..< end], encoding: .utf8)
                    ?? String(decoding: b[start ..< end], as: UTF8.self)
            }
        }

        return FsEntrySnapshot(
            name: name,
            kind: kind,
            deviceID: deviceID,
            fileID: fileID,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            reclaimableSize: privateSize,
            linkCount: linkCount,
            isDataless: flags & Self.sfDataless != 0
        )
    }
}
