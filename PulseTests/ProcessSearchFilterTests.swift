import XCTest
@testable import Pulse
@testable import PulseCore

/// 主窗口搜索过滤(纯逻辑):名字包含 + 纯数字查询的 pid 前缀,组级与行级口径。
/// 期望值全部为独立字面量;搜索框 UI(⌘F / Esc / 摆位)按 spec 测试决策以手动验收。
final class ProcessSearchFilterTests: XCTestCase {
    private let rows = [
        ProcessRowModel(pid: 100, name: "rustc", cpuPercent: 90, memoryBytes: 200_000_000),
        ProcessRowModel(pid: 11, name: "node", cpuPercent: 5, memoryBytes: 500_000_000),
        ProcessRowModel(pid: 12, name: "Cargo", cpuPercent: 5, memoryBytes: 50_000_000),
        ProcessRowModel(pid: 1234, name: "helper", cpuPercent: 1, memoryBytes: 10_000_000),
    ]

    private func group(name: String) -> ProcessGroup {
        ProcessGroup(
            id: .app(bundlePath: "g-\(name)"), name: name,
            processes: [], cpuPercent: 10, memoryBytes: 100
        )
    }

    // MARK: 查询归一与激活态

    /// 空查询与纯空白查询都算"未在搜索":过滤全旁路,视图与无搜索一致。
    func testEmptyAndWhitespaceQueriesAreInactive() {
        XCTAssertFalse(ProcessSearchFilter(query: "").isActive)
        XCTAssertFalse(ProcessSearchFilter(query: "   \n").isActive)
        XCTAssertTrue(ProcessSearchFilter(query: "x").isActive)
    }

    /// 归一:小写 + 全角数字转半角(中文输入法数字态的兜底)。
    func testNormalizedLowercasesAndMapsFullwidthDigits() {
        XCTAssertEqual(ProcessSearchFilter(query: "  RUSTC ").normalized, "rustc")
        XCTAssertEqual(ProcessSearchFilter(query: "１２").normalized, "12")
    }

    // MARK: 行级匹配

    /// 名字匹配 = 大小写不敏感包含。
    func testNameMatchIsCaseInsensitiveContains() {
        let filter = ProcessSearchFilter(query: "cargo")
        XCTAssertTrue(filter.matches(row: rows[2]))
        XCTAssertFalse(filter.matches(row: rows[0]))

        XCTAssertTrue(ProcessSearchFilter(query: "RUST").matches(row: rows[0]))
    }

    /// 纯数字查询按 pid 前缀匹配:渐进输入下中间态可见("12" 同时命中 12 与 1234)。
    func testNumericQueryMatchesPIDPrefix() {
        let filter = ProcessSearchFilter(query: "12")

        XCTAssertTrue(filter.matches(row: rows[2]), "pid 12 前缀命中")
        XCTAssertTrue(filter.matches(row: rows[3]), "pid 1234 前缀命中")
        XCTAssertFalse(filter.matches(row: rows[0]), "pid 100 非前缀")
        XCTAssertFalse(filter.matches(row: rows[1]), "pid 11 非前缀")

        XCTAssertTrue(ProcessSearchFilter(query: "1234").matches(row: rows[3]), "全 pid 精确命中")
        XCTAssertFalse(ProcessSearchFilter(query: "234").matches(row: rows[3]), "只认前缀,后缀不算")
    }

    /// 纯数字查询仍按名字匹配:名字里带数字的应用名照常可搜("A20")。
    func testNumericQueryAlsoMatchesName() {
        let a20 = ProcessRowModel(pid: 999, name: "A20", cpuPercent: 3, memoryBytes: 10)

        XCTAssertTrue(ProcessSearchFilter(query: "20").matches(row: a20))
    }

    /// 非纯数字查询不做 pid 匹配(混合输入按名字口径)。
    func testNonNumericQueryIgnoresPID() {
        let filter = ProcessSearchFilter(query: "node")

        XCTAssertTrue(filter.matches(row: rows[1]))
        XCTAssertFalse(filter.matches(row: rows[0]))
    }

    // MARK: 组级匹配

    /// 组名命中:命中它自己,行全不命中也算。
    func testGroupMatchesByGroupName() {
        let filter = ProcessSearchFilter(query: "safari")

        XCTAssertTrue(filter.matches(group: group(name: "Safari"), rows: []))
        XCTAssertFalse(filter.matches(group: group(name: "Xcode"), rows: rows))
    }

    /// 行命中连坐组:按 pid 搜要能定位到它所在的组,哪怕组名不匹配。
    func testGroupMatchesWhenAnyRowMatchesByPID() {
        let filter = ProcessSearchFilter(query: "1234")

        XCTAssertTrue(filter.matches(group: group(name: "Xcode"), rows: rows))
    }

    /// 空查询组级全命中(旁路)。
    func testGroupBypassesWhenInactive() {
        XCTAssertTrue(ProcessSearchFilter(query: "  ").matches(group: group(name: "Xcode"), rows: []))
    }

    // MARK: 展开表行集

    /// 组名命中 → 全部行:按应用名搜 = 看这个应用的全部进程(含命名不相干 helper)。
    func testFilterRowsKeepsAllWhenGroupNameMatches() {
        let filter = ProcessSearchFilter(query: "xcode")

        XCTAssertEqual(filter.filterRows(for: group(name: "Xcode"), in: rows).map(\.pid), rows.map(\.pid))
    }

    /// 组因行命中而保留 → 只留命中行,保序(引擎既定序不被搜索打乱)。
    func testFilterRowsKeepsOnlyMatchingRowsOtherwise() {
        let filter = ProcessSearchFilter(query: "12")

        XCTAssertEqual(filter.filterRows(for: group(name: "Xcode"), in: rows).map(\.pid), [12, 1234])
    }

    /// 未在搜索 → 原样返回(不过滤、不复制语义上的差异)。
    func testFilterRowsBypassesWhenInactive() {
        let filter = ProcessSearchFilter(query: "")

        XCTAssertEqual(filter.filterRows(for: group(name: "Xcode"), in: rows).map(\.pid), rows.map(\.pid))
    }

    // MARK: 组列表过滤(静态入口)

    /// 行访问器不可用(nil)→ 退化为仅组名匹配:下钻与组同轮落地,实际不走到。
    func testFilteredGroupsFallsBackToNameOnlyWhenRowsUnavailable() {
        let groups = [group(name: "Safari"), group(name: "Xcode")]
        let filter = ProcessSearchFilter(query: "1234")

        XCTAssertEqual(
            ProcessSearchFilter.filteredGroups(groups, filter: filter) { _ in nil },
            [],
            "pid 命中需要行数据,行不可知时无组幸存"
        )
        XCTAssertEqual(
            ProcessSearchFilter.filteredGroups(groups, filter: ProcessSearchFilter(query: "safari")) { _ in nil }
                .map(\.name),
            ["Safari"]
        )
        XCTAssertEqual(
            ProcessSearchFilter.filteredGroups(groups, filter: ProcessSearchFilter(query: "x")) { $0.name == "Safari" ? [] : nil }
                .map(\.name),
            ["Xcode"],
            "行可知但为空且组名不匹配 → 淘汰(Safari);行 nil → 按组名兜底(Xcode 因名命中)"
        )
    }

    /// 组列表过滤:行命中连坐组(按 pid 搜定位到组),未在搜索全旁路。
    func testFilteredGroupsMatchesByRowAndBypassesWhenInactive() {
        let groups = [group(name: "Safari"), group(name: "Xcode")]

        XCTAssertEqual(
            ProcessSearchFilter.filteredGroups(groups, filter: ProcessSearchFilter(query: "1234")) { _ in rows }
                .map(\.name),
            ["Safari", "Xcode"],
            "两组的行都来自同一份 rows,1234 命中两组的行集 → 两组都保留"
        )
        XCTAssertEqual(
            ProcessSearchFilter.filteredGroups(groups, filter: ProcessSearchFilter(query: "")) { _ in rows },
            groups,
            "未在搜索 → 原序原样"
        )
    }
}
