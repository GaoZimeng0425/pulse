import Foundation
import IOKit
import PulseCore

// SMC 客户端移植自 stats(MIT)SMC/smc.swift(只读路径;**结构体布局必须与
// AppleSMC user client 逐字节一致**——内核侧按固定偏移解析,字段一个不能少),
// 探针⑤(docs/probes/05)为本仓先行实证:macOS 26 用户态连接免权限弹窗,
// #KEY=2806 枚举 9.2ms。写与风扇控制不移植。

// MARK: - SMC 客户端(只读裁剪,探针⑤同款布局)

/// AppleSMC 用户态连接:open 一次常驻(与 app 同寿命),每键两连
/// (readKeyInfo + readBytes)。调度由 SensorScheduler 单 actor 串行,
/// 无锁;@unchecked Sendable 由这一纪律担保(nettop provider 同款)。
final class SmcClient: @unchecked Sendable {
    private var conn: io_connect_t = 0

    private enum Selector: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    /// 与 AppleSMC user client 的结构体协议逐字节一致(stats SMCKeyData_t 同款,
    /// 含内核要求的对齐填充字段)。
    private struct KeyData {
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        struct KeyInfo {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var pLimitData = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes = (
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        ) as Bytes

        static let size = MemoryLayout<KeyData>.stride
    }

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) ==
            kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != IO_OBJECT_NULL else { return nil }
        var connection: io_connect_t = 0
        guard IOServiceOpen(device, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            IOObjectRelease(device)
            return nil
        }
        IOObjectRelease(device)
        conn = connection
    }

    deinit {
        if conn != 0 {
            IOServiceClose(conn)
        }
    }

    private func call(input: inout KeyData, output: inout KeyData) -> kern_return_t {
        var outputSize = KeyData.size
        return IOConnectCallStructMethod(
            conn,
            UInt32(Selector.kernelIndex.rawValue),
            &input,
            KeyData.size,
            &output,
            &outputSize
        )
    }

    /// 读一个键:dataType 原文 + 原始字节;键不在/读失败 → nil。
    func read(key: String) -> (dataType: String, bytes: [UInt8])? {
        guard key.utf8.count == 4 else { return nil }
        let fourCC = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var input = KeyData()
        var output = KeyData()

        input.key = fourCC
        input.data8 = Selector.readKeyInfo.rawValue
        guard call(input: &input, output: &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        let size = Int(output.keyInfo.dataSize)
        let dataType = fourCCString(output.keyInfo.dataType)

        input.data8 = Selector.readBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(size)
        guard call(input: &input, output: &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: min(size, 32))
        withUnsafeBytes(of: output.bytes) { raw in
            for index in bytes.indices where index < raw.count {
                bytes[index] = raw[index]
            }
        }
        return (dataType, bytes)
    }

    /// 全键枚举(#KEY 计数 + readIndex;发现结果调用方缓存)。
    func allKeys() -> [String] {
        guard let countValue = read(key: "#KEY"),
              let count = SmcValueDecoder.decode(dataType: countValue.dataType, bytes: countValue.bytes)
        else { return [] }
        var keys: [String] = []
        for index in 0 ..< Int(count) {
            var input = KeyData()
            var output = KeyData()
            input.data8 = Selector.readIndex.rawValue
            input.data32 = UInt32(index)
            guard call(input: &input, output: &output) == kIOReturnSuccess, output.result == 0 else { continue }
            keys.append(fourCCString(output.key))
        }
        return keys
    }

    /// FourCharCode → 4 字符字符串(键名/dataType 互转)。
    private func fourCCString(_ code: UInt32) -> String {
        [code >> 24, code >> 16, code >> 8, code].compactMap {
            UnicodeScalar($0 & 0xFF).map(String.init)
        }.joined()
    }
}

// MARK: - Live SMC 源

/// Darwin 薄适配器:发现一次(进程级缓存,键集 = T 前缀温度 ∪ F 前缀风扇 ∪
/// 电池顺手键 PPBR/PDTR——探针⑤全键清单的过滤),每轮逐键读原始字节;
/// 窗口不可见时由 provider 门控挡住全部 IOConnect 调用。
final class LiveSmcSource: SmcSource, @unchecked Sendable {
    private let client: SmcClient?
    /// 发现缓存:同进程只枚举一次(调度 actor 串行,无锁)。
    private var discoveredKeys: [String]?

    init() {
        client = SmcClient()
    }

    func read() -> SmcSnapshot? {
        guard let client else { return nil }
        let keys: [String]
        if let discoveredKeys {
            keys = discoveredKeys
        } else {
            let filtered = client.allKeys().filter { key in
                key.hasPrefix("T") || key.hasPrefix("F") || key == "PPBR" || key == "PDTR"
            }
            discoveredKeys = filtered
            keys = filtered
        }
        guard !keys.isEmpty else { return nil }

        var rawKeys: [SmcRawKey] = []
        rawKeys.reserveCapacity(keys.count)
        for key in keys {
            guard let value = client.read(key: key) else { continue }
            rawKeys.append(SmcRawKey(key: key, dataType: value.dataType, bytes: value.bytes))
        }
        guard !rawKeys.isEmpty else { return nil }
        return SmcSnapshot(keys: rawKeys, takenAt: Date())
    }
}

// MARK: - SMC 传感器 provider(p2-sensors/04,ADR-0004)

/// SMC 传感器:短档 `.every(seconds: 5)`(弹窗 ∨ 传感器页可见才读);坏值防御
/// 的"沿用旧值"档需要上一轮读数,provider 持有 previous——由 stateLock 串行
/// (5s UI 档与 30s 历史档两条 driver 的 tick 在调度 actor 外并发,2026-10-23
/// 审计②;源的 io_connect 同经此锁串行)。
final class SmcSensorProvider: SensorProvider, @unchecked Sendable {
    typealias Reading = SmcReading

    let cadence: SensorCadence = .every(seconds: 5)

    private let source: any SmcSource
    private let gate = SensorVisibilityGate()
    private let slot = SensorLastGoodBox<SmcReading>()
    private var previous: SmcReading?
    /// 双档串行锁:护坏值沿用链 previous 与源的 SMC 连接。
    private let stateLock = NSLock()

    var lastGood: SmcReading? {
        slot.current
    }

    init(source: any SmcSource = LiveSmcSource()) {
        self.source = source
    }

    func setVisible(_ visible: Bool) {
        _ = gate.setVisible(visible)
    }

    func snapshot() async -> SmcReading? {
        guard gate.isVisible else { return nil }
        return await historySnapshot()
    }

    /// 历史档读(p2-sensors/08):不看可见性闸;坏值防御的 previous 状态与
    /// UI 档共用(同一条坏值沿用链,档位切换不断账)。
    func historySnapshot() async -> SmcReading? {
        guard let raw = source.read() else { return nil }
        return foldLocked(raw)
    }

    /// NSLock 禁用于 async 上下文(Swift 6)——锁段拆进同步方法。
    private func foldLocked(_ raw: SmcSnapshot) -> SmcReading? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let reading = SmcReadingBuilder.make(from: raw, previous: previous) else {
            return nil // 折算失败不动 previous:沿用链不被一次坏载荷清零(审计②顺带)
        }
        previous = reading
        slot.store(reading)
        return reading
    }
}
