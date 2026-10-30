@testable import PulseCore
import XCTest

/// 状态徽章阈值规则(工单 P0.6-04 语义,评审 F1 并入 05 的 chip 实现):
/// ✓正常 / 高负载 的判定边界。规则纯逻辑在此钉死;chip 映射与菜单栏红线
/// 同口径断言要用 app 类型,在 PulseTests/StatusBadgeChipTests。
final class StatusBadgeTests: XCTestCase {
    // MARK: 组卡高负载线(组 CPU% > 100%)

    func testGroupAboveThresholdGetsHighBadge() {
        XCTAssertEqual(StatusBadgeRules.groupBadge(cpuPercent: 100.5), .high)
        XCTAssertEqual(StatusBadgeRules.groupBadge(cpuPercent: 445), .high)
    }

    /// 边界(工单钉死):恰好 100%(单核满载)不算高负载。
    func testGroupAtOrBelowThresholdGetsNoBadge() {
        XCTAssertNil(StatusBadgeRules.groupBadge(cpuPercent: 100))
        XCTAssertNil(StatusBadgeRules.groupBadge(cpuPercent: 99.9))
        XCTAssertNil(StatusBadgeRules.groupBadge(cpuPercent: 0))
    }

    // MARK: 组高负载最忙进程(组行 chip,2026-10-30 用户拍板 B)

    private func group(cpu: Double, processes: [RawProcess]) -> ProcessGroup {
        ProcessGroup(
            id: .project(root: "/Users/x/pulse", worktreeName: "main"), name: "pulse @ main",
            processes: processes, cpuPercent: cpu, memoryBytes: 0
        )
    }

    /// 高负载组取组内首个进程(引擎契约:进程 CPU% 降序)的显示名。
    func testHighLoadGroupNamesTopProcess() {
        let hot = group(cpu: 186, processes: [
            RawProcess(
                pid: 10,
                parentPID: 1,
                executablePath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
            ),
            RawProcess(pid: 11, parentPID: 1, executablePath: "/usr/local/bin/node"),
        ])
        XCTAssertEqual(StatusBadgeRules.groupHotProcessName(hot), "swift-frontend")
    }

    /// 阈值与数值标红同源:恰好 100% 不挂;空组不挂。
    func testHotProcessNameFollowsGroupThreshold() {
        let process = RawProcess(pid: 10, parentPID: 1, executablePath: "/usr/local/bin/node")
        XCTAssertNil(StatusBadgeRules.groupHotProcessName(group(cpu: 100, processes: [process])))
        XCTAssertNil(StatusBadgeRules.groupHotProcessName(group(cpu: 250, processes: [])))
    }

    /// chip 封顶字数(2026-10-30 用户拍板):超长进程名中间省略到上限,chip 自身不再被压缩。
    func testHotProcessNameIsCappedWithMiddleEllipsis() {
        let long = group(cpu: 150, processes: [
            RawProcess(pid: 10, parentPID: 1, executablePath: "/usr/bin/com.apple.WebKit.WebContent.Development"),
        ])
        let name = StatusBadgeRules.groupHotProcessName(long)
        XCTAssertEqual(name?.count, StatusBadgeRules.hotProcessNameMaxLength)
        XCTAssertEqual(name?.hasPrefix("com.apple"), true)
        XCTAssertEqual(name?.hasSuffix("opment"), true)
        XCTAssertEqual(name?.contains("…"), true)
    }

    func testShortHotProcessNameIsUntouched() {
        let short = group(cpu: 150, processes: [
            RawProcess(pid: 10, parentPID: 1, executablePath: "/usr/local/bin/node"),
        ])
        XCTAssertEqual(StatusBadgeRules.groupHotProcessName(short), "node")
    }

    // MARK: 系统负载徽章(空载 ✓正常 / 高负载 / 中间静默)

    func testIdleSystemLoadGetsNormalBadge() {
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 0), .normal)
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 29.9), .normal)
    }

    /// 边界:恰好空载线(30%)不算空载——落入静默档,不挂 chip。
    func testSystemLoadAtIdleThresholdIsSilent() {
        XCTAssertNil(StatusBadgeRules.systemBadge(load: 30))
        XCTAssertNil(StatusBadgeRules.systemBadge(load: 50))
    }

    /// 高负载线与菜单栏变红同口径(> 70%);恰好 70% 不算。
    func testHighSystemLoadGetsHighBadge() {
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 70.1), .high)
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 100), .high)
        XCTAssertNil(StatusBadgeRules.systemBadge(load: 70))
    }
}
