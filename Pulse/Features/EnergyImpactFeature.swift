import Foundation
import Observation
import PulseCore
import ServiceManagement

/// 特权助手功能模块(p3-root-mcp/03):60s 档拉取 helper 的 per-process
/// Energy Impact,按进程名聚合 top 与全机合计;合计经 `FeatureEvent.gauges`
/// 广播进历史窄表(GaugeKey.energyImpact,助手缺席不产行 = 空段诚实)。
/// **归组口径 v1 = 进程名聚合**(记档理由):pid→组映射依赖采样轮时序,
/// 60s 档与 5s 心跳不同拍有 pid 复用错配风险;名字聚合对"哪个 App 耗电"
/// 够用,精细归组留 04 Agents 用量卡按需再进。不做可见性门控:60s 单档
/// 一次 XPC 短调用,开销可忽略,数据以落库为目的(与容器/蓝牙的可见门控
/// 动机不同——它们一轮成本高)。
@Observable
@MainActor
final class EnergyImpactFeature: MonitorFeature {
    /// 一轮聚合结果:top 进程(名聚合,impact 降序)+ 全机合计 + 采样时刻。
    private(set) var reading: EnergyImpactReading?

    /// 拉取缝:Live = XPC client;预览/测试注入合成闭包(60s 循环不设缝,
    /// 真机验收,探针 09 同族)。
    typealias Fetch = @Sendable () async throws
        -> (samples: [(pid: Int, name: String, impact: Double)], collectedAt: Date)

    private let fetch: Fetch
    private var host: MonitorHost?
    private var pollTask: Task<Void, Never>?

    init(fetch: @escaping Fetch = { try await EnergyHelperClient().fetchLatest() }) {
        self.fetch = fetch
    }

    func start(_ host: MonitorHost) {
        self.host = host
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private var lastFetchFailed = false

    private func pollOnce() async {
        let result: (samples: [(pid: Int, name: String, impact: Double)], collectedAt: Date)?
        do {
            result = try await fetch()
        } catch {
            // 翻转才记(读路径健康状态沿):未装期间每分钟一条 error 会刷屏。
            if !lastFetchFailed {
                LogService.error("特权助手拉取失败(未装/未批准/超时):\(error.localizedDescription)", category: "Energy")
                lastFetchFailed = true
            }
            return
        }
        if lastFetchFailed {
            LogService.info("特权助手拉取恢复", category: "Energy")
        }
        lastFetchFailed = false
        guard let result else { return } // 编译器收窄(catch 路径已 return)
        let aggregated = Self.aggregate(result.samples)
        guard !aggregated.isEmpty else { return }
        let total = aggregated.reduce(0) { $0 + $1.impact }
        reading = EnergyImpactReading(
            top: aggregated.sorted { $0.impact > $1.impact }.prefix(10)
                .map { EnergyImpactReading.Row(name: $0.name, impact: $0.impact) },
            totalImpact: total,
            collectedAt: result.collectedAt
        )
        host?.broadcast(.gauges([.energyImpact: total]))
    }

    /// 同名进程求和(纯函数,单测钉口径)。
    nonisolated static func aggregate(_ samples: [(pid: Int, name: String, impact: Double)]) -> [(
        name: String,
        impact: Double
    )] {
        var byName: [String: Double] = [:]
        for sample in samples where sample.impact > 0 {
            byName[sample.name, default: 0] += sample.impact
        }
        return byName.map { (name: $0.key, impact: $0.value) }
    }
}

/// 能耗影响读数(top 名聚合行 + 全机合计)。
struct EnergyImpactReading: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        let name: String
        let impact: Double
        var id: String {
            name
        }
    }

    let top: [Row]
    let totalImpact: Double
    let collectedAt: Date
}

// MARK: - 设置页状态桥(特权助手三态)

/// SMAppService daemon 状态的 UI 桥:设置页开关直接驱动 register/unregister
/// (探针 09 结论:register() 报 Code=1 是等用户批准的中间态,status 才是
/// 判据;批准动作在系统设置,app 侧只如实显示三态)。
@MainActor
enum PrivilegedHelperStatus {
    case notRegistered
    case requiresApproval
    case enabled

    static func current(plistName: String = "com.gaozimeng.pulse.helper2.plist") -> PrivilegedHelperStatus {
        switch SMAppService.daemon(plistName: plistName).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .notRegistered
        }
    }

    static func setInstalled(_ installed: Bool) {
        let service = SMAppService.daemon(plistName: "com.gaozimeng.pulse.helper2.plist")
        if installed {
            try? service.register()
        } else {
            try? service.unregister()
        }
    }
}
