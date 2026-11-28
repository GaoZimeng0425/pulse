import AppKit
@testable import Pulse
import PulseCore
import SwiftUI
import XCTest

/// 幽灵弹窗(phantom-popover,2026-11-28 用户报「Pulse 常驻 CPU 近 10%」):弹窗面板
/// 懒创建,而「重开主窗口」路径(点 Dock / Finder 双击 / Spotlight)会先 closePanel()
/// ——在从没开过弹窗时当场把面板连同门控视图建出来。SwiftUI 的 onAppear 在**从没
/// 上屏**的面板里照样触发(探针实测;onDisappear 永不触发),门控若在 onAppear 里
/// 写可见性,Pulse 就认定「弹窗开着」:采样节奏卡在 1s、隐形弹窗每秒整页重算,直到
/// 用户真开关一次弹窗或重启。可见性写路径只许 AppKit 层的 openPanel / closePanel。
@MainActor
final class PopoverVisibilitySignalTests: XCTestCase {
    func testGateHostedInNeverShownPanelDoesNotReportPopoverVisible() {
        let monitor = SystemMonitor.preview()
        XCTAssertFalse(monitor.popoverVisible)

        // 复刻 PopupPanel 的挂法:defer 面板 + 毛玻璃底 + NSHostingView,从不 orderFront。
        let hosting = NSHostingView(rootView: MenuBarPopoverGate(monitor: monitor))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 648)
        let effect = NSVisualEffectView(frame: hosting.frame)
        effect.addSubview(hosting)
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = effect
        panel.orderOut(nil)

        // 给 SwiftUI 一段主线程空转,让 onAppear / task 这类回调有机会落地。
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(
            monitor.popoverVisible,
            "从没上屏的弹窗面板不得把可见性报成「开着」(否则采样卡 1s、隐形弹窗每秒重算)"
        )
        XCTAssertNil(monitor.currentPopoverTab)
        monitor.stop()
    }
}
