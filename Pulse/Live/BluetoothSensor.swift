import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit
import PulseCore

// MARK: - Live 蓝牙源(p2-sensors/06)

/// Darwin 薄适配器:三源里的两源同步读——① IORegistry
/// `AppleDeviceManagementHIDEventService` 电量外设(妙控板实探:BatteryPercent/
/// DeviceAddress `d4-57-63-5d-bf-6b` 格式/BD_ADDR 六字节)② 蓝牙偏好缓存
/// `/Library/Preferences/com.apple.Bluetooth` 的 DeviceCache(本机 macOS 26 实探
/// 无该键 → 空,macOS 版本差异属正常空态);配对/连接态锚 = IOBluetooth
/// `pairedDevices()`(实探:同设备可重复出现,去重在核心包合并器)。
/// 源③ GATT 按 ON_DEMAND 建连,见 `GattBatteryProbe`(不在本源,不常开)。
struct LiveBluetoothSource: BluetoothSource {
    /// 蓝牙开关态:IOBluetooth 无廉价的同步查询,v1 不设探针——nil = 未知,
    /// 空表交 UI 兜底文案。
    var poweredOn: Bool? {
        nil
    }

    func readPaired() -> [PairedDeviceStatus]? {
        guard let raw = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil // 蓝牙栈不可用
        }
        return raw.map { device in
            PairedDeviceStatus(
                name: device.name,
                address: device.addressString,
                isConnected: device.isConnected(),
                rawRSSI: Int(device.rssi()),
                vendorID: nil, // vendorID/productID 选择子在 Swift 侧不可见(原语返回),级③匹配留给合成载荷单测
                productID: nil
            )
        }
    }

    func readHidBatteries() -> [HidBatteryEntry] {
        var iterator: io_iterator_t = 0
        let matching: CFMutableDictionary = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var entries: [HidBatteryEntry] = []
        var service: io_object_t = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                // BatteryPercent 在场才成条:内建键盘等无电量键的服务不冒充蓝牙外设。
                let percent = (properties["BatteryPercent"] as? NSNumber)?.intValue
            else { continue }
            entries.append(
                HidBatteryEntry(
                    batteryPercent: percent,
                    productName: properties["Product"] as? String,
                    address: Self.hidAddress(properties),
                    vendorID: (properties["VendorID"] as? NSNumber)?.intValue,
                    productID: (properties["ProductID"] as? NSNumber)?.intValue
                )
            )
        }
        return entries
    }

    func readCachedBatteries() -> [CachedBatteryEntry] {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.Bluetooth.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let cache = root["DeviceCache"] as? [String: [String: Any]]
        else { return [] } // 键缺席/读失败 = 空(macOS 26 实探常态),不崩不伪造
        return cache.map { address, entry in
            CachedBatteryEntry(
                batteryPercent: (entry["BatteryPercent"] as? NSNumber)?.intValue ?? 0,
                name: entry["Name"] as? String,
                address: address,
                vendorID: (entry["VendorID"] as? NSNumber)?.intValue,
                productID: (entry["ProductID"] as? NSNumber)?.intValue
            )
        }
        .filter { $0.batteryPercent > 0 } // 0 = 缓存从未见过电量,不是读数
    }

    /// HID 地址回退链:DeviceAddress(串)→ SerialNumber(串)→ BD_ADDR(六字节
    /// 数据,折 `xx-xx-…` 小写串与 DeviceAddress 同形)。三级都缺 = nil(合并器
    /// 走名/ID 匹配)。
    private static func hidAddress(_ properties: [String: Any]) -> String? {
        if let address = properties["DeviceAddress"] as? String, !address.isEmpty {
            return address
        }
        if let serial = properties["SerialNumber"] as? String, !serial.isEmpty {
            return serial
        }
        if let data = properties["BD_ADDR"] as? Data, data.count == 6 {
            return data.map { String(format: "%02x", $0) }.joined(separator: "-")
        }
        return nil
    }
}

// MARK: - GATT 电量探针(源③,按需建连)

/// 有界 GATT 探针:为"缺电量的已配对设备名"扫描 → 名字命中才建连 → 读
/// 0x180F/0x2A19 → 交付后断连(p2-sensors/01 探针⑥实证:设备须在场,连接可
/// 超时——超时/失败安静放弃,下轮 30s 再试)。全部状态锁在自有串行队列
/// (CBCentralManager delegate 队列),deliver 出队即 @Sendable;探针一次起一个,
/// 自然有界:扫描窗 12s、每设备连接 8s,全链最多 ~20s 自动收尾。
final class GattBatteryProbe: NSObject, @unchecked Sendable {
    private static let scanWindow: TimeInterval = 12
    private static let connectTimeout: TimeInterval = 8

    private let queue = DispatchQueue(label: "pulse.gatt-battery-probe")
    private var central: CBCentralManager?
    private var deliver: (@Sendable (GattBatteryEntry) -> Void)?
    private var wantedNames: Set<String> = []
    private var attempted = Set<UUID>()
    private var pendingConnects = Set<UUID>()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var finished = false

    /// 起探针(重复调用安全:已在跑 = no-op)。交付走 deliver,结果由下一轮
    /// provider 快照收账(探针异步完成,不阻塞当轮)。
    func start(wanting names: [String], deliver: @escaping @Sendable (GattBatteryEntry) -> Void) {
        queue.async { [self] in
            guard central == nil, !names.isEmpty else { return }
            wantedNames = Set(names)
            self.deliver = deliver
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        central?.stopScan()
        for peripheral in peripherals.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
        pendingConnects.removeAll()
        central = nil // 释放管理器;下次 start 重建
        deliver = nil
    }
}

extension GattBatteryProbe: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            finish()
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        queue.asyncAfter(deadline: .now() + Self.scanWindow) { [weak self] in
            // 扫描窗到:还在连的让它连完(每设备另有 8s 超时),只是不再发现新目标。
            self?.central?.stopScan()
            if self?.pendingConnects.isEmpty == true {
                self?.finish()
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name, wantedNames.contains(name),
              attempted.insert(peripheral.identifier).inserted
        else { return }
        peripherals[peripheral.identifier] = peripheral
        pendingConnects.insert(peripheral.identifier)
        peripheral.delegate = self
        central.connect(peripheral)
        let id = peripheral.identifier
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, let central = self.central, let target = peripherals[id] else { return }
            if pendingConnects.contains(id) {
                central.cancelPeripheralConnection(target)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // CBUUID 非 Sendable,不设静态常量(Swift 6 全局可变检查),用点内联。
        peripheral.discoverServices([CBUUID(string: "180F")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pendingConnects.remove(peripheral.identifier)
        if pendingConnects.isEmpty, finished == false, central.isScanning == false {
            finish()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        pendingConnects.remove(peripheral.identifier)
        peripherals[peripheral.identifier] = nil
        if pendingConnects.isEmpty, !central.isScanning {
            finish()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        for service in services {
            peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == CBUUID(string: "2A19") {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: "2A19"), error == nil,
              let byte = characteristic.value?.first
        else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        deliver?(GattBatteryEntry(batteryPercent: Int(byte), name: peripheral.name))
        central?.cancelPeripheralConnection(peripheral) // 读完即断,不占设备
    }
}

// MARK: - 蓝牙传感器 provider(p2-sensors/06,ADR-0004)

/// 蓝牙传感器:**可见 30s / 不可见完全停**(spec 节奏矩阵——蓝牙电量是慢变量,
/// 不为常驻成本买单)。可见快照 = 三源合并(锚 IOBluetooth + HID + 缓存 + 上一轮
/// GATT 收账);有缺电量的设备才起 GATT 探针,结果进缓冲供**下一轮**合并
/// (探针异步,不当轮阻塞)。睡眠停扫天然成立(进程随睡眠挂起,30s tick 不跑);
/// 唤醒后下一个可见 tick 自动重启扫描。
final class BluetoothSensorProvider: SensorProvider {
    typealias Reading = BluetoothReading

    let cadence: SensorCadence = .every(seconds: 30)

    private let source: any BluetoothSource
    private let gate = SensorVisibilityGate()
    private let slot = SensorLastGoodBox<BluetoothReading>()
    private let probe = GattBatteryProbe()
    private let gattBuffer = GattBatteryBuffer()

    var lastGood: BluetoothReading? {
        slot.current
    }

    init(source: any BluetoothSource = LiveBluetoothSource()) {
        self.source = source
    }

    /// 可见性切换(弹窗在场 ∨ 主窗口外设页在场,BluetoothFeature 折算下发)。
    func setVisible(_ visible: Bool) {
        _ = gate.setVisible(visible)
    }

    func snapshot() async -> BluetoothReading? {
        // 门控关:一个源都不碰(验收:不可见零扫描)。
        guard gate.isVisible, let paired = source.readPaired() else { return nil }
        let reading = BluetoothMerge.merge(
            paired: paired,
            hid: source.readHidBatteries(),
            cache: source.readCachedBatteries(),
            gatt: drainGattBuffer()
        )
        slot.store(reading)
        // 按需 GATT:还有缺电量的已配对设备 → 起探针(设备在场才可能读到,
        // 不在场超时安静放弃)。中文名设备(平板/键盘广播名)常无 GATT BAS,
        // 探针空转一轮即弃,下轮再试。
        let lacking = reading.devices.filter { $0.batteryPercent == nil }.compactMap(\.name)
        if !lacking.isEmpty {
            probe.start(wanting: lacking) { [weak self] entry in
                self?.appendGatt(entry)
            }
        }
        return reading
    }

    /// GATT 收账入口(探针 deliver 回调;@testable 测试直接投样本钉收账行为)。
    func appendGatt(_ entry: GattBatteryEntry) {
        gattBuffer.append(entry)
    }

    private func drainGattBuffer() -> [GattBatteryEntry] {
        gattBuffer.drain()
    }
}

/// GATT 样本收账盒(SensorLastGoodBox 同款纪律:锁保护微小盒子,协议要求
/// provider 非隔离可 Sendable)。
final class GattBatteryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [GattBatteryEntry] = []

    func append(_ entry: GattBatteryEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    /// 取走制:一次取全并清空(样本只进一轮合并)。
    func drain() -> [GattBatteryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let drained = entries
        entries = []
        return drained
    }
}
