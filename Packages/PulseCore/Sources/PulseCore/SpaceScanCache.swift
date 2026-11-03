import Foundation

// MARK: - 扫描结果落盘缓存(p4-cleaner/11,用户拍板 2026-11-03)

//
// 扫描一次约 1 分钟,而结果此前只存内存——关主窗即丢。本模块把 SpaceScanResult
// (目录粒度树 + 台账 + 统计)与扫描元信息编成紧凑二进制:
//   · 路径不整串存:树结构本身就是前缀(引擎保证 child.path = parent.path +
//     "/" + name),节点只存 name,解码时逐层重建——600k 节点的体积大头就此砍半;
//   · 整数全走 varint(zigzag),字符串 UTF-8 + varint 长度;
//   · 带魔数与版本,损坏/不识别 → 解码 nil(回空态,绝不伪造)。
// 地图显示树与清单不存:从树现算(map ~0.1s、匹配毫秒级),存反而多一份漂移源。
//
// 资源口径(票面钉死):写 = 扫描完成时一次;读 = 打开清理页时一次(后台);
// 内存 = 与扫完同峰,关窗释放;常驻稳态零(无调度)。

/// 扫描元信息:装载后判定「结果还能不能信」的依据(配置变了要提示重扫)。
public struct SpaceScanMeta: Sendable, Equatable {
    public var startedAt: Date
    public var finishedAt: Date
    /// 扫描时的根(物理域;测试注入的夹具根也照存)。
    public var roots: [String]
    /// 扫描时的排除清单快照。
    public var excludedPathPrefixes: [String]

    public init(
        startedAt: Date,
        finishedAt: Date,
        roots: [String],
        excludedPathPrefixes: [String]
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.roots = roots
        self.excludedPathPrefixes = excludedPathPrefixes
    }
}

/// 一份缓存 = 元信息 + 扫描产出。(树无 Equatable,比较走测试里的扁平化账目。)
public struct SpaceScanCachePayload: Sendable {
    public var meta: SpaceScanMeta
    public var result: SpaceScanResult

    public init(meta: SpaceScanMeta, result: SpaceScanResult) {
        self.meta = meta
        self.result = result
    }
}

public enum SpaceScanCache {
    static let magic: [UInt8] = Array("PSC1".utf8)
    /// 格式版本(魔数后 u32 小端)。不兼容变更:改魔数,不覆写旧文件语义。
    static let formatVersion: UInt32 = 1

    // MARK: 编码

    public static func encode(_ payload: SpaceScanCachePayload) -> Data {
        var w = Writer()
        w.rawBytes(Self.magic)
        w.u32(Self.formatVersion)

        let meta = payload.meta
        w.f64(meta.startedAt.timeIntervalSince1970)
        w.f64(meta.finishedAt.timeIntervalSince1970)
        w.strings(meta.roots)
        w.strings(meta.excludedPathPrefixes)

        let result = payload.result
        w.bool(result.cancelled)

        // 统计(varint)
        let s = result.stats
        w.varint(Int64(s.entriesSeen))
        w.varint(Int64(s.files))
        w.varint(Int64(s.directories))
        w.varint(Int64(s.symlinks))
        w.varint(Int64(s.datalessFiles))
        w.varint(Int64(s.hardlinkSkips))
        w.varint(Int64(s.doubleVisitSkips))
        w.varint(s.accountedBytes)

        // 台账
        w.varint(Int64(result.ledger.count))
        for error in result.ledger {
            w.string(error.path)
            switch error.reason {
            case .tccDenied: w.u8(0)
            case .permissionDenied: w.u8(1)
            case .vanished: w.u8(2)
            case .tooDeep: w.u8(3)
            case let .other(errno): w.u8(4)
                w.varint(Int64(errno))
            }
        }

        // 树:根整串路径 + 名字;子孙只存 name,路径解码时重建
        w.varint(Int64(result.trees.count))
        for tree in result.trees {
            encodeNode(tree, parentPath: nil, into: &w)
        }
        return w.data
    }

    /// - Parameter parentPath: nil = 根节点(存整串 path + name——根名可能与尾段不同,
    /// 如 "/");子节点只存 name。
    private static func encodeNode(_ node: SpaceNode, parentPath: String?, into w: inout Writer) {
        if parentPath == nil {
            w.string(node.path)
            w.string(node.name)
        } else {
            w.string(node.name)
        }
        w.u8(node.kind == .directory ? 0 : node.kind == .file ? 1 : node.kind == .symlink ? 2 : 3)
        w.varint(node.accountedBytes)
        w.varint(node.reclaimableBytes)
        w.varint(node.fallbackBytes)
        var flags: UInt8 = 0
        flags |= node.isPartial ? 0b0001 : 0
        flags |= node.allReclaimableAccounting ? 0 : 0b0010
        flags |= node.newestChangeEpoch == nil ? 0 : 0b0100
        w.u8(flags)
        if let newest = node.newestChangeEpoch {
            w.f64(newest)
        }
        w.varint(Int64(node.fileCount))
        w.varint(Int64(node.directoryCount))
        w.varint(Int64(node.symlinkCount))
        w.varint(Int64(node.datalessCount))
        w.varint(Int64(node.children.count))
        for child in node.children {
            // 引擎构造保证 child.path = 父 path + "/" + name(根 "/" 直拼)——
            // 解码按同式重建;万一有不守约的树(手搭夹具),编码侧如实存 name,
            // 重建出的 path 与原值不同处只在测试断言里暴露。
            encodeNode(child, parentPath: node.path, into: &w)
        }
    }

    // MARK: 解码(损坏/不识别 → nil,绝不半解半猜)

    public static func decode(_ data: Data) -> SpaceScanCachePayload? {
        var r = Reader(data: data)
        guard r.rawBytes(count: Self.magic.count) == Self.magic, r.u32() == Self.formatVersion,
              let started = r.f64(),
              let finished = r.f64(),
              let roots = r.strings(),
              let exclusions = r.strings(),
              let cancelled = r.bool(),
              let entries = r.varint(),
              let files = r.varint(),
              let directories = r.varint(),
              let symlinks = r.varint(),
              let dataless = r.varint(),
              let hardlinkSkips = r.varint(),
              let doubleVisitSkips = r.varint(),
              let accounted = r.varint()
        else { return nil }
        var stats = ScanStats()
        stats.entriesSeen = Int(entries)
        stats.files = Int(files)
        stats.directories = Int(directories)
        stats.symlinks = Int(symlinks)
        stats.datalessFiles = Int(dataless)
        stats.hardlinkSkips = Int(hardlinkSkips)
        stats.doubleVisitSkips = Int(doubleVisitSkips)
        stats.accountedBytes = accounted

        guard let ledgerCount = r.varint() else { return nil }
        var ledger: [CleanEnumerateError] = []
        ledger.reserveCapacity(Int(ledgerCount))
        for _ in 0 ..< ledgerCount {
            guard let path = r.string(), let tag = r.u8() else { return nil }
            let reason: CleanEnumerateFailure
            switch tag {
            case 0: reason = .tccDenied
            case 1: reason = .permissionDenied
            case 2: reason = .vanished
            case 3: reason = .tooDeep
            case 4:
                guard let errno = r.varint() else { return nil }
                reason = .other(errno: Int32(truncatingIfNeeded: errno))
            default:
                return nil
            }
            ledger.append(CleanEnumerateError(path: path, reason: reason))
        }

        guard let treeCount = r.varint() else { return nil }
        var trees: [SpaceNode] = []
        trees.reserveCapacity(Int(treeCount))
        for _ in 0 ..< treeCount {
            guard let tree = decodeNode(parentPath: nil, into: &r) else { return nil }
            trees.append(tree)
        }
        guard r.isAtEnd else { return nil }

        return SpaceScanCachePayload(
            meta: SpaceScanMeta(
                startedAt: Date(timeIntervalSince1970: started),
                finishedAt: Date(timeIntervalSince1970: finished),
                roots: roots,
                excludedPathPrefixes: exclusions
            ),
            result: SpaceScanResult(trees: trees, ledger: ledger, stats: stats, cancelled: cancelled)
        )
    }

    private static func decodeNode(parentPath: String?, into r: inout Reader) -> SpaceNode? {
        let pathOrName: String
        let name: String
        if parentPath == nil {
            guard let full = r.string(), let rootName = r.string() else { return nil }
            pathOrName = full
            name = rootName
        } else {
            guard let childName = r.string() else { return nil }
            pathOrName = childName
            name = childName
        }
        guard
            let kindByte = r.u8(),
            let accounted = r.varint(),
            let reclaimable = r.varint(),
            let fallback = r.varint(),
            let flags = r.u8()
        else { return nil }
        let kind: FsEntrySnapshot.Kind = switch kindByte {
        case 0: .directory
        case 1: .file
        case 2: .symlink
        default: .other
        }
        var newest: Double?
        if flags & 0b0100 != 0 {
            guard let value = r.f64() else { return nil }
            newest = value
        }
        guard
            let fileCount = r.varint(),
            let directoryCount = r.varint(),
            let symlinkCount = r.varint(),
            let datalessCount = r.varint(),
            let childCount = r.varint()
        else { return nil }

        let path: String = if let parentPath {
            parentPath == "/" ? "/" + pathOrName : parentPath + "/" + pathOrName
        } else {
            pathOrName
        }

        var node = SpaceNode(
            name: name,
            path: path,
            kind: kind,
            accountedBytes: accounted,
            reclaimableBytes: reclaimable,
            fallbackBytes: fallback,
            allReclaimableAccounting: flags & 0b0010 == 0,
            fileCount: Int(fileCount),
            directoryCount: Int(directoryCount),
            symlinkCount: Int(symlinkCount),
            datalessCount: Int(datalessCount),
            isPartial: flags & 0b0001 != 0,
            newestChangeEpoch: newest
        )
        node.children.reserveCapacity(Int(childCount))
        for _ in 0 ..< childCount {
            guard let child = decodeNode(parentPath: path, into: &r) else { return nil }
            node.children.append(child)
        }
        return node
    }
}

// MARK: - 字节读写器(varint:LEB128;zigzag 处理负数)

private struct Writer {
    var bytes: [UInt8] = []
    var data: Data {
        Data(bytes)
    }

    mutating func rawBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func u32(_ value: UInt32) {
        bytes.append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    mutating func bool(_ value: Bool) {
        u8(value ? 1 : 0)
    }

    mutating func f64(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func varint(_ value: Int64) {
        var v = UInt64(bitPattern: (value << 1) ^ (value >> 63)) // zigzag
        while true {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            if v == 0 {
                u8(byte)
                return
            }
            u8(byte | 0x80)
        }
    }

    mutating func string(_ value: String) {
        let raw = Array(value.utf8)
        varint(Int64(raw.count))
        bytes.append(contentsOf: raw)
    }

    mutating func strings(_ values: [String]) {
        varint(Int64(values.count))
        for value in values {
            string(value)
        }
    }
}

private struct Reader {
    let data: [UInt8]
    var offset = 0

    init(data: Data) {
        self.data = [UInt8](data)
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func rawBytes(count: Int) -> [UInt8]? {
        guard offset + count <= data.count else { return nil }
        defer { offset += count }
        return Array(data[offset ..< offset + count])
    }

    mutating func u8() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u32() -> UInt32? {
        guard let raw = rawBytes(count: 4) else { return nil }
        return UInt32(raw[0])
            | UInt32(raw[1]) << 8
            | UInt32(raw[2]) << 16
            | UInt32(raw[3]) << 24
    }

    mutating func bool() -> Bool? {
        guard let byte = u8() else { return nil }
        return byte == 1
    }

    mutating func f64() -> Double? {
        guard let raw = rawBytes(count: 8) else { return nil }
        var bits: UInt64 = 0
        for (index, byte) in raw.enumerated().reversed() {
            bits = bits << 8 | UInt64(byte)
            _ = index
        }
        // raw 已是小端字节序,上面从高到低拼回
        return Double(bitPattern: bits)
    }

    mutating func varint() -> Int64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let byte = u8() else { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
            guard shift < 64 else { return nil }
        }
        // unzigzag:低位是符号(1 = 负),其余位是量级——负数 = 按位取反量级
        let sign = result & 1
        let magnitude = result >> 1
        return Int64(bitPattern: sign == 0 ? magnitude : ~magnitude)
    }

    mutating func string() -> String? {
        guard let length = varint(), length >= 0, let raw = rawBytes(count: Int(length)) else { return nil }
        return String(bytes: raw, encoding: .utf8)
    }

    mutating func strings() -> [String]? {
        guard let count = varint(), count >= 0 else { return nil }
        var out: [String] = []
        out.reserveCapacity(Int(count))
        for _ in 0 ..< count {
            guard let value = string() else { return nil }
            out.append(value)
        }
        return out
    }
}
