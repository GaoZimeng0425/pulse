@testable import Pulse
@testable import PulseCore
import XCTest

// 声音传感器测试(p2-sensors/05):provider 行为用假源(零 CoreAudio 依赖),
// Live 源只做"本机真读一次不崩 + 结构健全"冒烟(既有 Live 适配器测试同款纪律)。

/// 假声音源:固定载荷开关(测 lastGood 语义)。
private final class FakeSoundSource: SoundSource, @unchecked Sendable {
    var payload: SoundRawReading?

    func read() -> SoundRawReading? {
        payload
    }
}

final class SoundSensorTests: XCTestCase {
    func testCadenceIsOnEvent() {
        // 节奏登记(票面口径):事件档,零轮询。
        let provider = SoundSensorProvider(source: FakeSoundSource(), wakeups: { nil })
        XCTAssertEqual(provider.cadence, .onEvent)
    }

    func testFoldingAndLastGoodSurvivesFailure() async {
        // 读成功 = 折算后交付并记 lastGood;读失败(nil)= 不动 lastGood。
        let source = FakeSoundSource()
        source.payload = SoundRawReading(deviceName: "Speakers", volumeScalar: 0.42, isMuted: true)
        let provider = SoundSensorProvider(source: source, wakeups: { nil })

        let read = await provider.snapshot()
        XCTAssertEqual(read?.deviceName, "Speakers")
        XCTAssertEqual(read?.volumePercent ?? -1, 42, accuracy: 0.01)
        XCTAssertEqual(read?.isMuted, true)

        source.payload = nil // 模拟读失败(无音频子系统)
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.deviceName, "Speakers")
    }

    func testWakeupStreamYieldsFirstFrameImmediately() async throws {
        // 事件流形状:构造即首唤醒(首帧就有数),随后事件再唤醒——用假流钉行为。
        let provider = SoundSensorProvider(
            source: FakeSoundSource(),
            wakeups: {
                AsyncStream { continuation in
                    continuation.yield() // 首唤醒
                    continuation.yield() // 属性变化
                    continuation.finish() // 假流必须收尾(build 闭包返回不结束流)
                }
            }
        )
        var wakes = 0
        for await _ in try XCTUnwrap(provider.wakeups()) {
            wakes += 1
        }
        XCTAssertEqual(wakes, 2, "首唤醒 + 一次属性变化")
    }

    func testLiveSmokeOnThisMachine() {
        // Live 冒烟:本机真读一次不崩;有默认输出设备时结构健全
        // (折算与钳位在核心包,这里只验原始载荷量级)。
        let reading = LiveSoundSource().read()
        if let scalar = reading?.volumeScalar {
            XCTAssertTrue(scalar >= -0.01 && scalar <= 1.01, "原始音量标量量级异常:\(scalar)")
        }
        if let name = reading?.deviceName {
            XCTAssertFalse(name.isEmpty, "设备名读到但为空串")
        }
    }
}
