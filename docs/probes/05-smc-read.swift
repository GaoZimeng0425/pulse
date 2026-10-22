// 探针⑤(2026-10-22,p2-sensors/01):AppleSMC 用户态连接真读数——研究档案 §5.5 的验证。
// SMC 客户端移植自 stats(MIT,https://github.com/exelban/stats 的 SMC/smc.swift,
// Copyright © 2021 Serhii Mytrovtsiy),只取**只读路径**(open/call/read/getValue/
// getAllKeys),写与风扇控制不移植。产出:
//   1. 连接免权限门槛实证(IOServiceOpen 无弹窗);
//   2. 风扇 FNum/F?Ac/F?Mn/F?Mx/F?ID 真读数;
//   3. 全键枚举(#KEY 计数 + readIndex)→ T/V/P/I/F 前缀键清单 + 全部温度键读数,
//      作为 p2-sensors/04 传感器命名表的种子数据;
//   4. 各 dataType 解码抽查(sp78/fpe2/{fds)。
// 编译运行:swiftc -O 05-smc-read.swift -o /tmp/p5 && /tmp/p5 > 05-smc-read.output.txt

// swiftlint:disable type_name
// 原因:SMCKeyData_t/SMCVal_t 等类型名刻意保留 stats 源(SMC/smc.swift)的对应拼写,
// 04 票正式移植时可一并评估改名;探针以可对照为先。

import Foundation
import IOKit

// MARK: - stats SMC 客户端(只读裁剪版,结构体布局必须与 AppleSMC user client 逐字节一致)

enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

struct SMCKeyData_t {
    typealias SMCBytes_t = (
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8
    )
    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
    var pLimitData = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0)
    )
}

struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    func toString() -> String {
        String(describing: UnicodeScalar(self >> 24 & 0xFF)!) +
            String(describing: UnicodeScalar(self >> 16 & 0xFF)!) +
            String(describing: UnicodeScalar(self >> 8 & 0xFF)!) +
            String(describing: UnicodeScalar(self & 0xFF)!)
    }
}

extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

final class SMC {
    private var conn: io_connect_t = 0

    init() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) ==
            kIOReturnSuccess else {
            print("Error IOServiceGetMatchingServices")
            exit(1)
        }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { print("Error: no AppleSMC device")
            exit(1)
        }
        guard IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            print("Error IOServiceOpen(可能需要权限?)")
            exit(1)
        }
        IOObjectRelease(device)
        print("AppleSMC 连接建立(无权限弹窗)")
    }

    deinit { _ = IOServiceClose(conn) }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }

    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        guard value.pointee.key.count == 4, value.pointee.key.utf8.count == 4 else { return kIOReturnBadArgument }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: value.pointee.key)
        input.data8 = SMCKeys.readKeyInfo.rawValue
        var result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        if output.result == 0x84 {
            return kIOReturnNotFound
        }
        if output.result != 0 {
            return kIOReturnError
        }
        let keyInfo = output.keyInfo

        value.pointee.dataSize = UInt32(keyInfo.dataSize)
        value.pointee.dataType = keyInfo.dataType.toString()
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        if output.result == 0x84 {
            return kIOReturnNotFound
        }
        if output.result != 0 {
            return kIOReturnError
        }
        memcpy(&value.pointee.bytes, &output.bytes, min(Int(value.pointee.dataSize), value.pointee.bytes.count))
        return kIOReturnSuccess
    }

    func getValue(_ key: String) -> Double? {
        var val = SMCVal_t(key)
        let result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }
        guard val.dataSize > 0 else { return nil }
        if val.bytes.first(where: { $0 != 0 }) == nil, val.key != "FS! ", !val.key.hasSuffix("Md"),
           !val.key.hasSuffix("md") {
            return nil
        }
        switch val.dataType {
        case "ui8 ": return Double(val.bytes[0])
        case "ui16": return Double(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1]))
        case "ui32": return Double(UInt32(val.bytes[0]) << 24 | UInt32(val.bytes[1]) << 16 | UInt32(val.bytes[2]) << 8 |
                UInt32(val.bytes[3]))
        case "sp78": return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 256
        case "sp87": return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 128
        case "sp96": return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 64
        case "spf0": return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
        case "fpe2": return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
        case "flt ": return val.bytes.withUnsafeBytes { Double($0.load(as: Float.self)) }
        default: return nil
        }
    }

    func getStringValue(_ key: String) -> String? {
        var val = SMCVal_t(key)
        guard read(&val) == kIOReturnSuccess, val.dataSize > 0, val.dataType == "{fds" else { return nil }
        return val.bytes[4 ..< 16].compactMap { $0 == 0 ? nil : UnicodeScalar($0) }.map(String.init).joined()
    }

    func getAllKeys() -> [String] {
        guard let keysNum = getValue("#KEY") else { print("ERROR: #KEY 不可读")
            return []
        }
        print("总键数 #KEY = \(Int(keysNum))")
        var list: [String] = []
        for i in 0 ..< Int(keysNum) {
            var input = SMCKeyData_t()
            var output = SMCKeyData_t()
            input.data8 = SMCKeys.readIndex.rawValue
            input.data32 = UInt32(i)
            guard call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess,
                  output.result == 0 else { continue }
            list.append(output.key.toString())
        }
        return list
    }
}

// MARK: - 探针主体

let smc = SMC()

print("\n== 风扇 ==")
if let fanCount = smc.getValue("FNum") {
    print("FNum = \(Int(fanCount))")
    for i in 0 ..< Int(fanCount) {
        let ac = smc.getValue("F\(i)Ac").map { Int($0) } ?? nil
        let mn = smc.getValue("F\(i)Mn").map { Int($0) } ?? nil
        let mx = smc.getValue("F\(i)Mx").map { Int($0) } ?? nil
        let name = smc.getStringValue("F\(i)ID")
        print("  F\(i): name=\(name ?? "?") actual=\(ac.map { "\($0) rpm" } ?? "nil") min=\(mn ?? 0) max=\(mx ?? 0)")
    }
} else {
    print("FNum 不可读")
}

print("\n== 全键枚举(命名表种子) ==")
let t0 = Date()
let allKeys = smc.getAllKeys()
let elapsed = Date().timeIntervalSince(t0)
var byPrefix: [Character: Int] = [:]
for k in allKeys {
    byPrefix[k.first ?? "?", default: 0] += 1
}

print("枚举到 \(allKeys.count) 键,耗时 \(String(format: "%.1f", elapsed * 1000)) ms")
print("首字母分布(前 12):", byPrefix.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key)=\($0.value)" }, "…")
let interesting = allKeys.filter { "TVPIF".contains($0.first ?? "?") }
print("T/V/P/I/F 前缀键共 \(interesting.count) 个(04 票命名表候选域)")
print(interesting.joined(separator: " "))

print("\n== 温度键全读数(sp78 等) ==")
var temps: [(String, Double)] = []
for k in allKeys where k.hasPrefix("T") {
    if let v = smc.getValue(k), v > 1, v < 120 {
        temps.append((k, v))
    }
}

print("读到合理温度值的键 \(temps.count) 个:")
for (k, v) in temps.sorted(by: { $0.1 > $1.1 }) {
    print(String(format: "  %@ = %.1f °C", k, v))
}

print("\n== 电池功率顺手键(04 票 PPBR/PDTR) ==")
for k in ["PPBR", "PDTR", "ACEN", "CHWP", "CH0I"] {
    print("  \(k) = \(smc.getValue(k).map { String(format: "%.3f", $0) } ?? "nil")")
}
