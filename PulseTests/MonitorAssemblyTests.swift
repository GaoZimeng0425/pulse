@testable import Pulse
@testable import PulseCore
import XCTest

/// MonitorFeatures registry 防漂移(2026-10-23 审计低):具名字段(视图直读)与
/// registry 数组(onRound / start / 可见性 / 传感器登记的唯一派发通道)是双份
/// 手工维护,编译期无防护——加字段漏登记 = 该模块静默失联,所有派发都不达。
/// 本测试用 Mirror 钉住两份清单一致,漂移即红。构造全用 Inert 假源
/// (写法对照 InertSources 的 `SystemMonitor.preview`;HistoryFeature 引擎
/// 缺席即降级,chipName 传空串)。
@MainActor
final class MonitorAssemblyTests: XCTestCase {
    /// 全 Inert 装配的 MonitorFeatures(不起子进程、不碰偏好与生产库)。
    private func makeFeatures() -> MonitorFeatures {
        MonitorFeatures(
            network: NetworkFeature(),
            alerts: .inert(),
            devServers: DevServerFeature(portScanner: InertDevServerPortScanner()),
            rankings: RankingsFeature(nettopSource: InertNettopCSVSource()),
            history: HistoryFeature(engine: nil),
            disk: DiskFeature(
                capacitySource: InertDiskCapacitySource(),
                throughputSource: InertDiskThroughputSource()
            ),
            battery: BatteryFeature(source: InertBatterySource()),
            gpu: GpuFeature(source: InertGpuSource()),
            power: PowerFeature(source: InertPowerSource(), chipName: ""),
            smc: SmcFeature(source: InertSmcSource()),
            sound: SoundFeature(source: InertSoundSource()),
            // 惰性构造:不走 Live 授权控制 + UserDefaults.standard 的生产便利构造器
            // (p2-review/02;测试宿主不读不写用户偏好)。
            bluetooth: .inert(),
            containers: ContainerFeature(source: InertContainerSource()),
            launchdManifest: LaunchdManifestFeature(
                provider: LaunchdManifestProvider(source: InertLaunchdPlistSource())
            )
        )
    }

    /// 具名字段数 == registry 登记条数:加字段漏登记(模块静默失联)即红。
    func testRegistryCoversAllNamedFields() {
        let features = makeFeatures()
        XCTAssertEqual(
            Mirror(reflecting: features).children.count,
            features.registry.count,
            "MonitorFeatures 具名字段与 registry 漂移:有字段漏登记,该模块所有派发都不达"
        )
    }

    /// registry 无重复登记:同一模块登记两次 = 重复派发(传感器重复采样)。
    func testRegistryHasNoDuplicateModules() {
        let features = makeFeatures()
        let identities = features.registry.map(ObjectIdentifier.init)
        XCTAssertEqual(
            Set(identities).count,
            identities.count,
            "registry 里登记了重复模块"
        )
    }
}
