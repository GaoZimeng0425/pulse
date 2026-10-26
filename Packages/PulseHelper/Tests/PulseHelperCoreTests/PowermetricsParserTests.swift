import PulseHelperCore
import XCTest

/// powermetrics 解析口径(p3-root-mcp/03):夹具 = 探针 08 真实输出的
/// 等形片段(列数一致、名字含空格/括号、DEAD_TASKS 的 -1 pid、section 结束)。
final class PowermetricsParserTests: XCTestCase {
    private let fixture = """
    Machine model: Mac16,1
    OS version: 26A434

    *** Sampled system activity ***

    *** Running tasks ***

    Name                               ID     CPU ms/s  User%  Deadlines (<2 ms, 2-5 ms)  Wakeups (Intr, Pkg idle)  Energy Impact
    WindowServer                       409    456.71    76.85  156.92  4.90               703.18  208.90                   1222.12
    OrbStack Helper                    82786  471.10    73.03  204.97  51.98              334.43  60.81                   1167.39
    DEAD_TASKS                         -1     122.63    42.55  5.90    0.00               5.90    0.98                     88.68
    Browser Helper (Renderer)          30277  48.14     53.33  0.00    0.00               716.91  184.38                   5.36

    **** Battery and backlight usage ****
    **** Network activity ****
    """

    func testParsesNamesWithSpacesAndNegativePid() {
        let rows = PowermetricsParser.parse(fixture)
        // DEAD_TASKS(-1)照报:pid 合法整数,归组侧自会消化(系统僵尸口径)。
        XCTAssertEqual(rows.map(\.name), [
            "WindowServer", "OrbStack Helper", "DEAD_TASKS", "Browser Helper (Renderer)",
        ])
        XCTAssertEqual(rows.map(\.pid), [409, 82786, -1, 30277])
        XCTAssertEqual(rows.map(\.impact), [1222.12, 1167.39, 88.68, 5.36], accuracy: 0.001)
    }

    func testStopsAtNextSection() {
        let rows = PowermetricsParser.parse(fixture)
        // Battery/Network section 之后的行(若有)不进结果:本夹具无进程行,
        // 以"恰好 4 行 + 不含 section 文本"钉边界。
        XCTAssertFalse(rows.contains { $0.name.contains("Battery") })
        XCTAssertEqual(rows.count, 4)
    }

    func testEmptyAndMissingTableReturnEmpty() {
        XCTAssertTrue(PowermetricsParser.parse("").isEmpty)
        XCTAssertTrue(PowermetricsParser.parse("Machine model: Mac16,1\n").isEmpty)
        // 有表头但零数据行。
        XCTAssertTrue(
            PowermetricsParser.parse("*** Running tasks ***\nName ID CPU\n").isEmpty
        )
    }

    func testHeaderColumnCountDrivesSplit() {
        // 表头少两列(模拟不同 flag 集):切列随表头走,不靠硬编码列数。
        let alt = """
        *** Running tasks ***

        Name       ID    Energy Impact
        WeChat     476   4.35
        """
        let rows = PowermetricsParser.parse(alt)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "WeChat")
        XCTAssertEqual(rows[0].pid, 476)
        XCTAssertEqual(rows[0].impact, 4.35, accuracy: 0.001)
    }
}

private func XCTAssertEqual(
    _ lhs: [Double], _ rhs: [Double], accuracy: Double,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard lhs.count == rhs.count else {
        XCTFail("长度不一致 \(lhs) vs \(rhs)", file: file, line: line)
        return
    }
    for (a, b) in zip(lhs, rhs) where abs(a - b) > accuracy {
        XCTFail("\(a) 与 \(b) 差超过 \(accuracy)", file: file, line: line)
    }
}
