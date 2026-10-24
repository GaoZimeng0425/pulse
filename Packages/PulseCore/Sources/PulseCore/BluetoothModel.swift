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

/// 一轮蓝牙读数:合并后的设备表。蓝牙开关态字段已删(p2-audit/03,2026-10-23
/// 用户拍板 A):查真值需常驻 CoreBluetooth 监听,性价比不足;蓝牙关时
/// readPaired 返 nil 已走"蓝牙不可用或无设备"空态。往后排的点子记在票面。
public struct BluetoothReading: Equatable, Sendable {
    public let devices: [BluetoothDeviceRow]

    public init(devices: [BluetoothDeviceRow]) {
        self.devices = devices
    }
}

// MARK: - 合并器(纯逻辑,单测接缝)

/// 三源合并器:锚 = 已配对设备(按规整地址去重,同址重复行是 IOBluetooth 的
/// 已知行为);电量条目经**三级匹配**挂锚——规整地址 → 唯一名 → 唯一
/// 厂商/产品 ID;任一级锚侧或同源候选侧出现多候选(歧义)即弃,不给错电量,
/// 歧义候选也不单独成行。同一设备多源命中时按 hid > cache > gatt 取(探针实证
/// HID 是内核活值最可信;cache 可能陈旧;gatt 需在场)。挂不上锚、身份明确的
/// 电量条目单独成行(连接态未知)。
public enum BluetoothMerge {
    /// 统一折叠后的电量候选(三源条目去掉来源差异的中间形)。
    private struct Candidate: Equatable, Sendable {
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

        // 同源完全相同的样本 = 同一读数重复上报(如同一设备两次 GATT 交付),先折叠;
        // 余下同源同键的才是真歧义(读数不同,不知道哪条是谁的)。
        let distinct = candidates.reduce(into: [Candidate]()) { kept, candidate in
            if !kept.contains(candidate) {
                kept.append(candidate)
            }
        }
        let resolution = resolve(distinct, anchors: anchors)

        // 锚行:电量挂上即带;RSSI 哨兵(≥0,含 127 与 0)归 nil。
        var rows = order.map { key -> BluetoothDeviceRow in
            let anchor = anchors[key]!
            let battery = resolution.attached[key]
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
        rows += unanchoredRows(resolution.unmatched)

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
        return BluetoothReading(devices: rows)
    }

    /// 一轮匹配结果:锚 key → 挂上的电量;无锚池 = 挂不上锚且身份不歧义的候选。
    /// 歧义候选两边都不进——直接弃(spec Story 11「歧义即弃」)。
    private struct Resolution {
        var attached: [String: Candidate]
        var unmatched: [Candidate]
    }

    private enum Match {
        case anchor(String)
        case unmatched
        case ambiguous
    }

    /// 逐条匹配后收口:同一锚被**同源** ≥2 条候选命中 = 歧义,该源对此锚全部弃挂
    /// (不再"同级后到者胜");跨源同锚是同一设备的多源读数,按 hid > cache > gatt 取。
    private static func resolve(
        _ candidates: [Candidate],
        anchors: [String: PairedDeviceStatus]
    ) -> Resolution {
        var hits: [String: [Candidate]] = [:] // 锚 key → 命中它的候选
        var unmatched: [Candidate] = []
        for candidate in candidates {
            let peers = candidates.filter { $0.source == candidate.source }
            switch matchAnchor(candidate, peers: peers, anchors: anchors) {
            case let .anchor(key): hits[key, default: []].append(candidate)
            case .unmatched: unmatched.append(candidate)
            case .ambiguous: continue
            }
        }
        let attached = hits.compactMapValues { contenders -> Candidate? in
            Dictionary(grouping: contenders, by: \.source).values
                .filter { $0.count == 1 }
                .compactMap(\.first)
                .max { rank($0.source) < rank($1.source) }
        }
        return Resolution(attached: attached, unmatched: unmatched)
    }

    /// 三级匹配,两侧都判唯一:① 规整地址相等 → ② 名字锚侧唯一且同源候选里唯一
    /// → ③ 厂商/产品 ID 同理。某级在锚侧有命中却不唯一(任一侧 ≥2)= 歧义,直接弃,
    /// 不降级试下一级;锚侧零命中才降级。「候选侧」= 同一源的本轮候选(跨源同名是
    /// 同一设备的多源读数,不算歧义)。地址级不判候选侧:地址即身份,同址多读数由
    /// `resolve` 的同锚同源规则弃。
    private static func matchAnchor(
        _ candidate: Candidate,
        peers: [Candidate],
        anchors: [String: PairedDeviceStatus]
    ) -> Match {
        // 级①:地址(normalizedAddress 非 nil 即非空,见 normalizeAddress)。
        if let address = candidate.normalizedAddress {
            let keys = anchors.filter { normalizeAddress($0.value.address ?? "") == address }.map(\.key)
            if !keys.isEmpty {
                return keys.count == 1 ? .anchor(keys[0]) : .ambiguous
            }
        }
        // 级②:名。
        if let name = candidate.name, !name.isEmpty {
            let keys = anchors.filter { $0.value.name == name }.map(\.key)
            if !keys.isEmpty {
                let unique = keys.count == 1 && peers.filter { $0.name == name }.count == 1
                return unique ? .anchor(keys[0]) : .ambiguous
            }
        }
        // 级③:厂商/产品 ID。
        if let vendorID = candidate.vendorID, let productID = candidate.productID {
            let sameIDs: (Int?, Int?) -> Bool = { $0 == vendorID && $1 == productID }
            let keys = anchors.filter { sameIDs($0.value.vendorID, $0.value.productID) }.map(\.key)
            if !keys.isEmpty {
                let unique = keys.count == 1 && peers.filter { sameIDs($0.vendorID, $0.productID) }.count == 1
                return unique ? .anchor(keys[0]) : .ambiguous
            }
        }
        return .unmatched
    }

    /// 无锚池口径:挂不上锚、身份明确的电量条目才单独成行(连接态未知)。池键 =
    /// 规整地址,无址按名;同源同池键 ≥2 条(读数不同)= 不知道哪个读数是哪台 →
    /// 全部弃,**也不以无电量行出现**——无锚行存在的唯一意义是展示电量,去掉电量
    /// 只剩无连接态、无 RSSI 的名字;已配对的设备另有锚行,不缺这一行。跨源同池键
    /// 按候选序(hid > cache > gatt)取首。
    private static func unanchoredRows(_ pool: [Candidate]) -> [BluetoothDeviceRow] {
        let keyed = pool.map { (key: $0.normalizedAddress ?? ($0.name ?? UUID().uuidString), candidate: $0) }
        let sameSourceCounts = Dictionary(
            keyed.map { ("\($0.candidate.source.rawValue)|\($0.key)", 1) },
            uniquingKeysWith: +
        )
        var seen = Set<String>()
        return keyed.compactMap { key, candidate -> BluetoothDeviceRow? in
            guard sameSourceCounts["\(candidate.source.rawValue)|\(key)"] == 1,
                  seen.insert(key).inserted
            else { return nil }
            return BluetoothDeviceRow(
                name: candidate.name ?? "未知设备",
                address: nil,
                normalizedAddress: candidate.normalizedAddress,
                isConnected: false,
                batteryPercent: candidate.percent,
                batterySource: candidate.source,
                rssi: nil
            )
        }
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
    /// 已配对设备锚(IOBluetooth):蓝牙关时返回 nil 交空态,不伪造。
    func readPaired() -> [PairedDeviceStatus]?
    /// 源①:IORegistry HID 电量条目。
    func readHidBatteries() -> [HidBatteryEntry]
    /// 源②:蓝牙偏好缓存电量条目(macOS 26 无 DeviceCache 键 = 空数组)。
    func readCachedBatteries() -> [CachedBatteryEntry]
}
