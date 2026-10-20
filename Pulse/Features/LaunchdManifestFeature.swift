import Foundation
import PulseCore

/// launchd 服务清单功能模块(launchd-attribution/01;ADR-0003 MonitorFeature):60 秒一档的
/// 清单 provider 经 sensorDrivers 登记,每次交付整份替换进主干的归组配置
/// (MonitorHost.setLaunchdServiceExecutablePaths),下一轮归组即以新清单判定后台服务。
/// 没有视图要读的状态、没有 onRound——它只是把一个低频读数送进主干,不持有宿主之外
/// 的任何引用。
@MainActor
final class LaunchdManifestFeature: MonitorFeature {
    private let provider: LaunchdManifestProvider
    private var host: MonitorHost = .inert

    init(provider: LaunchdManifestProvider) {
        self.provider = provider
    }

    func start(_ host: MonitorHost) {
        self.host = host
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            provider.driver { [weak self] paths in
                // nil = 从未成功读过且本轮也失败:主干保持现有清单(初值空集 = 只剩静态域)。
                guard let paths else { return }
                Task { @MainActor in
                    self?.host.setLaunchdServiceExecutablePaths(paths)
                }
            },
        ]
    }
}
