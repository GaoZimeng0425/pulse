import AppKit
import Observation
@testable import Pulse
import SwiftUI
import XCTest

/// 原生列表自量行的高度自校正(main-window-native-list,2026-11-28):行内的局部状态
/// (组下钻里点开进程详情、智能体项目明细展开、项目「显示全部」)只在行自己的宿主里
/// 刷新,宿主视图的 body 不重跑,列表不会重量——行高停在旧值,内容被裁或留白,要等
/// 下一轮数据刷新(主窗口 5s)才恢复。自量行必须自己把自然高度报给列表。
@MainActor
final class NativeListSelfSizingTests: XCTestCase {
    @Observable
    final class Toggle {
        var expanded = false
    }

    /// 行内容读一个宿主不观察的状态盒(宿主 body 不会因它重跑)。
    private struct ExpandingRow: View {
        let toggle: Toggle

        var body: some View {
            VStack(spacing: 0) {
                Color.red.frame(height: 40)
                if toggle.expanded {
                    Color.blue.frame(height: 120)
                }
            }
        }
    }

    func testMeasuredRowFollowsInRowStateChangeWithoutHostUpdate() throws {
        let toggle = Toggle()
        let list = NativeList(
            rows: [NativeListRow(kind: "card", height: .measured(key: "card")) {
                AnyView(ExpandingRow(toggle: toggle))
            }],
            resetToken: 0
        )
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: list.frame(width: 400, height: 600))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let table = try XCTUnwrap(Self.table(in: window.contentView))
        XCTAssertEqual(table.rect(ofRow: 0).height, 40, accuracy: 1)

        toggle.expanded = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(
            table.rect(ofRow: 0).height, 160, accuracy: 1,
            "行内状态撑高了内容,行高必须跟上(不等宿主下一轮刷新)"
        )

        toggle.expanded = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(table.rect(ofRow: 0).height, 40, accuracy: 1, "收起后行高也要缩回")
    }

    /// 行内局部 @State 撑高(智能体页切范围 / 展开项目):离屏量高器那份状态永远是默认值。
    private struct LocalStateRow: View {
        @State private var expanded: Bool

        init(startsExpanded: Bool) {
            _expanded = State(initialValue: startsExpanded)
        }

        var body: some View {
            VStack(spacing: 0) {
                Color.red.frame(height: 40)
                if expanded {
                    Color.blue.frame(height: 120)
                }
            }
        }
    }

    /// 评审 HIGH:行内局部状态撑高后,宿主下一轮刷新(行结构不变)不得用离屏量高器
    /// (默认状态)把行高压回去——可见行的高度只认它自报的自然高。
    func testHostRefreshDoesNotRevertSelfReportedHeightToSizerDefault() throws {
        // 第 1 次调用给离屏量高器(收起),之后给可见行(展开)= 模拟「用户在行里点开了」。
        var calls = 0
        let rows = [NativeListRow(kind: "pane", height: .measured(key: "pane")) {
            calls += 1
            return AnyView(LocalStateRow(startsExpanded: calls >= 2))
        }]
        let coordinator = NativeList.Coordinator()
        let scrollView = coordinator.makeScrollView(showsVerticalScroller: false)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer { window.close() }
        coordinator.update(rows: rows, resetToken: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let table = try XCTUnwrap(Self.table(in: scrollView))
        XCTAssertEqual(table.rect(ofRow: 0).height, 160, accuracy: 1, "可见行自报展开后的高度")

        // 宿主刷新(数据变了、行结构不变):不得把行压回量高器的默认高度。
        coordinator.update(rows: rows, resetToken: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(table.rect(ofRow: 0).height, 160, accuracy: 1, "刷新后行高仍跟可见内容一致")
    }

    private static func table(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView {
            return table
        }
        for sub in view.subviews {
            if let found = table(in: sub) {
                return found
            }
        }
        return nil
    }
}
