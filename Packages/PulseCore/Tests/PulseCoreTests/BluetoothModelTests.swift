@testable import PulseCore
import XCTest

/// 接缝:蓝牙三源电量合并(p2-sensors/06,纯逻辑)。规则出处
/// docs/research/sensor-impl-comparison.md §2.8:三级匹配(规整地址 → 唯一名 →
/// 唯一厂商/产品 ID)、歧义即弃、缓存电量 1 当 100 解、RSSI 哨兵归未知。
final class BluetoothModelTests: XCTestCase {
    // MARK: 地址规整

    func testAddressNormalization() {
        XCTAssertEqual(BluetoothMerge.normalizeAddress("d4-57-63-5d-bf-6b"), "d457635dbf6b")
        XCTAssertEqual(BluetoothMerge.normalizeAddress("D4:57:63:5D:BF:6B"), "d457635dbf6b")
        XCTAssertEqual(BluetoothMerge.normalizeAddress("  d457635DBF6b "), "d457635dbf6b")
        XCTAssertNil(BluetoothMerge.normalizeAddress(""))
        XCTAssertNil(BluetoothMerge.normalizeAddress("---"))
    }

    // MARK: 级①地址匹配 + 锚去重

    func testHidBatteryAttachesByAddress() {
        // 妙控板实探形状:HID 地址 `d4-57-63-5d-bf-6b` 与 IOBluetooth 地址串相等。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "妙控板", address: "d4-57-63-5d-bf-6b", isConnected: true, rawRSSI: -58)],
            hid: [HidBatteryEntry(batteryPercent: 41, productName: "妙控板", address: "d4-57-63-5d-bf-6b")],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.count, 1)
        XCTAssertEqual(reading.devices[0].batteryPercent, 41)
        XCTAssertEqual(reading.devices[0].batterySource, .hid)
        XCTAssertEqual(reading.devices[0].rssi, -58)
        XCTAssertTrue(reading.devices[0].isConnected)
    }

    func testPairedDuplicatesCollapseByAddress() {
        // IOBluetooth 实探:小米平板在 pairedDevices() 出现两次——按规整地址去重,
        // 连接态 OR。
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: "平板", address: "08-b3-39-48-01-a6", isConnected: false),
                PairedDeviceStatus(name: "平板", address: "08:B3:39:48:01:A6", isConnected: true),
            ],
            hid: [],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.count, 1)
        XCTAssertTrue(reading.devices[0].isConnected)
    }

    // MARK: 级②名匹配 + 歧义即弃

    func testGattBatteryAttachesByUniqueName() {
        // GATT 样本只有名字(核心蓝牙 identifier 是 UUID 非地址):名在锚侧唯一才挂。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "Bose QC35 II", address: "2c-41-a1-c8-c5-01")],
            hid: [],
            cache: [],
            gatt: [GattBatteryEntry(batteryPercent: 80, name: "Bose QC35 II")]
        )
        XCTAssertEqual(reading.devices.first?.batteryPercent, 80)
        XCTAssertEqual(reading.devices.first?.batterySource, .gatt)
    }

    func testAmbiguousNameIsDroppedNotMisattributed() {
        // 锚侧两台同名:名字匹配歧义即弃——不给任何一台挂错电量,条目走无锚行。
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: "同款耳机", address: "aa-aa-aa-aa-aa-01"),
                PairedDeviceStatus(name: "同款耳机", address: "aa-aa-aa-aa-aa-02"),
            ],
            hid: [],
            cache: [],
            gatt: [GattBatteryEntry(batteryPercent: 55, name: "同款耳机")]
        )
        XCTAssertEqual(reading.devices.filter(\.isConnected).count, 0)
        XCTAssertNil(reading.devices.first { $0.normalizedAddress?.hasSuffix("01") == true }?.batteryPercent)
        XCTAssertNil(reading.devices.first { $0.normalizedAddress?.hasSuffix("02") == true }?.batteryPercent)
        // 无锚行保住读数(不丢数据,只是不知道是谁的)。
        XCTAssertEqual(reading.devices.last?.name, "同款耳机")
        XCTAssertEqual(reading.devices.last?.batteryPercent, 55)
    }

    // MARK: 级③厂商/产品 ID 匹配

    func testVendorProductMatchingFiresWhenUnique() {
        // 地址缺席、名字对不上,但厂商/产品 ID 锚侧唯一 → 级③挂上。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "手柄", address: "b2-2f-35-a4-75-f3", vendorID: 0x1234, productID: 0x5678)],
            hid: [HidBatteryEntry(
                batteryPercent: 66,
                productName: "GameSir Nova",
                address: nil,
                vendorID: 0x1234,
                productID: 0x5678
            )],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.first?.batteryPercent, 66)
        XCTAssertEqual(reading.devices.first?.batterySource, .hid)
    }

    // MARK: 源②坑口径

    func testCacheBatteryOneMeansHundred() {
        // 缓存电量 1 实为 100(stats readers.swift:339-341 同款坑口径)。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "QC35", address: "2c-41-a1-c8-c5-01")],
            hid: [],
            cache: [CachedBatteryEntry(batteryPercent: 1, name: "QC35", address: "2c:41:a1:c8:c5:01")],
            gatt: []
        )
        XCTAssertEqual(reading.devices.first?.batteryPercent, 100)
        XCTAssertEqual(reading.devices.first?.batterySource, .cache)

        // 真 1% 的其它值不动:2 就是 2。
        let honest = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "QC35", address: "2c-41-a1-c8-c5-01")],
            hid: [],
            cache: [CachedBatteryEntry(batteryPercent: 2, name: "QC35", address: "2c-41-a1-c8-c5-01")],
            gatt: []
        )
        XCTAssertEqual(honest.devices.first?.batteryPercent, 2)
    }

    // MARK: 多源优先级

    func testHidBeatsCacheBeatsGatt() {
        let paired = [PairedDeviceStatus(name: "妙控板", address: "d4-57-63-5d-bf-6b")]
        let hidOnly = BluetoothMerge.merge(
            paired: paired,
            hid: [HidBatteryEntry(batteryPercent: 41, address: "d4-57-63-5d-bf-6b")],
            cache: [CachedBatteryEntry(batteryPercent: 99, address: "d4-57-63-5d-bf-6b")],
            gatt: [GattBatteryEntry(batteryPercent: 1, name: "妙控板")]
        )
        XCTAssertEqual(hidOnly.devices.first?.batteryPercent, 41)
        XCTAssertEqual(hidOnly.devices.first?.batterySource, .hid)

        let cacheVsGatt = BluetoothMerge.merge(
            paired: paired,
            hid: [],
            cache: [CachedBatteryEntry(batteryPercent: 99, address: "d4-57-63-5d-bf-6b")],
            gatt: [GattBatteryEntry(batteryPercent: 70, name: "妙控板")]
        )
        XCTAssertEqual(cacheVsGatt.devices.first?.batteryPercent, 99)
        XCTAssertEqual(cacheVsGatt.devices.first?.batterySource, .cache)
    }

    // MARK: RSSI 哨兵

    func testRssiSentinelsBecomeUnknown() {
        // RSSI ≥0(0 空值 / 127 哨兵)= 无读数;负 dBm 才有效。
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: "甲", address: "aa-aa-aa-aa-aa-01", rawRSSI: 0),
                PairedDeviceStatus(name: "乙", address: "aa-aa-aa-aa-aa-02", rawRSSI: 127),
                PairedDeviceStatus(name: "丙", address: "aa-aa-aa-aa-aa-03", rawRSSI: -64),
            ],
            hid: [],
            cache: [],
            gatt: []
        )
        XCTAssertNil(reading.devices.first { $0.name == "甲" }?.rssi)
        XCTAssertNil(reading.devices.first { $0.name == "乙" }?.rssi)
        XCTAssertEqual(reading.devices.first { $0.name == "丙" }?.rssi, -64)
    }

    // MARK: 无锚行 / 空态 / 排序

    func testUnmatchedBatteryBecomesOwnRowDeduped() {
        // GATT 扫到未配对设备:单独成行;同址/同名样本去重。
        let reading = BluetoothMerge.merge(
            paired: [],
            hid: [],
            cache: [],
            gatt: [
                GattBatteryEntry(batteryPercent: 30, name: "路过的新设备"),
                GattBatteryEntry(batteryPercent: 30, name: "路过的新设备"),
            ]
        )
        XCTAssertEqual(reading.devices.count, 1)
        XCTAssertEqual(reading.devices[0].batteryPercent, 30)
        XCTAssertFalse(reading.devices[0].isConnected)
    }

    func testEmptyEverythingIsEmpty() {
        // 蓝牙关/无配对/无样本:安静空表,不崩不伪造。
        let reading = BluetoothMerge.merge(paired: [], hid: [], cache: [], gatt: [])
        XCTAssertTrue(reading.devices.isEmpty)
    }

    func testConnectedDevicesSortFirst() {
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: "乙已连", address: "aa-aa-aa-aa-aa-02", isConnected: true),
                PairedDeviceStatus(name: "甲未连", address: "aa-aa-aa-aa-aa-01"),
            ],
            hid: [],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.map(\.name), ["乙已连", "甲未连"])
    }

    func testUnnamedAnchorFallsBackToBatteryName() {
        // 锚无名、电量条目有名:行名取电量侧名(比"未知设备"可读)。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: nil, address: "d4-57-63-5d-bf-6b", vendorID: 1, productID: 2)],
            hid: [HidBatteryEntry(
                batteryPercent: 44,
                productName: "子蒙's Magic Trackpad",
                address: "d4-57-63-5d-bf-6b"
            )],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.first?.name, "子蒙's Magic Trackpad")
    }
}
