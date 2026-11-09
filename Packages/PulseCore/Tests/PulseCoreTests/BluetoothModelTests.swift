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
        // 锚侧两台同名:名字匹配歧义即弃——不给任何一台挂错电量;歧义读数也不
        // 单独成带电量的行(p2-review/02:此前进无锚池带 55% 展示 = 把歧义读数露出去)。
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
        XCTAssertEqual(reading.devices.count, 2, "只剩两条锚行,歧义候选不成独立行")
        XCTAssertTrue(reading.devices.allSatisfy { $0.batteryPercent == nil })
    }

    func testSameNameCandidatesNeverOverrideAnchor() {
        // spec Story 11「歧义即弃」候选侧(p2-review/02):一轮 GATT 里两条同名样本
        // (两副同款耳机都在场)——名在锚侧唯一也不知道哪条是锚的,锚不带电量;
        // 两条读数也不得以带电量的独立行出现。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "AirPods Pro", address: "aa-aa-aa-aa-aa-01")],
            hid: [],
            cache: [],
            gatt: [
                GattBatteryEntry(batteryPercent: 80, name: "AirPods Pro"),
                GattBatteryEntry(batteryPercent: 20, name: "AirPods Pro"),
            ]
        )
        XCTAssertEqual(reading.devices.count, 1, "歧义候选不成独立行")
        XCTAssertNil(reading.devices[0].batteryPercent, "锚电量不被任一同名候选覆盖")
        XCTAssertNil(reading.devices[0].batterySource)
    }

    func testSameSourceAmbiguityDoesNotBlockOtherSourceForSameAnchor() {
        // 歧义按源判:GATT 两条同名弃掉,不连累 HID 经地址唯一挂锚(跨源同名 =
        // 同一设备的多源读数,不算歧义)。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "AirPods Pro", address: "aa-aa-aa-aa-aa-01")],
            hid: [HidBatteryEntry(batteryPercent: 41, productName: "AirPods Pro", address: "aa:aa:aa:aa:aa:01")],
            cache: [],
            gatt: [
                GattBatteryEntry(batteryPercent: 80, name: "AirPods Pro"),
                GattBatteryEntry(batteryPercent: 20, name: "AirPods Pro"),
            ]
        )
        XCTAssertEqual(reading.devices.count, 1)
        XCTAssertEqual(reading.devices[0].batteryPercent, 41)
        XCTAssertEqual(reading.devices[0].batterySource, .hid)
    }

    func testAnchorHitByTwoSameSourceCandidatesDropsBoth() {
        // 同一锚被同源两条候选经不同级命中(一条走地址、一条走唯一名):不再"同级
        // 后到者胜",全部弃挂,也不单独成行。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "妙控键盘", address: "d4-57-63-5d-bf-6b")],
            hid: [
                HidBatteryEntry(batteryPercent: 90, productName: "Keyboard", address: "d4-57-63-5d-bf-6b"),
                HidBatteryEntry(batteryPercent: 15, productName: "妙控键盘"),
            ],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.count, 1)
        XCTAssertNil(reading.devices[0].batteryPercent)
    }

    func testAmbiguousUnanchoredCandidatesProduceNoBatteryRow() {
        // 无锚池同源同名两条不同读数:不知道哪个读数是哪台 → 都不成行。
        let reading = BluetoothMerge.merge(
            paired: [],
            hid: [],
            cache: [],
            gatt: [
                GattBatteryEntry(batteryPercent: 30, name: "路过的耳机"),
                GattBatteryEntry(batteryPercent: 70, name: "路过的耳机"),
            ]
        )
        XCTAssertTrue(reading.devices.isEmpty)
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

    func testSameVendorProductCandidatesNeverOverrideAnchor() {
        // 候选侧 ID 歧义:两条无址、名对不上锚、同厂商/产品 ID 的 HID 条目(两只
        // 同款手柄)→ 锚不带电量,两条读数也不成独立行。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "手柄", address: "b2-2f-35-a4-75-f3", vendorID: 0x1234, productID: 0x5678)],
            hid: [
                HidBatteryEntry(batteryPercent: 66, productName: "GameSir Nova", vendorID: 0x1234, productID: 0x5678),
                HidBatteryEntry(batteryPercent: 33, productName: "GameSir Nova 2", vendorID: 0x1234, productID: 0x5678),
            ],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.count, 1, "歧义候选不成独立行")
        XCTAssertNil(reading.devices[0].batteryPercent, "锚电量不被任一同 ID 候选覆盖")
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

    // MARK: 设备类型(ui-unify 追改 2026-11-09:行首图标的数据底座)

    func testClassOfDeviceDecodesProbedSamples() {
        // 载荷 = 2026-11-09 本机 IOBluetooth 实探原值。
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(0x240404), .audio) // REDMI 头戴耳机
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(0x240418), .audio) // Bose QC35 II
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(0x7A020C), .phone) // 小米平板(自报手机)
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(0x2594), .trackpad) // 妙控板:外设·pointing
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(0x2540), .keyboard) // 外设·键盘位
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(0), .unknown) // BLE 常态
        XCTAssertEqual(BluetoothDeviceKind.fromClassOfDevice(nil), .unknown)
    }

    func testHidUsagesPickByPriorityRegardlessOfOrder() {
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([(page: 1, usage: 6)]), .keyboard)
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([(page: 1, usage: 5)]), .gamepad)
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([(page: 0x0D, usage: 5)]), .trackpad)
        // 组合设备(键盘 + 鼠标两份报告):报告顺序不影响结果。
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([(page: 1, usage: 2), (page: 1, usage: 6)]), .keyboard)
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([(page: 1, usage: 6), (page: 1, usage: 2)]), .keyboard)
        // vendor 页(妙控板实探 0xFF00 报告)不认;空 = 未知。
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([(page: 0xFF00, usage: 18)]), .unknown)
        XCTAssertEqual(BluetoothDeviceKind.fromHidUsages([]), .unknown)
    }

    func testMergeKindPrefersClassOfDeviceThenHidUsage() {
        // 实探形状:妙控板 CoD pointing,HID 报告里却混着 mouse usage → 仍是触控板;
        // Hack59-2(BLE)CoD 0 → 靠 IOHIDDevice usage 6 认出键盘(规整地址匹配,
        // 串形 `D4:57:…` 与锚的 `d4-57-…` 同键)。
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: "妙控板", address: "d4-57-63-5d-bf-6b", classOfDevice: 0x2594),
                PairedDeviceStatus(name: "Hack59-2", address: "ca-d2-10-9d-83-1e", classOfDevice: 0),
                PairedDeviceStatus(name: "手柄", address: "b2-2f-35-a4-75-f3"),
            ],
            hid: [],
            cache: [],
            gatt: [],
            usages: [
                HidUsageEntry(name: "妙控板", address: "D4:57:63:5D:BF:6B", usagePage: 1, usage: 2),
                HidUsageEntry(name: "Hack59-2", address: "ca-d2-10-9d-83-1e", usagePage: 1, usage: 6),
            ]
        )
        let kinds = Dictionary(uniqueKeysWithValues: reading.devices.map { ($0.name, $0.kind) })
        XCTAssertEqual(kinds["妙控板"], .trackpad)
        XCTAssertEqual(kinds["Hack59-2"], .keyboard)
        XCTAssertEqual(kinds["手柄"], .unknown, "无 CoD 也无 usage 的设备不硬猜")
    }

    func testMergeKindNameFallbackRequiresUniqueAnchorName() {
        // usage 条目无地址时退到名字匹配;锚侧同名两台 = 歧义,不给类型(电量级②同口径)。
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: "Keyboard", address: "aa-aa-aa-aa-aa-01"),
                PairedDeviceStatus(name: "Keyboard", address: "aa-aa-aa-aa-aa-02"),
                PairedDeviceStatus(name: "Mouse", address: "aa-aa-aa-aa-aa-03"),
            ],
            hid: [],
            cache: [],
            gatt: [],
            usages: [
                HidUsageEntry(name: "Keyboard", usagePage: 1, usage: 6),
                HidUsageEntry(name: "Mouse", usagePage: 1, usage: 2),
            ]
        )
        XCTAssertTrue(reading.devices.filter { $0.name == "Keyboard" }.allSatisfy { $0.kind == .unknown })
        XCTAssertEqual(reading.devices.first { $0.name == "Mouse" }?.kind, .mouse)
    }

    func testMergeKindAddressMismatchDoesNotFallBackToName() {
        // 地址两侧都有却不等 = 不是同一台(同名不同设备),不退名字匹配。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: "Keyboard", address: "aa-aa-aa-aa-aa-01")],
            hid: [],
            cache: [],
            gatt: [],
            usages: [HidUsageEntry(name: "Keyboard", address: "bb-bb-bb-bb-bb-02", usagePage: 1, usage: 6)]
        )
        XCTAssertEqual(reading.devices.first?.kind, .unknown)
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

    // MARK: 行 id 唯一性(ForEach 撞车收尾去重)

    func testTwoUnnamedAddresslessAnchorsGetDistinctIds() {
        // 2026-10-23 审计低:两条无名无址的已配对锚行都叫"未知设备",id 同源
        // 撞车触发 SwiftUI ForEach 重复 id 告警——收尾去重追加序号消歧,两行
        // 都保留且展示名不变。
        let reading = BluetoothMerge.merge(
            paired: [
                PairedDeviceStatus(name: nil, address: nil),
                PairedDeviceStatus(name: nil, address: nil),
            ],
            hid: [],
            cache: [],
            gatt: []
        )
        XCTAssertEqual(reading.devices.count, 2)
        XCTAssertEqual(Set(reading.devices.map(\.id)).count, 2, "无名无址锚行 id 必须互异")
        XCTAssertTrue(reading.devices.allSatisfy { $0.name == "未知设备" }, "消歧只改 id,展示名不变")
    }

    func testUnnamedAnchorAndBatteryRowNamedUnknownDeviceGetDistinctIds() {
        // 无名锚 + 一条名字恰为"未知设备"的无锚电量行:行名同源、都无地址 →
        // id 撞车同样被收尾消歧(电量读数不丢)。
        let reading = BluetoothMerge.merge(
            paired: [PairedDeviceStatus(name: nil, address: nil)],
            hid: [],
            cache: [],
            gatt: [GattBatteryEntry(batteryPercent: 50, name: "未知设备")]
        )
        XCTAssertEqual(reading.devices.count, 2)
        XCTAssertEqual(Set(reading.devices.map(\.id)).count, 2, "锚行与同名无锚电量行的 id 必须互异")
        XCTAssertTrue(reading.devices.allSatisfy { $0.name == "未知设备" })
        XCTAssertEqual(reading.devices.first { $0.batteryPercent == 50 }?.batterySource, .gatt)
    }
}
