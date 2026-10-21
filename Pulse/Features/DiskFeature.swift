import Foundation
import Observation
import PulseCore

/// 磁盘功能模块(工单 p1-history/05;ADR-0003 MonitorFeature):容量与吞吐两个
/// 自有传感器(ADR-0004)经 sensorDrivers 登记进 SystemMonitor 的调度器;视图直读
/// `capacity` / `throughput`。每份交付都广播给其他模块——吞吐带新鲜度标记,历史
/// 记账只认 fresh(恰好一次,arch-review-2026-10-18 甲5);容量喂磁盘剩余告警。
/// 读失败交付 lastGood(driver 口径),不回退为 nil、不白屏。
@Observable
@MainActor
final class DiskFeature: MonitorFeature {
    /// 磁盘容量读数(工单 p1-history/05):容器对账 + 可清除 + 各卷 + 快照,低频档
    /// (30s)交付;首轮前 nil → 卡片全占位(磁盘页常驻轴,无电池页的隐藏问题)。
    private(set) var capacity: DiskCapacityReading?
    /// 磁盘吞吐读数:系统级读写速率 + 走势,短档(5s)或回退档(30s,随源路径)
    /// 交付;首轮前 nil → 速率列占位。
    private(set) var throughput: DiskThroughputReading?

    private let capacityProvider: DiskCapacityProvider
    private let throughputProvider: DiskThroughputProvider
    @ObservationIgnored private var host: MonitorHost?

    /// `throughputSource` 由工厂选定(Live = adoptingBestPath,回退档带上与 Sampler
    /// 同一个心跳中继——arch-review-2026-10-18/01 高2)。
    init(capacitySource: any DiskCapacitySource, throughputSource: any DiskThroughputSource) {
        capacityProvider = DiskCapacityProvider(source: capacitySource)
        throughputProvider = DiskThroughputProvider(source: throughputSource)
    }

    // MARK: - MonitorFeature

    func start(_ host: MonitorHost) {
        self.host = host
    }

    /// 两个登记项:交付在调度上下文,跳回 MainActor 落地。
    func sensorDrivers() -> [SensorDriver] {
        [
            capacityProvider.driver { [weak self] reading in
                guard let self else { return }
                Task { @MainActor in self.applyCapacity(reading) }
            },
            throughputProvider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in self.applyThroughput(delivery) }
            },
        ]
    }

    // MARK: - 落地

    /// nil = 从未有过读数(非 APFS 系统 / 首轮前)→ 保持占位。
    private func applyCapacity(_ reading: DiskCapacityReading?) {
        guard let reading else { return }
        capacity = reading
        host?.broadcast(.diskCapacity(reading))
    }

    /// 每份交付都广播(记账的新鲜度判断在消费方);展示侧同值不重画。
    private func applyThroughput(_ delivery: SensorDelivery<DiskThroughputReading>?) {
        guard let delivery else { return }
        host?.broadcast(.diskThroughput(delivery))
        if delivery.reading != throughput {
            throughput = delivery.reading
        }
    }
}
