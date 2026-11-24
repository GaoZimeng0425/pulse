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
                productID: nil,
                classOfDevice: Int(device.classOfDevice)
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

    /// 设备类型回退源(ui-unify 追改 2026-11-09):IOHIDDevice 里蓝牙传输的接口,只读
    /// 注册表属性、不打开设备(打开才需要输入监控权限;读属性与 ioreg 同权)。先单键读
    /// Transport 过滤,只对蓝牙接口取全量属性——本机 HID 接口几十个,蓝牙的只几个。
    /// 实探:BLE 键盘 Hack59-2 = DeviceAddress `ca-d2-…` + usagePage 1 / usage 6;
    /// 妙控板 = SerialNumber `D4:57:…`(地址回退链与电量源同一个 `hidAddress`)。
    func readHidUsages() -> [HidUsageEntry] {
        var iterator: io_iterator_t = 0
        let matching: CFMutableDictionary = IOServiceMatching("IOHIDDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var entries: [HidUsageEntry] = []
        var service: io_object_t = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard
                let transport = IORegistryEntryCreateCFProperty(
                    service, "Transport" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String,
                transport.lowercased().contains("bluetooth")
            else { continue }
            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
                let page = (properties["PrimaryUsagePage"] as? NSNumber)?.intValue,
                let usage = (properties["PrimaryUsage"] as? NSNumber)?.intValue
            else { continue }
            entries.append(
                HidUsageEntry(
                    name: properties["Product"] as? String,
                    address: Self.hidAddress(properties),
                    usagePage: page,
                    usage: usage
                )
            )
        }
        return entries
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
/// 自然有界:扫描窗 12s、每设备连接 8s,全链最多 ~20s 自动收尾;闸关时 provider
/// 调 `cancel()` 提前收尾(p2-review/02)。
final class GattBatteryProbe: NSObject, GattBatteryProbing, @unchecked Sendable {
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
    /// 轮次号:每次 start 自增。扫描窗 / 连接超时定时器捕获起时的轮次,轮次已变
    /// (被 cancel 后又开新轮)即作废——旧轮定时器不得掐断新轮的扫描。
    private var round = 0

    /// 起探针(重复调用安全:已在跑 = no-op)。交付走 deliver,结果由下一轮
    /// provider 快照收账(探针异步完成,不阻塞当轮)。
    func start(wanting names: [String], deliver: @escaping @Sendable (GattBatteryEntry) -> Void) {
        queue.async { [self] in
            guard !names.isEmpty, central == nil else { return }
            // 上一轮已自然收尾(finish 置 central=nil):重置一次性状态再开新轮
            // ——2026-10-23 审计①:此前漏重置,第二轮 attempted 全拦 + finished
            // 拦死 finish,新 central 永不停扫也永不释放(电台常开泄漏)。
            finished = false
            round &+= 1
            attempted = []
            wantedNames = Set(names)
            self.deliver = deliver
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    /// 闸关取消(p2-review/02;BluetoothFeature 关开关 / 不可见 / 授权失效都折到
    /// provider.setVisible(false) 再到这里):在探针自有队列上走同一条收尾路径——
    /// 停扫、取消在连外设、释放 central。之后的 delegate 回调因 central 已释放 /
    /// 身份不符而作废。
    func cancel() {
        queue.async { [self] in
            guard central != nil else { return } // 没在跑:no-op
            finish()
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
        // 已被 cancel / 收尾的旧 central 迟到的状态回调:不是本轮的,不起扫。
        guard central === self.central else { return }
        guard central.state == .poweredOn else {
            finish()
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let startedRound = round
        queue.asyncAfter(deadline: .now() + Self.scanWindow) { [weak self] in
            // 扫描窗到:还在连的让它连完(每设备另有 8s 超时),只是不再发现新目标。
            guard let self, round == startedRound else { return }
            self.central?.stopScan()
            if pendingConnects.isEmpty {
                finish()
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
        let startedRound = round
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, round == startedRound,
                  let central = self.central, let target = peripherals[id] else { return }
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

// MARK: - 蓝牙授权 Live 实现(授权态与协议在 PulseCore 的 BluetoothAccess)

/// Live 实现:静默读走 `CBCentralManager.authorization` 类属性(NemoNotch 实证:
/// 不初始化协调器、不弹);显式请求靠建一个 `CBCentralManager`——首次建即弹系统
/// 权限框,答复落地走 delegate 的状态更新。同时只挂一个请求器,连点不叠加。
/// `@unchecked Sendable` 前提:唯一可变状态 `pending` 由 `lock` 串行化。
final class LiveBluetoothAccessControl: BluetoothAccessControl, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: BluetoothAccessRequester?

    func authorization() -> BluetoothAuthorization {
        switch CBCentralManager.authorization {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .allowedAlways: .allowed
        @unknown default: .notDetermined
        }
    }

    func requestAccess(_ completion: @escaping @Sendable () -> Void) {
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return
        }
        let requester = BluetoothAccessRequester { [weak self] in
            self?.clearPending()
            completion()
        }
        pending = requester
        lock.unlock()
        // 锁外启动:协调器的 delegate 回调若与锁段重入会死锁。
        requester.start()
    }

    private func clearPending() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
    }
}

/// 一次性请求器:持有协调器直到首个状态更新(= 用户已答复 / 栈状态已知),随即
/// 释放协调器——不留常驻扫描对象。`@unchecked Sendable` 前提:状态只在主队列
/// (CBCentralManager queue nil = 主队列)上读写。
private final class BluetoothAccessRequester: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var central: CBCentralManager?
    private var completion: (@Sendable () -> Void)?

    init(completion: @escaping @Sendable () -> Void) {
        self.completion = completion
        super.init()
    }

    /// 这一行就是系统弹窗出现的那一刻(未决时);已授权 / 已拒则只收到状态更新。
    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let completion else { return }
        self.completion = nil
        self.central = nil
        completion()
    }
}
