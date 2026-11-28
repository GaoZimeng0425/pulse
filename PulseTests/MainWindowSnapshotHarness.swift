import AppKit
@testable import Pulse
import PulseCore
import SwiftUI
import XCTest

/// 主窗口离屏走查工具(main-window-native-list,2026-11-28):主窗口换原生列表前后,
/// 用合成数据把各页画进屏外窗口截图,并程序化滚动量 CPU。只在设了
/// `PULSE_SNAPSHOT_DIR` 时运行(`TEST_RUNNER_PULSE_SNAPSHOT_DIR=… sh scripts/test.sh
/// --only MainWindowSnapshotHarness`),全量检查里跳过——它起真窗口、要几十秒,不是行为断言。
/// 局限:屏外窗口下没有光标,滚动量不到命中测试与跟踪区那一份,只比渲染 + 布局。
@MainActor
final class MainWindowSnapshotHarness: XCTestCase {
    private static let groupCount = 120
    private static let windowSize = NSSize(width: 1280, height: 1400)

    func testSnapshotAndScrollEveryTab() throws {
        guard let directory = ProcessInfo.processInfo.environment["PULSE_SNAPSHOT_DIR"], !directory.isEmpty
        else { throw XCTSkip("未设 PULSE_SNAPSHOT_DIR:离屏走查工具只按需运行") }
        let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let label = ProcessInfo.processInfo.environment["PULSE_SNAPSHOT_LABEL"] ?? "snap"

        // 可选:真实历史库的副本(sqlite3 .backup 出来的),让智能体页画真实账本。
        let historyCopy = ProcessInfo.processInfo.environment["PULSE_SNAPSHOT_HISTORY"]
        let engine = historyCopy.flatMap { path in
            (try? HistoryDatabase.openReader(at: URL(fileURLWithPath: path))).flatMap(\.self)
                .map { HistoryEngine(database: $0) }
        }
        let monitor = SystemMonitor.preview(
            source: Self.syntheticSource(),
            historyEngine: engine ?? HistoryEngine(database: try? HistoryDatabase.openInMemory()),
            agentUsageReadsHistory: engine != nil
        )
        monitor.start()
        // 弹窗档 1s 节奏让两张合成快照尽快差分出 CPU%(主窗口自身不改节奏)。
        monitor.setPopoverTab(.overview)
        spin(seconds: 3)
        monitor.setPopoverTab(nil)

        var report: [String] = []
        // 默认窗宽 1280 走一遍各页;再加两档宽度:智能体 1800(走势 | 日历越过 1512 并排)、
        // 总览 760(网格 2 列、两卡上下排)——按宽度切排法的地方都要量高与显示一致。
        let configs: [(MetricTab, CGFloat)] = [.overview, .cpu, .memory, .disk, .network, .agents].map { ($0, 1280) }
            + [(.agents, 1800), (.overview, 760)]
        for (tab, width) in configs {
            let name = width == 1280 ? tab.rawValue : "\(tab.rawValue)\(Int(width))"
            let window = makeWindow(monitor: monitor, tab: tab, width: width)
            spin(seconds: 2)
            try snapshot(window, to: outputURL.appendingPathComponent("\(label)-\(name)-top.png"))
            let cpu = scrollAndMeasure(window)
            try snapshot(window, to: outputURL.appendingPathComponent("\(label)-\(name)-scrolled.png"))
            scrollToBottom(window)
            try snapshot(window, to: outputURL.appendingPathComponent("\(label)-\(name)-bottom.png"))
            report.append(String(
                format: "SCROLL_CPU %@ tab=%@ cpu=%.0fms/s range=%.0fpt",
                label,
                name,
                cpu.msPerSecond,
                cpu.range
            ))
            window.orderOut(nil)
            window.close()
        }
        monitor.stop()
        let text = report.joined(separator: "\n")
        try text.write(to: outputURL.appendingPathComponent("\(label)-report.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    // MARK: - 合成数据

    /// 120 个各不相同的 App 组,两张快照差分出互不相同的 CPU%,排行够长才量得出滚动成本。
    private static func syntheticSource() -> SyntheticProcessSource {
        let now = Date()
        let apps = (1 ... groupCount).map { index in
            RawProcess(
                pid: pid_t(1000 + index),
                parentPID: 1,
                executablePath: "/Applications/Synthetic\(index).app/Contents/MacOS/Synthetic\(index)",
                cpuTimeNanoseconds: UInt64(index) * 300_000_000,
                physicalFootprintBytes: UInt64(index) * 25_000_000
            )
        }
        let later = apps.map { process in
            RawProcess(
                pid: process.pid,
                parentPID: process.parentPID,
                executablePath: process.executablePath,
                cpuTimeNanoseconds: process.cpuTimeNanoseconds + UInt64(process.pid - 1000) * 9_000_000,
                physicalFootprintBytes: process.physicalFootprintBytes
            )
        }
        return SyntheticProcessSource(snapshots: [
            ProcessSnapshot(takenAt: now, processes: apps),
            ProcessSnapshot(takenAt: now.addingTimeInterval(1), processes: later),
        ])
    }

    // MARK: - 屏外窗口

    private func makeWindow(monitor: SystemMonitor, tab: MetricTab, width: CGFloat) -> NSWindow {
        // 落点簿预置「组排行展开」:排行越过前 20 名的截断,全部 120 行都在,才是长列表。
        let landing = MainWindowLanding()
        landing.stash(tab: tab, rankingID: MetricTabBlockBuilder.groupRankingID(for: tab))
        let root = MainWindowView(
            monitor: monitor,
            initialTab: tab,
            landing: landing,
            cleanAssembly: .preview(monitor: monitor)
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: NSPoint(x: -30000, y: 0),
                size: NSSize(width: width, height: Self.windowSize.height)
            ),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.setFrameOrigin(NSPoint(x: -30000, y: 0))
        window.orderFrontRegardless()
        return window
    }

    private func spin(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return XCTFail("取不到窗口内容位图") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return XCTFail("PNG 编码失败") }
        try data.write(to: url)
    }

    // MARK: - 程序化滚动

    /// 找页面主滚动区(面积最大的 NSScrollView),上下往返滚 3 秒(每帧 ~16ms 一步),
    /// 量本进程这段的 CPU 时间。
    private func scrollAndMeasure(_ window: NSWindow) -> (msPerSecond: Double, range: CGFloat) {
        guard let root = window.contentView,
              let scrollView = Self.scrollViews(in: root).max(by: { $0.frame.height < $1.frame.height }),
              let document = scrollView.documentView
        else { return (0, 0) }
        let range = max(0, document.frame.height - scrollView.contentView.bounds.height)
        guard range > 0 else { return (0, 0) }
        let step = max(8, range / 90)
        var offset: CGFloat = 0
        var direction: CGFloat = 1
        let start = Self.cpuSeconds()
        let wallStart = Date()
        while Date().timeIntervalSince(wallStart) < 3 {
            offset = min(range, max(0, offset + direction * step))
            if offset >= range || offset <= 0 {
                direction *= -1
            }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
        let wall = Date().timeIntervalSince(wallStart)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(range, 900)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return ((Self.cpuSeconds() - start) * 1000 / wall, range)
    }

    private func scrollToBottom(_ window: NSWindow) {
        guard let root = window.contentView,
              let scrollView = Self.scrollViews(in: root).max(by: { $0.frame.height < $1.frame.height }),
              let document = scrollView.documentView
        else { return }
        let bottom = max(0, document.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView {
            found.append(scroll)
        }
        for sub in view.subviews {
            found += scrollViews(in: sub)
        }
        return found
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
