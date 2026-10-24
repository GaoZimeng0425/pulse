import Darwin
import Foundation
import PulseCore

// MARK: - 惰性源(预览与单测共用)

//
// 每条 OS 接缝的「什么都不做」实现:读数恒缺(nil / 空)、不起子进程、不发信号、
// 不请求通知授权、不碰用户偏好与生产历史库。SystemMonitor 不再带 Live 默认参数
// (默认 `HistoryEngine.openDefault()` 曾让测试 / 预览误连生产库,见 0c892c1),
// 预览与单测经这里显式装配;真实装配只在 `SystemMonitor.live(projectRoots:)`。

/// 出生扫描:没有 pid,也就没有出生(登记只来自采样轮兜底)。
struct InertBirthScanSource: BirthScanSource {
    func pids() -> [pid_t] {
        []
    }

    func birthInfo(for pid: pid_t) -> LineageRegistry.Entry? {
        nil
    }
}

/// 结束进程:绝不发信号;如实回报「进程已退出」(合成进程本就不存在)。
struct InertKillService: KillService {
    func send(signal: Int32, to pid: pid_t) -> KillSignalResult {
        .failed(.noSuchProcess)
    }
}

/// 电池:无内建电池(电池页整页隐藏,与台式机同口径)。
struct InertBatterySource: BatterySource {
    func read() -> BatteryRawReading? {
        nil
    }
}

/// GPU:预览合成读数(固定 42% 利用率 + M4 静态信息,卡面有数好看);
/// 与电池/磁盘的"恒 nil 占位"不同——GPU 卡是常驻轴,预览有真形状更可验。
/// SMC:预览合成读数(派生值/风扇/两条明细,卡面有形状可验;表外键
/// 也带一条,未知组折叠形态可验)。
struct InertSmcSource: SmcSource {
    func read() -> SmcSnapshot? {
        func sp78(_ value: Double) -> [UInt8] {
            let scaled = Int(value * 256)
            return [UInt8((scaled >> 8) & 0xFF), UInt8(scaled & 0xFF)]
        }
        return SmcSnapshot(
            keys: [
                SmcRawKey(key: "Tp01", dataType: "sp78", bytes: sp78(48)),
                SmcRawKey(key: "Tp05", dataType: "sp78", bytes: sp78(52)),
                SmcRawKey(key: "Tg05", dataType: "sp78", bytes: sp78(46)),
                SmcRawKey(key: "Ts0S", dataType: "sp78", bytes: sp78(41)),
                SmcRawKey(key: "TZ99", dataType: "sp78", bytes: sp78(43)),
                SmcRawKey(key: "FNum", dataType: "ui8 ", bytes: [1]),
                SmcRawKey(key: "F0Ac", dataType: "fpe2", bytes: [0x9C, 0x40]),
                SmcRawKey(key: "F0Mn", dataType: "fpe2", bytes: [0x24, 0x40]),
                SmcRawKey(key: "F0Mx", dataType: "fpe2", bytes: [0x66, 0x00]),
            ],
            takenAt: Date()
        )
    }
}

/// 容器:预览合成读数(两台运行 + 一台退出,状态点/CPU/内存列都有形状可验)。
struct InertContainerSource: ContainerSource {
    func read() async -> ContainersReading? {
        ContainersReading(engineReachable: true, containers: [
            ContainerRow(
                id: "a1",
                name: "postgres",
                state: "running",
                image: "postgres:16",
                cpuPercent: 1.8,
                memoryBytes: 312 * 1024 * 1024
            ),
            ContainerRow(
                id: "b2",
                name: "redis",
                state: "running",
                image: "redis:7",
                cpuPercent: 0.4,
                memoryBytes: 28 * 1024 * 1024
            ),
            ContainerRow(id: "c3", name: "old-api", state: "exited", image: "api:0.9"),
        ])
    }
}

/// 蓝牙:预览合成载荷(两台带电量 + 一台未知,三级匹配/去重/排序都有形状可验)。
struct InertBluetoothSource: BluetoothSource {
    func readPaired() -> [PairedDeviceStatus]? {
        [
            PairedDeviceStatus(
                name: "子蒙's Magic Trackpad",
                address: "d4-57-63-5d-bf-6b",
                isConnected: true,
                rawRSSI: -58
            ),
            PairedDeviceStatus(name: "Bose QC35 II", address: "2c-41-a1-c8-c5-01", isConnected: false, rawRSSI: 0),
            PairedDeviceStatus(name: "Hack59-2", address: "ca-d2-10-9d-83-1e", isConnected: true, rawRSSI: 127),
        ]
    }

    func readHidBatteries() -> [HidBatteryEntry] {
        [HidBatteryEntry(batteryPercent: 41, productName: "子蒙's Magic Trackpad", address: "d4-57-63-5d-bf-6b")]
    }

    func readCachedBatteries() -> [CachedBatteryEntry] {
        [CachedBatteryEntry(batteryPercent: 80, name: "Bose QC35 II", address: "2c:41:a1:c8:c5:01")]
    }
}

/// 蓝牙授权:预览 / 测试宿主固定态(默认「已授权」),显式请求即刻回调——
/// 不碰蓝牙栈,单测不受本机 TCC 状态影响(CODING_STANDARDS 测试纪律)。
struct InertBluetoothAccessControl: BluetoothAccessControl {
    var state: BluetoothAuthorization = .allowed

    func authorization() -> BluetoothAuthorization {
        state
    }

    func requestAccess(_ completion: @escaping @Sendable () -> Void) {
        completion()
    }
}

/// 声音:预览合成读数(默认设备 + 42% 音量 + 未静音,卡面有形状可验)。
struct InertSoundSource: SoundSource {
    func read() -> SoundRawReading? {
        SoundRawReading(
            deviceName: "MacBook Pro Speakers",
            volumeScalar: 0.42,
            isMuted: false
        )
    }
}

/// 五路功率:预览合成读数(CPU/GPU/ANE/RAM/SoC 各一瓦数,卡面有形状可验)。
struct InertPowerSource: PowerSource {
    func read() -> PowerRawReading? {
        PowerRawReading(
            channels: [
                PowerChannelSample(name: "CPU Energy", unitLabel: "mJ", rawValue: 1000),
                PowerChannelSample(name: "GPU", unitLabel: "mJ", rawValue: 400),
                PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 60),
                PowerChannelSample(name: "DRAM", unitLabel: "mJ", rawValue: 200),
                PowerChannelSample(name: "SOC_REST", unitLabel: "mJ", rawValue: 90),
            ],
            takenAt: Date()
        )
    }
}

struct InertGpuSource: GpuSource {
    func read() -> GpuRawReading? {
        GpuRawReading(
            deviceUtilizationPercent: 42,
            rendererUtilizationPercent: 38,
            tilerUtilizationPercent: 11,
            allocatedBytes: 2_233_000_000,
            inUseBytes: 1_180_000_000,
            modelName: "Apple M4",
            coreCount: 10
        )
    }
}

/// 磁盘容量:读不到(容量卡整卡占位)。
struct InertDiskCapacitySource: DiskCapacitySource {
    func read() -> DiskCapacityRawReading? {
        nil
    }
}

/// 磁盘吞吐:读不到(速率列占位);节奏取低频档,调度器空转成本最低。
struct InertDiskThroughputSource: DiskThroughputSource {
    func readCounters() -> DiskIOCounters? {
        nil
    }

    var cadenceSeconds: TimeInterval {
        30
    }
}

/// nettop:不起子进程,读数恒缺(网络每进程排行占位)。
struct InertNettopCSVSource: NettopCSVSource {
    func read() async -> String? {
        nil
    }
}

/// launchd plist 目录:一律缺席(不碰磁盘;清单恒为空集,后台服务只剩静态域)。
struct InertLaunchdPlistSource: LaunchdPlistSource {
    func read(directory: String) -> LaunchdPlistDirectoryRead {
        .absent
    }
}

/// dev server 端口扫描:不扫,无监听端口。
struct InertDevServerPortScanner: DevServerPortScanning {
    func listeningPorts(pid: pid_t) -> [UInt16] {
        []
    }
}

/// 每核 tick:空样本(系统负载按 0 计,CoreTickDiffer 的退化口径)。
struct InertCoreTickSource: CoreTickSource {
    func sample() -> CoreTickSample {
        CoreTickSample(busyTicks: [], totalTicks: [], takenAt: Date())
    }
}

/// 内存构成:读不到(内存卡占位)。
struct InertMemoryStatsSource: MemoryStatsSource {
    func sample() -> MemoryBreakdown? {
        nil
    }
}

/// 网络计数:读缺失(网络页占位,历史增量 0)。
struct InertNetworkCountersSource: NetworkCountersSource {
    func sample() -> NetworkCounters? {
        nil
    }
}

/// 通知发送:系统「还没问过」、从不请求、从不投递。
struct InertAlertNotificationSender: AlertNotificationSending {
    func requestAuthorization() async -> Bool {
        false
    }

    func authorizationStatus() async -> NotificationAuthorization {
        .notDetermined
    }

    func authorizationDiagnostics() async -> String {
        "inert"
    }

    func send(_ payload: AlertNotificationPayload) async {}
}

extension AlertCenter {
    /// 惰性告警编排:规则全关(预设阈值)、配置不落盘、不碰 UserDefaults、不请求授权。
    static func inert() -> AlertCenter {
        AlertCenter(
            store: AlertSettingsStore(load: { [:] }, persist: { _ in }),
            sender: InertAlertNotificationSender()
        )
    }
}

// MARK: - 预览装配

extension SystemMonitor {
    /// SwiftUI 预览装配:进程来自调用方的合成源;每核 tick / 内存 / 网络计数取
    /// 只读 Live 源(不写任何东西,总览卡与改造前一样有真读数);其余 OS 接缝全
    /// 惰性(不起 nettop、不扫端口、不发信号、不请求通知授权、不碰用户偏好);
    /// 历史默认内存库(零磁盘副作用,落库与累计读回照常走一遍),绝不开生产库。
    static func preview(
        source: any ProcessSource = SyntheticProcessSource(processes: []),
        projectRoots: [String] = [],
        historyEngine: HistoryEngine? = HistoryEngine(database: try? HistoryDatabase.openInMemory())
    ) -> SystemMonitor {
        SystemMonitor(
            sources: MonitorSources(
                process: source,
                coreTicks: LiveCoreTickSource(),
                memoryStats: LiveMemoryStatsSource(),
                networkCounters: LiveNetworkCountersSource(),
                heartbeatRelay: HeartbeatRusageRelay(),
                birthScan: InertBirthScanSource(),
                killService: InertKillService()
            ),
            projectRoots: projectRoots,
            features: MonitorFeatures(
                network: NetworkFeature(),
                alerts: .inert(),
                devServers: DevServerFeature(portScanner: InertDevServerPortScanner()),
                rankings: RankingsFeature(nettopSource: InertNettopCSVSource()),
                history: HistoryFeature(engine: historyEngine),
                disk: DiskFeature(
                    capacitySource: InertDiskCapacitySource(),
                    throughputSource: InertDiskThroughputSource()
                ),
                battery: BatteryFeature(source: InertBatterySource()),
                gpu: GpuFeature(source: InertGpuSource()),
                power: PowerFeature(source: InertPowerSource(), chipName: HostInfo.current.chipName ?? ""),
                smc: SmcFeature(source: InertSmcSource()),
                sound: SoundFeature(source: InertSoundSource()),
                // 预览 / 测试宿主:开关固定开 + 固定已授权,卡面直接呈现设备行;
                // 不读不写用户 UserDefaults(TestHostIsolation)。
                bluetooth: BluetoothFeature(
                    source: InertBluetoothSource(),
                    access: InertBluetoothAccessControl(),
                    loadEnabled: { true },
                    persistEnabled: { _ in }
                ),
                containers: ContainerFeature(source: InertContainerSource()),
                launchdManifest: LaunchdManifestFeature(
                    provider: LaunchdManifestProvider(source: InertLaunchdPlistSource())
                )
            )
        )
    }
}
