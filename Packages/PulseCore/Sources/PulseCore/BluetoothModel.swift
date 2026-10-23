import Foundation

// MARK: - 蓝牙三源电量合并(p2-sensors/06,ADR-0004 SensorProvider 接缝)

// 合并规则与研究出处:docs/research/sensor-impl-comparison.md §2.8(stats MIT
// Modules/Bluetooth/readers.swift:256-284 的三级匹配,只取规则不搬代码);
// 源②"缓存电量 1 当 100 解"的坑 = readers.swift:339-341 同款。
// 三源 = ① IORegistry Apple HID 事件服务(Apple 外设)② 蓝牙偏好缓存
// (DeviceCache;免权限)③ CoreBluetooth GATT 电池服务(按需建连);
// 已配对/连接态与 RSSI 锚自 IOBluetooth 设备列表(RSSI ≥0 = 无读数,
// 127 哨兵与 0 空值同归未知)。

/// 源①原始条目:IORegistry `AppleDeviceManagementHIDEventService` 的电量外设
/// (妙控板/妙控键盘/Beats 等);BatteryPercent 在场才成条(内建键盘无此键,
/// 不冒充蓝牙外设)。地址回退链 DeviceAddress → SerialNumber → BD_ADDR 由
/// Live 折成展示串后交回。
public struct HidBatteryEntry: Equatable, Sendable {
    public var batteryPercent: Int
    public var productName: String?
    public var address: String?
    public var vendorID: Int?
    public var productID: Int?

    public init(
        batteryPercent: Int,
        productName: String? = nil,
        address: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil
    ) {
        self.batteryPercent = batteryPercent
        self.productName = productName
        self.address = address
        self.vendorID = vendorID
        self.productID = productID
    }
}

/// 源②原始条目:蓝牙偏好缓存 `/Library/Preferences/com.apple.Bluetooth` 的
/// DeviceCache 子项。**电量按原样交回**——"缓存值 1 实为 100"的解释在合并器
/// (本文件),不在 Live(测试缝纪律:解释属核心包纯逻辑)。
public struct CachedBatteryEntry: Equatable, Sendable {
    public var batteryPercent: Int
    public var name: String?
    public var address: String?
    public var vendorID: Int?
    public var productID: Int?

    public init(
        batteryPercent: Int,
        name: String? = nil,
        address: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil
    ) {
        self.batteryPercent = batteryPercent
        self.name = name
        self.address = address
        self.vendorID = vendorID
        self.productID = productID
    }
}

/// 源③原始样本:GATT 电池服务(0x180F/0x2A19)按需建连读到的一次电量。
/// CoreBluetooth 的 identifier 是 UUID 不是蓝牙地址,样本只带名字。
public struct GattBatteryEntry: Equatable, Sendable {
    public var batteryPercent: Int
    public var name: String?

    public init(batteryPercent: Int, name: String? = nil) {
        self.batteryPercent = batteryPercent
        self.name = name
    }
}

/// 已配对设备锚(IOBluetooth 设备列表):合并的行骨架——连接态与 RSSI 只在
/// 这里有;三条电量源经三级匹配挂到锚上。
public struct PairedDeviceStatus: Equatable, Sendable {
    public var name: String?
    /// 展示格式地址(如 `d4-57-63-5d-bf-6b`);nil = 拿不到。
    public var address: String?
    public var isConnected: Bool
    /// 最近 RSSI(dBm,负值有效;0/127 等哨兵交合并器归未知)。
    public var rawRSSI: Int
    public var vendorID: Int?
    public var productID: Int?

    public init(
        name: String? = nil,
        address: String? = nil,
        isConnected: Bool = false,
        rawRSSI: Int = 0,
        vendorID: Int? = nil,
        productID: Int? = nil
    ) {
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.rawRSSI = rawRSSI
        self.vendorID = vendorID
        self.productID = productID
    }
}

/// 电量出处(合并后的行携带,供 UI 与日志解释数值来源)。
public enum BluetoothBatterySource: String, Equatable, Sendable {
    case hid
    case cache
    case gatt
}

/// 合并后的设备行:锚(已配对设备)+ 挂上的电量;或无锚的纯电量条目
/// (GATT 扫到但不在配对表,如新设备)。
public struct BluetoothDeviceRow: Equatable, Identifiable, Sendable {
    /// 行身份:规整地址优先,无地址按名字(构造时定值)。无名无址的行全落
    /// "未知设备"会同源撞 id,由 merge 收尾对撞车行追加序号消歧(见 merge
    /// 末尾;2026-10-23 审计低,SwiftUI ForEach 要求 id 唯一)。
    public var id: String

    public let name: String
    public let address: String?
    public let normalizedAddress: String?
    public let isConnected: Bool
    public let batteryPercent: Int?
    public let batterySource: BluetoothBatterySource?
    /// 有效 RSSI(dBm,负值);0/127 哨兵归 nil(UI 显示 —)。
    public let rssi: Int?

    public init(
        name: String,
        address: String? = nil,
        normalizedAddress: String? = nil,
        isConnected: Bool = false,
        batteryPercent: Int? = nil,
        batterySource: BluetoothBatterySource? = nil,
        rssi: Int? = nil
    ) {
        // id 初值沿旧计算口径:规整地址优先,无地址按名字;撞车消歧在 merge 收尾。
        id = normalizedAddress ?? name
        self.name = name
        self.address = address
        self.normalizedAddress = normalizedAddress
        self.isConnected = isConnected
        self.batteryPercent = batteryPercent
        self.batterySource = batterySource
        self.rssi = rssi
    }
}

/// 一轮蓝牙读数:合并后的设备表 + 蓝牙开关态。
public struct BluetoothReading: Equatable, Sendable {
    public let poweredOn: Bool?
    public let devices: [BluetoothDeviceRow]

    public init(poweredOn: Bool?, devices: [BluetoothDeviceRow]) {
        self.poweredOn = poweredOn
        self.devices = devices
    }
}

// MARK: - 合并器(纯逻辑,单测接缝)

/// 三源合并器:锚 = 已配对设备(按规整地址去重,同址重复行是 IOBluetooth 的
/// 已知行为);电量条目经**三级匹配**挂锚——规整地址 → 唯一名 → 唯一
/// 厂商/产品 ID;任一级出现多候选(歧义)即弃,不给错电量。同一设备多源
/// 命中时按 hid > cache > gatt 取(探针实证 HID 是内核活值最可信;cache 可能
/// 陈旧;gatt 需在场)。挂不上锚的电量条目单独成行(连接态未知)。
public enum BluetoothMerge {
    /// 统一折叠后的电量候选(三源条目去掉来源差异的中间形)。
    private struct Candidate: Sendable {
        var percent: Int
        var source: BluetoothBatterySource
        var name: String?
        var normalizedAddress: String?
        var vendorID: Int?
        var productID: Int?
    }

    /// 地址规整:去 `:`/`-` 分隔、小写——`d4-57-63-5d-bf-6b`、`D4:57:…` 与
    /// `d457635dbf6b` 全等(三级匹配第一级的键)。
    public static func normalizeAddress(_ raw: String) -> String? {
        let normalized = raw.lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? nil : normalized
    }

    /// 合并一轮:paired 为空(蓝牙关/无配对)→ 只剩无锚电量行(通常也空)。
    public static func merge(
        paired: [PairedDeviceStatus],
        hid: [HidBatteryEntry],
        cache: [CachedBatteryEntry],
        gatt: [GattBatteryEntry]
    ) -> BluetoothReading {
        // 锚去重:同规整地址取首行,连接态 OR(IOBluetooth 同设备可能回报多次)。
        var anchors: [String: PairedDeviceStatus] = [:]
        var order: [String] = []
        for device in paired {
            let key = normalizeAddress(device.address ?? "") ?? (device.name ?? UUID().uuidString)
            if var existing = anchors[key] {
                existing.isConnected = existing.isConnected || device.isConnected
                anchors[key] = existing
            } else {
                anchors[key] = device
                order.append(key)
            }
        }

        // 电量条目统一折叠成中间形再挂锚。
        let candidates: [Candidate] =
            hid.map {
                Candidate(
                    percent: $0.batteryPercent,
                    source: .hid,
                    name: $0.productName,
                    normalizedAddress: normalizeAddress($0.address ?? ""),
                    vendorID: $0.vendorID,
                    productID: $0.productID
                )
            }
            + cache.map {
                Candidate(
                    // 坑口径:缓存值 1 实为 100(stats readers.swift:339-341 同款)。
                    percent: $0.batteryPercent == 1 ? 100 : $0.batteryPercent,
                    source: .cache,
                    name: $0.name,
                    normalizedAddress: normalizeAddress($0.address ?? ""),
                    vendorID: $0.vendorID,
                    productID: $0.productID
                )
            }
            + gatt.map {
                Candidate(
                    percent: $0.batteryPercent,
                    source: .gatt,
                    name: $0.name,
                    normalizedAddress: nil,
                    vendorID: nil,
                    productID: nil
                )
            }

        // 三级匹配:每条电量候选找至多一个锚;歧义即弃(该锚本轮不带此源的电量)。
        var attached: [String: Candidate] = [:] // 键 = 锚 key
        var unmatched: [Candidate] = []
        for candidate in candidates {
            if let key = matchAnchor(candidate, anchors: anchors) {
                // 同锚多源:hid > cache > gatt(来源序即优先级)。
                if let existing = attached[key] {
                    let newcomerWins = rank(candidate.source) > rank(existing.source)
                        // 同级再比新鲜度:后到的同级样本(如新读的 gatt)覆盖旧的。
                        || rank(candidate.source) == rank(existing.source)
                    if newcomerWins {
                        attached[key] = candidate
                    }
                } else {
                    attached[key] = candidate
                }
            } else {
                unmatched.append(candidate)
            }
        }

        // 锚行:电量挂上即带;RSSI 哨兵(≥0,含 127 与 0)归 nil。
        var rows = order.map { key -> BluetoothDeviceRow in
            let anchor = anchors[key]!
            let battery = attached[key]
            return BluetoothDeviceRow(
                name: anchor.name ?? battery?.name ?? "未知设备",
                address: anchor.address,
                normalizedAddress: normalizeAddress(anchor.address ?? ""),
                isConnected: anchor.isConnected,
                batteryPercent: battery?.percent,
                batterySource: battery?.source,
                rssi: anchor.rawRSSI < 0 ? anchor.rawRSSI : nil
            )
        }

        // 无锚电量行:按规整地址/名字自去重后追加(连接态未知)。
        var seenUnmatched = Set<String>()
        for candidate in unmatched {
            let key = candidate.normalizedAddress ?? (candidate.name ?? UUID().uuidString)
            guard seenUnmatched.insert(key).inserted else { continue }
            rows.append(
                BluetoothDeviceRow(
                    name: candidate.name ?? "未知设备",
                    address: nil,
                    normalizedAddress: candidate.normalizedAddress,
                    isConnected: false,
                    batteryPercent: candidate.percent,
                    batterySource: candidate.source,
                    rssi: nil
                )
            )
        }

        // 行序:已连接置顶,其余按名稳定排。
        rows.sort { lhs, rhs in
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected
            }
            return lhs.name < rhs.name
        }

        // 收尾去重:SwiftUI ForEach 要求 id 唯一;无名无址行撞 id 时追加
        // "#2"/"#3" 序号消歧,只改 id 不改展示名(两行仍都显示"未知设备")。
        var idOccurrences: [String: Int] = [:]
        for index in rows.indices {
            let base = rows[index].id
            let nth = idOccurrences[base, default: 0] + 1
            idOccurrences[base] = nth
            if nth > 1 {
                rows[index].id = "\(base)#\(nth)"
            }
        }
        return BluetoothReading(poweredOn: nil, devices: rows)
    }

    /// 三级匹配:① 规整地址相等 → ② 名字两侧均唯一且相等 → ③ 厂商/产品 ID
    /// 两侧均唯一且相等;任何一级多候选 = 歧义即弃(返回 nil,条目走无锚池)。
    private static func matchAnchor(
        _ candidate: Candidate,
        anchors: [String: PairedDeviceStatus]
    ) -> String? {
        // 级①:地址。
        if let address = candidate.normalizedAddress, !address.isEmpty {
            let hits = anchors.filter { normalizeAddress($0.value.address ?? "") == address }
            if hits.count == 1 {
                return hits.first?.key
            }
            if hits.count > 1 {
                return nil
            } // 歧义即弃
        }
        // 级②:名(两侧各自唯一)。
        if let name = candidate.name, !name.isEmpty {
            let anchorNames = anchors.values.compactMap(\.name)
            let nameUniqueOnAnchorSide = anchorNames.filter { $0 == name }.count == 1
            if nameUniqueOnAnchorSide {
                return anchors.first { $0.value.name == name }?.key
            }
        }
        // 级③:厂商/产品 ID(候选侧与锚侧都唯一)。
        if let vendorID = candidate.vendorID, let productID = candidate.productID {
            let hits = anchors.filter { $0.value.vendorID == vendorID && $0.value.productID == productID }
            if hits.count == 1 {
                return hits.first?.key
            }
        }
        return nil
    }

    /// 来源优先级:hid(内核活值)> cache(免权限快照)> gatt(需在场建连)。
    private static func rank(_ source: BluetoothBatterySource) -> Int {
        switch source {
        case .hid: 3
        case .cache: 2
        case .gatt: 1
        }
    }
}

// MARK: - 蓝牙源协议(编译期测试接缝,ADR-0003 澄清条款同款)

/// 蓝牙源(ADR-0004 接缝):产品运行期唯一真实现 = app 的 Live 适配器
/// (IOBluetooth/IORegistry/plist 读取 + CoreBluetooth 按需建连),测试注入
/// 假源;缝上全部纯逻辑(本文件的合并器)。
public protocol BluetoothSource: Sendable {
    /// 已配对设备锚(IOBluetooth;poweredOn 时为空数组,蓝牙关 = nil?)——
    /// 蓝牙关时返回 nil 交空态,不伪造。
    func readPaired() -> [PairedDeviceStatus]?
    /// 源①:IORegistry HID 电量条目。
    func readHidBatteries() -> [HidBatteryEntry]
    /// 源②:蓝牙偏好缓存电量条目(macOS 26 无 DeviceCache 键 = 空数组)。
    func readCachedBatteries() -> [CachedBatteryEntry]
    /// 蓝牙开关态(CoreBluetooth 状态;nil = 未知)。
    var poweredOn: Bool? { get }
}
