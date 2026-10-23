@testable import Pulse
@testable import PulseCore
import XCTest

// 蓝牙传感器测试(p2-sensors/06):provider 门控/合并收账用假源(零 IOBluetooth
// 依赖,且假载荷刻意让全部设备带电量——避免单测里真起 GATT 探针);Live 源只做
// "本机真读一次不崩 + 结构健全"冒烟(既有 Live 适配器测试同款纪律)。

/// 假蓝牙源:三路载荷全开关(默认全员带电量 = 不触发 GATT 探针)。
private final class FakeBluetoothSource: BluetoothSource, @unchecked Sendable {
    var paired: [PairedDeviceStatus]?
    var hid: [HidBatteryEntry] = []
    var cache: [CachedBatteryEntry] = []

    var poweredOn: Bool? {
        true
    }

    func readPaired() -> [PairedDeviceStatus]? {
        paired
    }

    func readHidBatteries() -> [HidBatteryEntry] {
        hid
    }

    func readCachedBatteries() -> [CachedBatteryEntry] {
        cache
    }
}

final class BluetoothSensorTests: XCTestCase {
    /// 全员带电量的标准载荷(妙控板 HID + QC35 缓存)。
    private func fullBatterySource() -> FakeBluetoothSource {
        let source = FakeBluetoothSource()
        source.paired = [
            PairedDeviceStatus(name: "妙控板", address: "d4-57-63-5d-bf-6b", isConnected: true, rawRSSI: -58),
            PairedDeviceStatus(name: "QC35", address: "2c-41-a1-c8-c5-01"),
        ]
        source.hid = [HidBatteryEntry(batteryPercent: 41, address: "d4-57-63-5d-bf-6b")]
        source.cache = [CachedBatteryEntry(batteryPercent: 80, address: "2c-41-a1-c8-c5-01")]
        return source
    }

    func testCadenceIsThirtySeconds() {
        // 节奏登记(票面口径):可见 30s 档,不可见停由门控保证。
        XCTAssertEqual(
            BluetoothSensorProvider(source: FakeBluetoothSource()).cadence,
            .every(seconds: 30)
        )
    }

    func testGateBlocksAllSourceReadsWhenInvisible() async {
        // 门控关:配对表都不碰(paired 调用计数为 0 级验证——读即返回 nil);
        // 门控开:三源合并交付。
        let source = fullBatterySource()
        let provider = BluetoothSensorProvider(source: source)

        provider.setVisible(false)
        let blocked = await provider.snapshot()
        XCTAssertNil(blocked)
        XCTAssertNil(provider.lastGood)

        provider.setVisible(true)
        let reading = await provider.snapshot()
        XCTAssertEqual(reading?.devices.count, 2)
        XCTAssertEqual(provider.lastGood?.devices.first?.batteryPercent, 41)
    }

    func testBluetoothUnavailableDeliversNothingAndKeepsLastGood() async {
        // 蓝牙栈不可用(readPaired nil):本轮不交付,lastGood 不动。
        let source = fullBatterySource()
        let provider = BluetoothSensorProvider(source: source)
        provider.setVisible(true)

        _ = await provider.snapshot()
        XCTAssertEqual(provider.lastGood?.devices.count, 2)

        source.paired = nil // 模拟蓝牙关
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.devices.count, 2)
    }

    func testGattBufferIsCollectedNextCycle() async {
        // GATT 收账口径:探针交付进缓冲,**下一轮**快照才进合并(取走制)。
        // 用"无锚样本"(不在配对表)钉行为——避免设备缺电量触发真 GATT 探针
        // (单测不转蓝牙栈,不碰用户耳机)。
        let provider = BluetoothSensorProvider(source: fullBatterySource())
        provider.setVisible(true)
        let first = await provider.snapshot()
        XCTAssertNil(first?.devices.first { $0.name == "路过的设备" })

        provider.appendGatt(GattBatteryEntry(batteryPercent: 30, name: "路过的设备"))
        let collected = await provider.snapshot()
        XCTAssertEqual(
            collected?.devices.first { $0.name == "路过的设备" }?.batteryPercent,
            30,
            "缓冲样本下一轮进合并"
        )

        let drained = await provider.snapshot()
        XCTAssertNil(drained?.devices.first { $0.name == "路过的设备" }, "缓冲是取走制,同一样本不进两轮")
    }

    /// 限时单发恢复盒(p2-audit/04 附带加固):IOBluetooth 首访可能阻塞等
    /// TCC 授权弹窗(无头测试宿主无人可点)或 bluetoothd 失速——5s 内取值,
    /// 超时恢复 .stalled 一次,晚到的读数丢弃。
    private enum PairedProbe: Sendable {
        case ok([PairedDeviceStatus]?)
        case stalled
    }

    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<PairedProbe, Never>

        init(_ continuation: CheckedContinuation<PairedProbe, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: PairedProbe) {
            lock.lock()
            let first = !resumed
            resumed = true
            lock.unlock()
            if first {
                continuation.resume(returning: result)
            }
        }
    }

    func testLivePairedSmokeOnThisMachine() async throws {
        // Live 冒烟:本机实探 6 台已配对(小米平板重复行,去重在合并器);
        // 只验原始载荷结构健全(名字/地址非空、地址可规整)。IOBluetooth 调用
        // 限时 5s——系统级健康另有 CLI 探针背书,宿主内阻塞(TCC 等待/蓝牙栈
        // 失速)时跳过不判败:60s fuse 上岗首日即抓到此测试真挂死(2026-10-23)。
        let source = LiveBluetoothSource()
        let probe: PairedProbe = await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            DispatchQueue.global().async {
                once.resume(.ok(source.readPaired()))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.resume(.stalled)
            }
        }
        guard case let .ok(paired) = probe else {
            throw XCTSkip("IOBluetooth 5s 未响应(疑似 TCC 授权等待/蓝牙栈失速)——本轮跳过冒烟")
        }
        guard let paired else {
            // 蓝牙栈可用但返回空(nil):软断言恒 nil 后放过。
            return
        }
        for device in paired {
            XCTAssertFalse(device.name?.isEmpty ?? true, "已配对设备名读到但为空")
            if let address = device.address {
                XCTAssertNotNil(BluetoothMerge.normalizeAddress(address), "地址无法规整:\(address)")
            }
        }
    }

    func testLiveHidSmokeOnThisMachine() {
        // Live 冒烟:HID 路(探针⑥实证开箱即用);有 BatteryPercent 的条目
        // 百分量级健全,地址回退链三者必居其一或全缺(全缺 = 级②③匹配)。
        let entries = LiveBluetoothSource().readHidBatteries()
        for entry in entries {
            XCTAssertTrue((0 ... 100).contains(entry.batteryPercent), "HID 电量量级异常:\(entry.batteryPercent)")
        }
        // 本机妙控板在场:至少一条 HID 电量(蓝牙开着时)。蓝牙关 = 空也成立,
        // 不硬性断言条数,只断言不崩 + 量级(上式)。
    }

    func testLiveCacheSmokeOnThisMachine() {
        // Live 冒烟:本机 macOS 26 系统 plist 无 DeviceCache 键(2026-10-22 实探)
        // → 空数组是常态;有键的机器上条目量级健全。
        for entry in LiveBluetoothSource().readCachedBatteries() {
            XCTAssertTrue((1 ... 100).contains(entry.batteryPercent), "缓存电量量级异常:\(entry.batteryPercent)")
        }
    }
}
