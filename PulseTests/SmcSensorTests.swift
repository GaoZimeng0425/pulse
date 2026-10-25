@testable import Pulse
@testable import PulseCore
import XCTest

// SMC 传感器测试(p2-sensors/04):provider 门控/坏值旧值档/lastGood 用假源,
// Live 源做"本机真读一次"冒烟(探针⑤实证免权限)。

private final class FakeSmcSource: SmcSource, @unchecked Sendable {
    var snapshots: [SmcSnapshot] = []
    private var index = 0

    func read() -> SmcSnapshot? {
        guard index < snapshots.count else { return nil }
        defer { index += 1 }
        return snapshots[index]
    }
}

final class SmcSensorTests: XCTestCase {
    @MainActor
    func testFeatureRegistersExactlyOneDriver() {
        // p2-review/06 根治:并发入口(双档两条驱动)收编成一条——previous 沿用链
        // 与 io_connect 的串行不再靠 p2-review/01 ① 的锁,靠"每 provider 一条驱动"
        // 的结构保证。锁已删,此断言钉住结构不被退回双驱动。
        let feature = SmcFeature(source: FakeSmcSource())
        XCTAssertEqual(feature.sensorDrivers().count, 1)
        feature.visibilityChanged(MonitorVisibility(popoverTab: .sensors))
        XCTAssertEqual(feature.sensorDrivers()[0].adaptiveInterval?(), 5)
        feature.visibilityChanged(MonitorVisibility())
        XCTAssertEqual(feature.sensorDrivers()[0].adaptiveInterval?(), 30)
    }

    private func sp78(_ value: Double) -> [UInt8] {
        let scaled = Int(value * 256)
        return [UInt8((scaled >> 8) & 0xFF), UInt8(scaled & 0xFF)]
    }

    func testGateDrivesIntervalNotReads() async {
        // p2-review/06 分档单循环:闸只驱动节奏(可见 5s / 不可见 30s),不再挡读。
        let source = FakeSmcSource()
        source.snapshots = [
            SmcSnapshot(keys: [
                SmcRawKey(key: "Tp01", dataType: "sp78", bytes: sp78(45)),
            ], takenAt: Date(timeIntervalSince1970: 0)),
        ]
        let provider = SmcSensorProvider(source: source)

        provider.setVisible(false)
        XCTAssertEqual(provider.adaptiveInterval?(), 30)
        let hiddenRead = await provider.snapshot()
        XCTAssertEqual(hiddenRead?.knownTemps.first?.value ?? -1, 45, accuracy: 1e-9, "闸关照样读(历史档同一条循环)")

        provider.setVisible(true)
        XCTAssertEqual(provider.adaptiveInterval?(), 5)
    }

    func testFrozenSensorKeepsPreviousAcrossRounds() async {
        // 冻死值第二轮沿用旧值(provider 持 previous 跨轮)。
        let source = FakeSmcSource()
        source.snapshots = [
            SmcSnapshot(
                keys: [SmcRawKey(key: "Tp01", dataType: "sp78", bytes: sp78(45))],
                takenAt: Date(timeIntervalSince1970: 0)
            ),
            SmcSnapshot(
                keys: [SmcRawKey(key: "Tp01", dataType: "sp78", bytes: sp78(6.2))],
                takenAt: Date(timeIntervalSince1970: 5)
            ),
        ]
        let provider = SmcSensorProvider(source: source)
        provider.setVisible(true)

        _ = await provider.snapshot()
        let second = await provider.snapshot()
        XCTAssertEqual(second?.knownTemps.first?.value ?? -1, 45, accuracy: 1e-9)
    }

    func testCadenceIsFiveSeconds() {
        let provider = SmcSensorProvider(source: FakeSmcSource())
        XCTAssertEqual(provider.cadence, .every(seconds: 5))
    }

    func testLiveSmokeOnThisMachine() async {
        // Live 冒烟:本机真读一次(Apple Silicon 必有 SMC);命名传感器在场
        // (M4 的 P/E 核与 GPU 核键都在探针⑤清单里),电池 PPBR 可读。
        let provider = SmcSensorProvider(source: LiveSmcSource())
        provider.setVisible(true)

        let reading = await provider.snapshot()
        XCTAssertNotNil(reading)
        XCTAssertGreaterThan(reading?.knownTemps.count ?? 0, 3, "命名温度传感器应 >3(P/E/GPU 核)")
        XCTAssertNotNil(reading?.fans.isEmpty == false ? reading?.fans.first?.rpm : nil, "应有风扇读数")
        XCTAssertNotNil(reading?.batteryPowerWatts, "PPBR 应可读(探针⑤实证)")
    }
}
