@testable import Pulse
@testable import PulseCore
import XCTest

// 蓝牙传感器测试(p2-sensors/06):provider 门控/合并收账用假源 + 假 GATT 探针
// (零 IOBluetooth / CoreBluetooth 依赖)。IOBluetooth 配对表冒烟已删(p2-review/02;
// 测试纪律:蓝牙栈不进单测,宿主内可能卡 TCC 等待)——系统级健康由 CLI 探针背书。
// 剩余 Live 冒烟只读 IORegistry / 系统 plist,不碰蓝牙栈与 TCC。

/// 假蓝牙源:三路载荷全开关(默认全员带电量 = 不触发 GATT 探针)。
private final class FakeBluetoothSource: BluetoothSource, @unchecked Sendable {
    var paired: [PairedDeviceStatus]?
    var hid: [HidBatteryEntry] = []
    var cache: [CachedBatteryEntry] = []

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

/// 假 GATT 探针(p2-review/02 接缝):只记账,不碰 CoreBluetooth——单测不转蓝牙栈。
private final class FakeGattProbe: GattBatteryProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [[String]] = []
    private var cancels = 0

    var startedNames: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    func start(wanting names: [String], deliver _: @escaping @Sendable (GattBatteryEntry) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        starts.append(names)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancels += 1
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
            BluetoothSensorProvider(source: FakeBluetoothSource(), probe: FakeGattProbe()).cadence,
            .every(seconds: 30)
        )
    }

    func testGateBlocksAllSourceReadsWhenInvisible() async {
        // 门控关:配对表都不碰(paired 调用计数为 0 级验证——读即返回 nil);
        // 门控开:三源合并交付。
        let source = fullBatterySource()
        let provider = BluetoothSensorProvider(source: source, probe: FakeGattProbe())

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
        let provider = BluetoothSensorProvider(source: source, probe: FakeGattProbe())
        provider.setVisible(true)

        _ = await provider.snapshot()
        XCTAssertEqual(provider.lastGood?.devices.count, 2)

        source.paired = nil // 模拟蓝牙关
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.devices.count, 2)
    }

    func testClosingGateCancelsInFlightGattProbe() async {
        // p2-review/02:闸关(开关关 / 不可见 / 授权失效都折成 setVisible(false))
        // = 立即停采,在途 GATT 探针随之取消,不再扫满 ~20s。
        let source = fullBatterySource()
        source.paired?.append(PairedDeviceStatus(name: "缺电量耳机", address: "aa-aa-aa-aa-aa-09"))
        let probe = FakeGattProbe()
        let provider = BluetoothSensorProvider(source: source, probe: probe)

        provider.setVisible(true)
        _ = await provider.snapshot()
        XCTAssertEqual(probe.startedNames, [["缺电量耳机"]], "缺电量设备起探针")
        XCTAssertEqual(probe.cancelCount, 0)

        provider.setVisible(false)
        XCTAssertEqual(probe.cancelCount, 1, "闸关即取消在途探针")
    }

    func testGattBufferIsCollectedNextCycle() async {
        // GATT 收账口径:探针交付进缓冲,**下一轮**快照才进合并(取走制)。
        // 用"无锚样本"(不在配对表)钉行为——避免设备缺电量触发真 GATT 探针
        // (单测不转蓝牙栈,不碰用户耳机)。
        let provider = BluetoothSensorProvider(source: fullBatterySource(), probe: FakeGattProbe())
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
