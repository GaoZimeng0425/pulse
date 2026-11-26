@testable import Pulse
import PulseCore
import SwiftUI
import XCTest

// agent-tab/14:行内等高排法的钉子——只量几何、不上屏:整页按弹窗原生列表同款量法
// (宽定、高无上限)离屏量高;子视图尺寸经 onGeometryChange 回报。

@MainActor
final class EqualHeightRowTests: XCTestCase {
    /// 弹窗内容宽:面板 360 − 两侧内距 12 × 2(DESIGN.md `{layout.popover-size}`)。
    private static let popoverContentWidth: CGFloat = 336
    func testUsagePaneMeasuresToBoundedHeightLikePopoverList() {
        let pane = AnyView(
            AgentUsagePaneView(
                rows: Self.usageRows(),
                projectRows: Self.projectRows(),
                modelRows: [],
                sessionCounts: [:],
                usage: nil,
                liveProjectCounts: [:],
                isCompact: true,
                isScanning: false,
                onRescan: {}
            )
            .padding(.vertical, 4)
        )
        let height = Self.measuredHeight(of: pane)
        // 页高随数据行数变,这里钉的是「不被撑爆」:弹窗一屏 648,余量放到两万点。
        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThan(height, 20000)
    }

    func testRowStretchesShortCellToTallestUnderPopoverMeasurement() {
        let recorder = FrameRecorder()
        let measured = Self.measuredHeight(of: AnyView(Self.probeRow(recorder)))
        XCTAssertLessThan(measured, 1000)
        let hosting = NSHostingView(rootView: AnyView(Self.probeRow(recorder)))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.popoverContentWidth, height: ceil(measured))
        Self.settle(hosting, recorder: recorder)
        Self.assertEqualHeights(recorder)
    }

    func testRowStretchesShortCellToTallestInScrollView() {
        let recorder = FrameRecorder()
        let hosting = NSHostingView(rootView: AnyView(ScrollView { Self.probeRow(recorder) }))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.popoverContentWidth, height: 400)
        Self.settle(hosting, recorder: recorder)
        Self.assertEqualHeights(recorder)
    }

    // MARK: 行内等高的探针

    /// 一行两张探针卡:自然高不同(1 行字 vs 4 行字)。
    private static func probeRow(_ recorder: FrameRecorder) -> some View {
        EqualHeightRow(spacing: 8) {
            ProbeCell(key: "short", lines: 1, recorder: recorder)
            ProbeCell(key: "tall", lines: 4, recorder: recorder)
        }
        .padding(.horizontal, 16)
    }

    private static func settle(_ view: NSHostingView<AnyView>, recorder: FrameRecorder) {
        view.layoutSubtreeIfNeeded()
        // SwiftUI 的几何回报靠主运行循环驱动;等两张卡都回报,超时交给断言报数。
        let deadline = Date().addingTimeInterval(2)
        while recorder.count < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    private static func assertEqualHeights(_ recorder: FrameRecorder) {
        let short = recorder.height(of: "short") ?? -1
        let tall = recorder.height(of: "tall") ?? -2
        XCTAssertEqual(short, tall, accuracy: 0.5)
    }

    // MARK: 夹具与量法

    /// 弹窗原生列表的量法:宽定、高取最大有限值,取内容的理想高。
    private static func measuredHeight(of view: AnyView) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        let size = controller.sizeThatFits(
            in: CGSize(width: popoverContentWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return size.height
    }

    /// 今天倒推 offset 天的账本日键;日期从当前时钟推,不写死(写死的夹具跨午夜必挂)。
    private static func dayKey(offset: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date()))!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 近 30 天、两家各一行。
    private static func usageRows() -> [AgentDailyUsageRow] {
        (0 ..< 30).flatMap { offset in
            [
                AgentDailyUsageRow(
                    day: dayKey(offset: offset),
                    source: .claude,
                    origin: .jsonl,
                    totalTokens: 300_000_000
                ),
                AgentDailyUsageRow(
                    day: dayKey(offset: offset),
                    source: .zcode,
                    origin: .jsonl,
                    totalTokens: 90_000_000
                ),
            ]
        }
    }

    /// 两个项目 × 近 30 天:项目榜单里有不止一行。
    private static func projectRows() -> [AgentProjectUsageRow] {
        ["pulse", "octok-client"].flatMap { project in
            (0 ..< 30).map { offset in
                AgentProjectUsageRow(
                    day: dayKey(offset: offset),
                    source: .claude,
                    project: project,
                    inputTokens: 30_000_000,
                    outputTokens: 6_000_000,
                    cacheReadTokens: 100_000_000,
                    cacheWriteTokens: 3_000_000,
                    totalTokens: 139_000_000,
                    requestCount: 40
                )
            }
        }
    }
}

/// 探针卡的高度记录器。
/// @unchecked 前提:heights 只在 NSLock 下读写(onGeometryChange 回调写、测试体读;
/// 锁是给 Sendable 检查器的串行化证明)。
private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var heights: [String: CGFloat] = [:]

    func record(_ key: String, height: CGFloat) {
        lock.lock()
        heights[key] = height
        lock.unlock()
    }

    func height(of key: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return heights[key]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return heights.count
    }
}

/// 探针卡:`lines` 行字决定自然高;先撑框、后铺底色(等高排法对卡的要求),
/// 回报的是带底色的整张卡的高。
private struct ProbeCell: View {
    let key: String
    let lines: Int
    let recorder: FrameRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0 ..< lines, id: \.self) { _ in
                Text("行").font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.red, in: .rect(cornerRadius: 12))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            recorder.record(key, height: height)
        }
    }
}
