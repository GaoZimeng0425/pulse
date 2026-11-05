import AppKit
@testable import Pulse
import XCTest

@MainActor
final class DockPresenceTests: XCTestCase {
    func testMainWindowBecomingKeyShowsDockIcon() {
        XCTAssertEqual(DockPresence.policy(for: .becameKey, isMainWindow: true, alphaValue: 1), .regular)
    }

    func testMainWindowClosingHidesDockIcon() {
        XCTAssertEqual(DockPresence.policy(for: .willClose, isMainWindow: true, alphaValue: 1), .accessory)
    }

    func testLaunchHiddenFrameDoesNotFlashDockIcon() {
        XCTAssertNil(DockPresence.policy(for: .becameKey, isMainWindow: true, alphaValue: 0))
    }

    func testOtherWindowsLeaveDockAlone() {
        XCTAssertNil(DockPresence.policy(for: .becameKey, isMainWindow: false, alphaValue: 1))
        XCTAssertNil(DockPresence.policy(for: .willClose, isMainWindow: false, alphaValue: 1))
    }
}
