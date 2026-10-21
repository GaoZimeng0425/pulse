@testable import Pulse
@testable import PulseCore
import XCTest

/// 接缝(工单 11:诊断报告一键复制):
/// - `SamplingStats` 采样累计统计(纯值类型, Sampler 每轮推进);
/// - `DiagnosticReport.assemble` 报告拼装(纯函数,时钟/统计/日志尾全部注入);
/// - `DiagnosticReport.logTail` 日志尾部截取(目录与 FileManager 注入)。
/// 期望值是独立约定的文案字面量,不与实现同源计算。
final class DiagnosticReportTests: XCTestCase {
    /// 本地时区的固定时刻(2026-10-16 13:00):与报告时间戳格式化同一时区口径
    /// (都走 .current),期望字面量在任何机器上都不漂移。
    private lazy var base: Date = {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 10
        comps.day = 16
        comps.hour = 13
        return Calendar.current.date(from: comps)!
    }()

    private var tempDirectory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = NSTemporaryDirectory() + "diagnostic-report-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(atPath: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    /// 已采三轮的统计:时长 1/2/3s,进程数 10/20/15,首采于 base。
    private var sampledStats: SamplingStats {
        var stats = SamplingStats()
        stats.record(startedAt: base, roundDuration: 1, processCount: 10)
        stats.record(startedAt: base, roundDuration: 2, processCount: 20)
        stats.record(startedAt: base, roundDuration: 3, processCount: 15)
        return stats
    }

    // MARK: SamplingStats(采样累计统计)

    func testSamplingStatsStartsEmptyWithoutFabricatingZeros() {
        let stats = SamplingStats()

        XCTAssertNil(stats.startedAt)
        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertNil(stats.averageRoundDuration)
        XCTAssertNil(stats.peakProcessCount)
    }

    func testSamplingStatsAccumulatesAveragePeakAndFirstStartedAt() {
        // 均值 = (1+2+3)/3 = 2s;峰值取最大进程数;运行起点只认首轮。
        let stats = sampledStats

        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.averageRoundDuration ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(stats.peakProcessCount, 20)
        XCTAssertEqual(stats.startedAt, base)
        // 后续 record 不改写运行起点。
        var stats2 = stats
        stats2.record(startedAt: base.addingTimeInterval(100), roundDuration: 1, processCount: 5)
        XCTAssertEqual(stats2.startedAt, base)
    }

    // MARK: assemble(报告拼装)

    func testAssembleContainsAllSpecFieldsAsPlainText() {
        let report = DiagnosticReport.assemble(
            version: "0.1.0",
            build: "1",
            macOSVersion: "Version 26.0 (Build 25A354)",
            chipName: "Apple M4 Pro",
            stats: sampledStats,
            logTail: "2026/10/16 13:07:01:123 [App] Pulse 启动",
            now: base.addingTimeInterval(5400)
        )

        // 标题 + 本地生成时间(注入时钟)。
        XCTAssertTrue(report.contains("Pulse 诊断报告"))
        XCTAssertTrue(report.contains("生成时间: 2026-10-16 14:30:00"))
        // 应用段。
        XCTAssertTrue(report.contains("版本: 0.1.0 (1)"))
        // 系统段。
        XCTAssertTrue(report.contains("macOS: Version 26.0 (Build 25A354)"))
        XCTAssertTrue(report.contains("机型芯片: Apple M4 Pro"))
        // 采样统计段:运行 90 分钟,均值 2s = 2000ms。
        XCTAssertTrue(report.contains("运行时长: 1 小时 30 分"))
        XCTAssertTrue(report.contains("采样轮数: 3"))
        XCTAssertTrue(report.contains("平均轮耗时: 2000.0 ms"))
        XCTAssertTrue(report.contains("进程数峰值: 20"))
        // 日志段:尾部原文照贴。
        XCTAssertTrue(report.contains("最近日志"))
        XCTAssertTrue(report.contains("2026/10/16 13:07:01:123 [App] Pulse 启动"))
    }

    func testAssembleMarksMissingFieldsAsUnavailable() {
        // 冷启动(未采一轮)且无芯片名、无日志:全部如实标"暂无",不伪造 0。
        let report = DiagnosticReport.assemble(
            version: "0.1.0",
            build: "1",
            macOSVersion: "Version 26.0",
            chipName: nil,
            stats: SamplingStats(),
            logTail: nil,
            now: base
        )

        XCTAssertTrue(report.contains("机型芯片: 暂无"))
        XCTAssertTrue(report.contains("运行时长: 暂无"))
        XCTAssertTrue(report.contains("采样轮数: 暂无"))
        XCTAssertTrue(report.contains("平均轮耗时: 暂无"))
        XCTAssertTrue(report.contains("进程数峰值: 暂无"))
        XCTAssertTrue(report.contains("暂无"))
    }

    // MARK: logTail(日志尾部截取)

    private func writeLog(_ name: String, lines: [String], modifiedAt: Date) throws {
        let path = tempDirectory + "/" + name
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: path
        )
    }

    func testLogTailTakesNewestLinesAcrossRotatedFilesInChronologicalOrder() throws {
        // 轮转场景:旧文件 3 行(更早),新文件 2 行(更近)。
        // 取尾部 4 行 = 旧文件末 2 行 + 新文件全部,按时间序(旧 → 新)拼回。
        try writeLog("pulse-a.log", lines: ["l1", "l2", "l3"], modifiedAt: base)
        try writeLog("pulse-b.log", lines: ["m1", "m2"], modifiedAt: base.addingTimeInterval(60))

        let tail = DiagnosticReport.logTail(
            directory: tempDirectory,
            maxLines: 4,
            fileManager: .default
        )

        XCTAssertEqual(tail, "l2\nl3\nm1\nm2")
    }

    func testLogTailTruncatesNewestFileWhenItAloneExceedsLimit() throws {
        try writeLog("pulse-a.log", lines: ["l1", "l2", "l3"], modifiedAt: base)
        try writeLog("pulse-b.log", lines: ["m1", "m2", "m3", "m4", "m5"], modifiedAt: base.addingTimeInterval(60))

        let tail = DiagnosticReport.logTail(
            directory: tempDirectory,
            maxLines: 3,
            fileManager: .default
        )

        // 最新文件自身已够 N 行,不再翻旧文件。
        XCTAssertEqual(tail, "m3\nm4\nm5")
    }

    func testLogTailIgnoresNonLogFiles() throws {
        try writeLog("pulse-a.log", lines: ["l1"], modifiedAt: base)
        try writeLog("notes.txt", lines: ["不应入选"], modifiedAt: base.addingTimeInterval(120))

        let tail = DiagnosticReport.logTail(
            directory: tempDirectory,
            maxLines: 10,
            fileManager: .default
        )

        XCTAssertEqual(tail, "l1")
    }

    func testLogTailReturnsNilForMissingOrEmptyDirectory() {
        XCTAssertNil(DiagnosticReport.logTail(
            directory: tempDirectory + "/不存在",
            maxLines: 10,
            fileManager: .default
        ))

        XCTAssertNil(DiagnosticReport.logTail(
            directory: tempDirectory,
            maxLines: 10,
            fileManager: .default
        ))
    }
}
