import XCTest
@testable import Pulse
@testable import PulseCore

/// 工单 01 模块排行·网络每进程(nettop)数据层:CSV 解析器用合成夹具覆盖
/// 正常行 / 缺列 / 非数字 / 怪名称(含点)/ 空输出 / 只有表头 / 负数——
/// 解析全程容错,坏行跳过不中断;provider 用合成 CSV 源驱动差分与门控,
/// 零真实子进程(格式事实由真机探针钉死,见 NettopSource.swift 文件头)。
final class NettopProcessRateTests: XCTestCase {

    // MARK: - 测试替身

    /// 脚本化 nettop CSV 源:按序吐出注入文本(nil = 起不来 / 运行失败),
    /// 耗尽后停在 nil;记录调用次数(门控断言用)。
    private final class ScriptedNettopCSVSource: NettopCSVSource, @unchecked Sendable {
        private let lock = NSLock()
        private let texts: [String?]
        private var index = 0
        private var reads = 0

        init(_ texts: [String?]) {
            self.texts = texts
        }

        func read() async -> String? {
            nextText()
        }

        /// 锁操作收进同步方法:NSLock 禁止在 async 上下文直接调用。
        private func nextText() -> String? {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            guard index < texts.count else { return nil }
            defer { index += 1 }
            return texts[index]
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    /// 合成时钟:按序吐出注入时刻(差分对墙钟的确定性时间轴)。
    private final class ScriptedClock: @unchecked Sendable {
        private let lock = NSLock()
        private let dates: [Date]
        private var index = 0

        init(epochSeconds: [TimeInterval]) {
            self.dates = epochSeconds.map { Date(timeIntervalSinceReferenceDate: $0) }
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            let date = dates[min(index, dates.count - 1)]
            index += 1
            return date
        }
    }

    private let takenAt = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: - CSV 解析(合成夹具)

    func testParserReadsNormalRowsAfterHeader() {
        // 正常行:名称.pid,入,出[,尾随空列];表头无条件跳过。
        let csv = """
        ,bytes_in,bytes_out,
        Safari.1234,100,200,
        apsd.380,6864,157295,
        """
        let table = NettopCSVParser.parse(csv, takenAt: takenAt)
        XCTAssertEqual(table.takenAt, takenAt)
        XCTAssertEqual(table.bytes[1234], NettopProcessBytes(downBytes: 100, upBytes: 200))
        XCTAssertEqual(table.bytes[380], NettopProcessBytes(downBytes: 6864, upBytes: 157295))
        XCTAssertEqual(table.bytes.count, 2)
    }

    func testParserSplitsPIDAtLastDotForDottedNames() {
        // bundle 前缀辅助进程名称可含多个点:pid = 最后一个点之后的段。
        let table = NettopCSVParser.parse(
            ",bytes_in,bytes_out,\ncom.apple.WebKit.Networking.999,10,20,",
            takenAt: takenAt
        )
        XCTAssertEqual(table.bytes[999], NettopProcessBytes(downBytes: 10, upBytes: 20))
        XCTAssertEqual(table.bytes.count, 1, "只此一行一条:不得按中间点拆出别的 pid")
    }

    func testParserSkipsRowsMissingColumns() {
        // 缺列(只有 1–2 列)跳行,不中断其余行。
        let table = NettopCSVParser.parse(
            ",bytes_in,bytes_out,\nSafari.1,100,\nSafari.2\n\nok.3,7,8,",
            takenAt: takenAt
        )
        XCTAssertEqual(Array(table.bytes.keys).sorted(), [3])
    }

    func testParserSkipsNonNumericAndEmptyPIDSegments() {
        // pid 段非数字 / 空(名称以点结尾)跳行。
        let table = NettopCSVParser.parse(
            ",bytes_in,bytes_out,\nSafari.abc,1,2,\nSafari.,3,4,",
            takenAt: takenAt
        )
        XCTAssertTrue(table.bytes.isEmpty)
    }

    func testParserSkipsNegativeOrNonNumericByteFields() {
        // 负数(UInt64 拒收)/ 乱码字节列跳行,不钳不猜。
        let table = NettopCSVParser.parse(
            ",bytes_in,bytes_out,\nbad.1,-5,2,\nbad.2,x,3,\ngood.3,1,-2,\nok.4,5,6,",
            takenAt: takenAt
        )
        XCTAssertEqual(Array(table.bytes.keys).sorted(), [4])
    }

    func testParserAccumulatesDuplicatePIDRows() {
        // 同 pid 多行(口径外重复):字节累加视作合计。
        let table = NettopCSVParser.parse(
            ",bytes_in,bytes_out,\ndup.7,10,20,\ndup.7,1,2,",
            takenAt: takenAt
        )
        XCTAssertEqual(table.bytes[7], NettopProcessBytes(downBytes: 11, upBytes: 22))
    }

    func testParserYieldsEmptyTableForEmptyOutputAndHeaderOnly() {
        // 空输出 / 只有表头:空表(不是失败)——按普通轮进差分账本。
        XCTAssertTrue(NettopCSVParser.parse("", takenAt: takenAt).bytes.isEmpty)
        XCTAssertTrue(NettopCSVParser.parse(",bytes_in,bytes_out,", takenAt: takenAt).bytes.isEmpty)
        // 纯空白与换行同样为空表,不崩。
        XCTAssertTrue(NettopCSVParser.parse("\n\n", takenAt: takenAt).bytes.isEmpty)
    }

    // MARK: - Provider(合成 CSV 源 + 假时钟驱动)

    func testNetworkFirstRoundBaselineThenRatesOverWallClock() async {
        // 首轮记基线;第二轮对实际墙钟间隔(2s)折算:Δdown 300/2s、Δup 300/2s。
        let source = ScriptedNettopCSVSource([
            ",bytes_in,bytes_out,\nSafari.1,100,200,",
            ",bytes_in,bytes_out,\nSafari.1,400,500,",
        ])
        let provider = ProcessNetworkRateProvider(source: source, clock: ScriptedClock(epochSeconds: [0, 2]).now)
        provider.setVisible(true)

        let first = await provider.snapshot()
        XCTAssertNil(first, "基线轮不出数")
        let second = await provider.snapshot()
        XCTAssertEqual(second?[1]?.downBytesPerSec ?? -1, 150, accuracy: 1e-9)
        XCTAssertEqual(second?[1]?.upBytesPerSec ?? -1, 150, accuracy: 1e-9)
        XCTAssertNotNil(provider.lastGood)
    }

    func testNetworkNilCSVKeepsLastGoodAndEmptyTableClears() async {
        // 起不来 / 失败(nil)→ 读数 nil,lastGood 保留;空回包 → 空表按
        // 普通轮差分,读数如实清空(下轮从新基线重立)。
        let source = ScriptedNettopCSVSource([
            ",bytes_in,bytes_out,\nSafari.1,100,200,",
            ",bytes_in,bytes_out,\nSafari.1,400,500,",
            nil,
            "",
        ])
        let provider = ProcessNetworkRateProvider(source: source, clock: ScriptedClock(epochSeconds: [0, 2, 4, 6]).now)
        provider.setVisible(true)
        _ = await provider.snapshot()
        let good = await provider.snapshot()
        XCTAssertEqual(good?[1]?.downBytesPerSec ?? -1, 150, accuracy: 1e-9)

        let failed = await provider.snapshot()
        XCTAssertNil(failed, "nil CSV = 读失败,消费方保 lastGood")
        XCTAssertEqual(provider.lastGood?[1]?.downBytesPerSec, good?[1]?.downBytesPerSec)

        let empty = await provider.snapshot()
        XCTAssertEqual(empty, [:], "空回包 = 空表,读数如实清空")
    }

    func testNetworkGateClosedSkipsSourceEntirely() async {
        // 门关 = 零子进程成本:源零调用。
        let source = ScriptedNettopCSVSource([",bytes_in,bytes_out,\nSafari.1,1,1,"])
        let provider = ProcessNetworkRateProvider(source: source, clock: ScriptedClock(epochSeconds: [0]).now)

        let reading = await provider.snapshot()
        XCTAssertNil(reading)
        XCTAssertEqual(source.callCount, 0, "门关时不起子进程")
    }

    func testNetworkCadenceIsFiveSeconds() {
        // 节奏契约(工单 01):网络每进程 5s 低频档。
        let provider = ProcessNetworkRateProvider(
            source: ScriptedNettopCSVSource([]),
            clock: ScriptedClock(epochSeconds: [0]).now
        )
        XCTAssertEqual(provider.cadence, .every(seconds: 5))
    }
}
