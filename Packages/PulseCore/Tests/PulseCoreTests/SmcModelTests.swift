@testable import PulseCore
import XCTest

/// 接缝:SMC 折算(p2-sensors/04,纯逻辑)。解码表(sp78/fpe2/{fds)、坏值
/// 两档防御、命名表命中/表外、派生 Average/Hottest、风扇与电池顺手键——
/// 全部合成载荷覆盖。客户端实证与键表种子:探针⑤(2026-10-22)。
final class SmcModelTests: XCTestCase {
    // MARK: - 解码

    func testDecoderTypes() {
        // sp78 ÷256(温度)、fpe2 移位(风扇 rpm)、ui8/ui16、flt。
        XCTAssertEqual(SmcValueDecoder.decode(dataType: "sp78", bytes: [0x1E, 0x80]) ?? -1, 30.5, accuracy: 1e-9)
        XCTAssertEqual(
            SmcValueDecoder.decode(dataType: "fpe2", bytes: [0x9C, 0x40]) ?? -1,
            10000,
            accuracy: 1e-9
        ) // (156<<6)+(64>>2)
        XCTAssertEqual(SmcValueDecoder.decode(dataType: "ui8 ", bytes: [7]), 7)
        XCTAssertEqual(SmcValueDecoder.decode(dataType: "ui16", bytes: [1, 2]), 258)
        XCTAssertEqual(SmcValueDecoder.decode(dataType: "spf0", bytes: [0, 47]), 47)
        XCTAssertNil(SmcValueDecoder.decode(dataType: "wxyz", bytes: [1, 2])) // 未知类型 → nil
    }

    func testFdsStringDecode() {
        // F?ID 的 {fds:第 4…16 字节可见字符(风扇命名)。
        var bytes = [UInt8](repeating: 0, count: 16)
        let name = "CPU"
        for (index, scalar) in name.utf8.enumerated() {
            bytes[4 + index] = scalar
        }
        XCTAssertEqual(SmcValueDecoder.decodeString(dataType: "{fds", bytes: bytes), "CPU")
        XCTAssertNil(SmcValueDecoder.decodeString(dataType: "sp78", bytes: bytes))
    }

    // MARK: - 坏值两档防御

    func testBadValueTiers() {
        // ① ≤0 或 >110 丢弃;② 1…10 沿用旧值,首轮无旧值丢弃;正常值透传。
        XCTAssertNil(SmcReadingBuilder.sanitized(0, previous: 55))
        XCTAssertNil(SmcReadingBuilder.sanitized(-1, previous: 55))
        XCTAssertNil(SmcReadingBuilder.sanitized(114.3, previous: 55)) // 探针⑤的 TCMz 哨兵位
        XCTAssertEqual(SmcReadingBuilder.sanitized(6.2, previous: 55) ?? -1, 55, accuracy: 1e-9) // 探针⑤的 Ta## 冻死位
        XCTAssertNil(SmcReadingBuilder.sanitized(6.2, previous: nil))
        XCTAssertEqual(SmcReadingBuilder.sanitized(45, previous: nil) ?? -1, 45, accuracy: 1e-9)
    }

    // MARK: - 折算入口

    private func snapshot(
        _ pairs: [(String, String, [UInt8])],
        at date: Date = Date(timeIntervalSince1970: 0)
    ) -> SmcSnapshot {
        SmcSnapshot(keys: pairs.map { SmcRawKey(key: $0.0, dataType: $0.1, bytes: $0.2) }, takenAt: date)
    }

    private func sp78(_ value: Double) -> [UInt8] {
        let scaled = Int(value * 256)
        return [UInt8((scaled >> 8) & 0xFF), UInt8(scaled & 0xFF)]
    }

    func testMakeNamesKnownAndUnknown() {
        // 命名表命中(Tp01 = CPU performance core 1)进 knownTemps 带组;
        // 表外键(TZ99)进 unknownTemps 归未知组;坏值(6.2 无旧值)被丢。
        let reading = SmcReadingBuilder.make(
            from: snapshot([
                ("Tp01", "sp78", sp78(45)),
                ("TZ99", "sp78", sp78(40)),
                ("Ta00", "sp78", sp78(6.2)), // 冻死值,首轮丢弃
            ]),
            previous: nil
        )
        XCTAssertEqual(reading?.knownTemps.count, 1)
        XCTAssertEqual(reading?.knownTemps.first?.name, "CPU performance core 1")
        XCTAssertEqual(reading?.knownTemps.first?.group, .cpu)
        XCTAssertEqual(reading?.unknownTemps.count, 1)
        XCTAssertEqual(reading?.unknownTemps.first?.group, .unknown)
    }

    func testMakeDerivedAverageAndHottest() {
        // 派生:Average 只收 average 标记(Tp01/05 每核有标记,Tp0P Powerboard 无);
        // Hottest 收组内全部。
        let reading = SmcReadingBuilder.make(
            from: snapshot([
                ("Tp01", "sp78", sp78(40)),
                ("Tp05", "sp78", sp78(60)),
                ("Tp0P", "sp78", sp78(65)), // Powerboard,cpu 组但无 average 标记
                ("Tg05", "sp78", sp78(50)),
            ]),
            previous: nil
        )
        // 表内 Tp01/Tp05/Tp0P 三键全带 average 标记(AS 段落的 P 核行),
        // Average = (40+60+65)/3;Hottest = 组内最大。
        XCTAssertEqual(reading?.derived.cpuAverage ?? -1, 55, accuracy: 1e-9)
        XCTAssertEqual(reading?.derived.cpuHottest ?? -1, 65, accuracy: 1e-9)
        XCTAssertEqual(reading?.derived.gpuHottest ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(reading?.derived.gpuAverage ?? -1, 50, accuracy: 1e-9) // Tg05 同带标记
        XCTAssertNil(reading?.derived.socHottest)
    }

    func testMakeFansAndBatteryKeys() {
        // FNum=1(探针⑤本机实测)+ F0Ac/Mn/Mx + PPBR/PDTR 顺手键。
        let reading = SmcReadingBuilder.make(
            from: snapshot([
                ("FNum", "ui8 ", [1]),
                ("F0Ac", "fpe2", [0x9C, 0x40]), // (156<<6)+(64>>2) = 10000
                ("F0Mn", "fpe2", [0x24, 0x40]), // (36<<6)+16 = 2320 ≈ 探针实测 2317 同数量级
                ("F0Mx", "fpe2", [0x66, 0x00]), // (102<<6) = 6528 ≈ 探针实测 6550
                ("PPBR", "sp78", sp78(1.309)), // 探针⑤实测 1.309 W
                ("PDTR", "sp78", sp78(47.96)),
                ("Tp01", "sp78", sp78(45)),
            ]),
            previous: nil
        )
        XCTAssertEqual(reading?.fans.count, 1)
        XCTAssertEqual(reading?.fans.first?.rpm, 10000)
        XCTAssertEqual(reading?.fans.first?.minRpm, 2320)
        XCTAssertEqual(reading?.fans.first?.maxRpm, 6528)
        XCTAssertEqual(reading?.batteryPowerWatts ?? -1, 1.309, accuracy: 0.01)
        XCTAssertEqual(reading?.adapterWatts ?? -1, 47.96, accuracy: 0.01)
    }

    func testPreviousValueSurvivesFrozenSensor() {
        // 冻死值(6.2)在第二轮被旧值顶替,同键读数不回跳。
        let first = SmcReadingBuilder.make(
            from: snapshot([("Tp01", "sp78", sp78(45))]),
            previous: nil
        )
        let second = SmcReadingBuilder.make(
            from: snapshot([("Tp01", "sp78", sp78(6.2))]),
            previous: first
        )
        XCTAssertEqual(second?.knownTemps.first?.value ?? -1, 45, accuracy: 1e-9)
    }

    func testNamingTableWildcardAndCounts() {
        // 通配形(TC%c → 任意单字符尾)与表规模(移植完整性哨兵:255±若
        // 上游表变化会在此炸)。
        XCTAssertNotNil(SmcNamingTable.name(for: "TC1c"))
        XCTAssertNotNil(SmcNamingTable.name(for: "Tp01"))
        XCTAssertNil(SmcNamingTable.name(for: "ZZ99"))
        XCTAssertTrue(SmcNamingTable.entries.count > 200)
    }
}
