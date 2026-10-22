@testable import PulseCore
import XCTest

/// 接缝:声音读数折算(p2-sensors/05,纯逻辑)。只测外部行为(载荷进 → 读数出),
/// 防御分支全部合成载荷覆盖——标量折百分数 / 钳位 / nil 穿透 / 静音独立位。
final class SoundModelTests: XCTestCase {
    func testScalarFoldsToPercent() {
        // 标量 0–1 折 0–100。
        let reading = SoundReading.make(from: SoundRawReading(
            deviceName: "MacBook Pro Speakers",
            volumeScalar: 0.42,
            isMuted: false
        ))
        XCTAssertEqual(reading.deviceName, "MacBook Pro Speakers")
        XCTAssertEqual(reading.volumePercent ?? -1, 42, accuracy: 0.01)
        XCTAssertEqual(reading.isMuted, false)
    }

    func testClampingOutOfRangeScalars() {
        // 个别驱动回报越界:钳 0…100(GPU 利用率钳位同族防御)。
        let over = SoundReading.make(from: SoundRawReading(volumeScalar: 1.8))
        XCTAssertEqual(over.volumePercent, 100)

        let negative = SoundReading.make(from: SoundRawReading(volumeScalar: -0.5))
        XCTAssertEqual(negative.volumePercent, 0)
    }

    func testNilPassthroughForMissingFields() {
        // 设备不控音量/静音不可读:nil 穿透占位,不伪造 0%(0 是真读数)。
        let reading = SoundReading.make(from: SoundRawReading(deviceName: "USB Device"))
        XCTAssertEqual(reading.deviceName, "USB Device")
        XCTAssertNil(reading.volumePercent)
        XCTAssertNil(reading.isMuted)

        // 有设备名但空串 = 无名设备,同样如实透传。
        let unnamed = SoundReading.make(from: SoundRawReading(deviceName: "", volumeScalar: 0.5))
        XCTAssertEqual(unnamed.deviceName, "")
    }

    func testMuteIsIndependentOfVolume() {
        // 静音时音量值保留(mute 独立属性,解除静音不用重学位置)。
        let muted = SoundReading.make(from: SoundRawReading(volumeScalar: 0.6, isMuted: true))
        XCTAssertEqual(muted.isMuted, true)
        XCTAssertEqual(muted.volumePercent ?? -1, 60, accuracy: 0.01)
    }

    func testBoundaryScalars() {
        XCTAssertEqual(SoundReading.make(from: SoundRawReading(volumeScalar: 0)).volumePercent, 0)
        XCTAssertEqual(SoundReading.make(from: SoundRawReading(volumeScalar: 1)).volumePercent, 100)
    }
}
