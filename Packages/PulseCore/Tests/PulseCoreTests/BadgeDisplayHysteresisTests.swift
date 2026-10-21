@testable import PulseCore
import XCTest

/// 菜单栏徽标显示迟滞(badge-hysteresis/01,纯值状态机):死区边界、对称性、锚在显示值
/// 不累积、强调级越权立即、占位切换立即、网络槽直通、三槽同口径。参数(±2pp /
/// 红线 70)为维护者 2026-10-21 拍板,末例把它们钉死——改参数必须有意识地改测试。
final class BadgeDisplayHysteresisTests: XCTestCase {
    // MARK: - CPU

    /// 新读数取整与已显示整数差 1:不换,返回的仍是**已显示的原始读数**(不是新读数)。
    func testCPUWithinDeadbandKeepsDisplayedReading() {
        let displayed = data(cpu: 38.4)
        XCTAssertEqual(update(displayed, cpu: 39.4).cpuLoadPercent, 38.4)
        XCTAssertEqual(update(displayed, cpu: 37.4).cpuLoadPercent, 38.4)
    }

    /// 差恰为 2 即换,上行下行同阈值(对称死区,拍板)。
    func testCPUAtDeadbandEdgeAdoptsInBothDirections() {
        let displayed = data(cpu: 38.4)
        XCTAssertEqual(update(displayed, cpu: 40.4).cpuLoadPercent, 40.4)
        XCTAssertEqual(update(displayed, cpu: 36.4).cpuLoadPercent, 36.4)
    }

    /// 锚在显示值而非上一轮原始值:连续两轮 39.4(差 1,不换)之后来 40.4——对显示值
    /// 38 差 2 必须换;若错锚在上一轮原始值 39.4,差 1 会一直不换,显示越钉越偏。
    func testCPUDeadbandAnchorsOnDisplayedValueNotLastReading() {
        var shown = data(cpu: 38.0)
        shown = update(shown, cpu: 39.4)
        shown = update(shown, cpu: 39.4)
        XCTAssertEqual(shown.cpuLoadPercent, 38.0)
        shown = update(shown, cpu: 40.4)
        XCTAssertEqual(shown.cpuLoadPercent, 40.4)
    }

    /// 红线(>70,严格大于)两侧切换立即换,哪怕取整只差 1;恰好 70.0 不红,仍按死区。
    func testCPUCrossingRedLineAdoptsImmediatelyEvenWithinDeadband() {
        XCTAssertEqual(update(data(cpu: 68.9), cpu: 70.1).cpuLoadPercent, 70.1)
        XCTAssertEqual(update(data(cpu: 70.5), cpu: 69.9).cpuLoadPercent, 69.9)
        XCTAssertEqual(update(data(cpu: 69.0), cpu: 70.0).cpuLoadPercent, 69.0)
    }

    /// 占位 ↔ 读数两个方向都立即。
    func testCPUPlaceholderTransitionsAreImmediate() {
        XCTAssertEqual(update(data(cpu: nil), cpu: 5.0).cpuLoadPercent, 5.0)
        XCTAssertNil(update(data(cpu: 5.0), cpu: nil).cpuLoadPercent)
    }

    // MARK: - RAM

    /// 压力等级变化(橙 / 红)立即换,占比完全相同也换。
    func testMemoryPressureChangeAdoptsImmediately() {
        let displayed = data(memory: memory(percent: 40, pressure: .normal))
        let warning = memory(percent: 40, pressure: .warning)
        XCTAssertEqual(update(displayed, memory: warning).memory, warning)
    }

    /// 压力不变:已用占比死区——差 1 保留已显示的整份构成,差 2 采纳新构成。
    func testMemoryUsedPercentDeadbandKeepsDisplayedBreakdown() {
        let shown = memory(percent: 40, pressure: .normal)
        let displayed = data(memory: shown)
        XCTAssertEqual(update(displayed, memory: memory(percent: 41, pressure: .normal)).memory, shown)
        let moved = memory(percent: 42, pressure: .normal)
        XCTAssertEqual(update(displayed, memory: moved).memory, moved)
        XCTAssertNil(update(displayed, memory: nil).memory)
    }

    // MARK: - 磁盘剩余

    /// 两字节数作一个槽原子采纳;剩余占比死区;可显示性切换(缺读数 / 总量 0)立即。
    func testDiskSlotIsAtomicWithRemainingPercentDeadband() {
        let displayed = data(diskAvailable: 400, diskTotal: 1000)
        let kept = update(displayed, diskAvailable: 410, diskTotal: 1000)
        XCTAssertEqual(kept.diskAvailableBytes, 400)
        XCTAssertEqual(kept.diskTotalBytes, 1000)
        let moved = update(displayed, diskAvailable: 380, diskTotal: 1000)
        XCTAssertEqual(moved.diskAvailableBytes, 380)
        XCTAssertNil(update(displayed, diskAvailable: nil, diskTotal: nil).diskTotalBytes)
        XCTAssertEqual(
            update(data(diskAvailable: 400, diskTotal: 0), diskAvailable: 401, diskTotal: 1000).diskTotalBytes,
            1000
        )
    }

    // MARK: - 网络

    /// 网络速率槽直通(拍板排除迟滞):每轮都采纳新读数,含回到 nil。
    func testNetworkRatePassesThroughEveryRound() {
        let displayed = data(network: NetworkRates(upBytesPerSecond: 100, downBytesPerSecond: 200))
        let next = NetworkRates(upBytesPerSecond: 101, downBytesPerSecond: 200)
        XCTAssertEqual(update(displayed, network: next).networkRate, next)
        XCTAssertNil(update(displayed, network: nil).networkRate)
    }

    // MARK: - 整体

    /// 全部槽都在死区内抖动时,输出与已显示快照**逐位相等**——这是 app 侧"相等就不
    /// 赋值、不触发 SwiftUI 失效"的前提。
    func testAllSlotsWithinDeadbandReturnDisplayedSnapshotVerbatim() {
        let displayed = MenuBarBadgeData(
            cpuLoadPercent: 38.4,
            memory: memory(percent: 60, pressure: .normal),
            diskAvailableBytes: 400,
            diskTotalBytes: 1000,
            networkRate: nil
        )
        let jitter = MenuBarBadgeData(
            cpuLoadPercent: 39.3,
            memory: memory(percent: 61, pressure: .normal),
            diskAvailableBytes: 405,
            diskTotalBytes: 1000,
            networkRate: nil
        )
        XCTAssertEqual(BadgeDisplayHysteresis.update(displayed: displayed, incoming: jitter), displayed)
        XCTAssertEqual(BadgeDisplayHysteresis.update(displayed: displayed, incoming: displayed), displayed)
    }

    /// 拍板参数钉死:±2pp 死区、红线 70。
    func testParametersPinnedToTriageDecision() {
        XCTAssertEqual(BadgeDisplayHysteresis.deadbandPoints, 2)
        XCTAssertEqual(BadgeDisplayHysteresis.cpuRedThreshold, 70)
    }

    // MARK: - 夹具

    private func data(
        cpu: Double? = nil,
        memory: MemoryBreakdown? = nil,
        diskAvailable: Int64? = nil,
        diskTotal: UInt64? = nil,
        network: NetworkRates? = nil
    ) -> MenuBarBadgeData {
        MenuBarBadgeData(
            cpuLoadPercent: cpu,
            memory: memory,
            diskAvailableBytes: diskAvailable,
            diskTotalBytes: diskTotal,
            networkRate: network
        )
    }

    private func update(_ displayed: MenuBarBadgeData, cpu: Double?) -> MenuBarBadgeData {
        var incoming = displayed
        incoming.cpuLoadPercent = cpu
        return BadgeDisplayHysteresis.update(displayed: displayed, incoming: incoming)
    }

    private func update(_ displayed: MenuBarBadgeData, memory: MemoryBreakdown?) -> MenuBarBadgeData {
        var incoming = displayed
        incoming.memory = memory
        return BadgeDisplayHysteresis.update(displayed: displayed, incoming: incoming)
    }

    private func update(_ displayed: MenuBarBadgeData, diskAvailable: Int64?, diskTotal: UInt64?) -> MenuBarBadgeData {
        var incoming = displayed
        incoming.diskAvailableBytes = diskAvailable
        incoming.diskTotalBytes = diskTotal
        return BadgeDisplayHysteresis.update(displayed: displayed, incoming: incoming)
    }

    private func update(_ displayed: MenuBarBadgeData, network: NetworkRates?) -> MenuBarBadgeData {
        var incoming = displayed
        incoming.networkRate = network
        return BadgeDisplayHysteresis.update(displayed: displayed, incoming: incoming)
    }

    /// 已用占比精确等于 percent 的内存构成(总量 100_000,只填 app 页)。
    private func memory(percent: UInt64, pressure: MemoryPressure) -> MemoryBreakdown {
        MemoryBreakdown(
            totalBytes: 100_000,
            appBytes: percent * 1000,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedBytes: 0,
            pressure: pressure
        )
    }
}
