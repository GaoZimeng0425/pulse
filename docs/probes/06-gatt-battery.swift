// 探针⑥(2026-10-22,p2-sensors/01):CoreBluetooth GATT 电池服务真读数——蓝牙三源
// 之③的验证(研究档案 §2.8 源⑤)。目标:扫到 BLE 外设 → 连接 → 发现 0x180F
// 电池服务 → 读 0x2A19 电量特征;验证连接时长与权限面(应免弹窗)。
// Apple 外设(妙控板等)电量通常走 IORegistry HID 路不走 GATT BAS,故本探针
// 的预期对象是第三方 BLE 设备(耳机/手柄)。20s 扫不到/连不上 = 如实落档的
// 有效结论(说明 GATT 路需要设备在场且可连接,产品侧按需建连的设计不变)。
// 编译运行:swiftc -O 06-gatt-battery.swift -o /tmp/p6 && /tmp/p6

import CoreBluetooth
import Foundation

let batteryService = CBUUID(string: "180F")
let batteryLevel = CBUUID(string: "2A19")

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let central: CBCentralManager
    var tried = Set<UUID>()
    var connected = false
    var connectStart = Date()
    var timer: Timer?

    override init() {
        central = CBCentralManager()
        super.init()
        central.delegate = self
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("蓝牙状态: \(c.state == .poweredOn ? "poweredOn" : String(describing: c.state.rawValue))")
        guard c.state == .poweredOn else {
            print("结论:蓝牙未开或不可用 —— GATT 路不可测,如实落档")
            exit(0)
        }
        // 不按广播过滤:很多 BLE 外设不在广播里带 0x180F,扫到有名设备就连上发现
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("开始扫描(20s)…")
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in
            print("结论:20s 内无可连接的带电量的 BLE 外设(或均未在广播)—— GATT 路需设备在场,产品侧按需建连设计成立")
            exit(0)
        }
        RunLoop.main.add(timer!, forMode: .default)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name, !name.isEmpty, tried.insert(peripheral.identifier).inserted else { return }
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        print("发现: \(name)  RSSI=\(RSSI)  广播服务=\(advServices)")
        guard !connected else { return }
        connected = true
        central.stopScan()
        print("连接 → \(name)(计时开始)…")
        connectStart = Date()
        peripheral.delegate = self
        central.connect(peripheral)
        // 连接超时兜底:12s 连不上换下一个
        Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
            print("结论:连接超时(设备不可达)—— 如实落档")
            exit(0)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print(String(format: "已连接(%.1fs),发现服务…", -connectStart.timeIntervalSinceNow))
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("结论:连接失败 \(error?.localizedDescription ?? "?") —— 如实落档")
        exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            print("结论:无电池服务(0x180F 不在该设备)—— 该设备电量不走 GATT BAS")
            exit(0)
        }
        for s in services {
            print("服务: \(s.uuid.uuidString)")
            peripheral.discoverCharacteristics([batteryLevel], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first else { return }
        peripheral.readValue(for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevel else { return }
        if let data = characteristic.value, let byte = data.first {
            print("✅ 结论:GATT 电池读数成功 —— \(peripheral.name ?? "?") 电量 = \(byte)%(\(data.count) 字节)")
            print("   权限面:全程无系统弹窗(免 TCC)")
        } else {
            print("结论:读到特征但值为空 \(error?.localizedDescription ?? "")")
        }
        central.cancelPeripheralConnection(peripheral)
        exit(0)
    }
}

let probe = Probe()
RunLoop.main.run()
