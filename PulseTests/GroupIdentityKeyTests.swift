import XCTest
@testable import Pulse
@testable import PulseCore

/// stableKey 逆映射(工单 03):历史库 group_id(字符串)读回重建类型化身份
/// ——往返恒等,非法字符串拒绝而不是硬造身份。
final class GroupIdentityKeyTests: XCTestCase {
    /// 六类身份的 stableKey → 逆映射严格互逆。
    func testRoundTripForAllIdentityShapes() {
        let identities: [GroupIdentity] = [
            .app(bundlePath: "/Applications/Alpha.app"),
            .project(root: "/Users/x/pulse", worktreeName: nil),
            .project(root: "/Users/x/pulse", worktreeName: "03"),
            .system,
            .backgroundService,
            .orphan,
        ]
        for identity in identities {
            XCTAssertEqual(GroupIdentity(stableKey: identity.stableKey), identity)
        }
    }

    /// App 路径里的特殊字符(冒号、@)不破坏 bundle 解析。
    func testBundlePathMayContainAtAndColon() {
        let identity = GroupIdentity.app(bundlePath: "/Applications/We:ird@2.0.app")
        XCTAssertEqual(GroupIdentity(stableKey: identity.stableKey), identity)
    }

    /// worktree 名拆分取第一个 "@":根是绝对路径,worktree 名里的 @ 得以保留;
    /// 根含 @ 属字符串约定的既知限制。
    func testProjectWorktreeSplitsAtTheFirstAtSign() {
        let identity = GroupIdentity.project(root: "/Users/x/pulse", worktreeName: "feat@x")
        XCTAssertEqual(
            GroupIdentity(stableKey: identity.stableKey),
            GroupIdentity.project(root: "/Users/x/pulse", worktreeName: "feat@x")
        )
    }

    /// 非法/不完整的键一律拒绝(failable),绝不硬造身份。
    func testMalformedKeysAreRejected() {
        XCTAssertNil(GroupIdentity(stableKey: ""))
        XCTAssertNil(GroupIdentity(stableKey: "unknown:thing"))
        XCTAssertNil(GroupIdentity(stableKey: "bundle:"))
        XCTAssertNil(GroupIdentity(stableKey: "project:"))
        XCTAssertNil(GroupIdentity(stableKey: "project:/root/@"))
        XCTAssertNil(GroupIdentity(stableKey: "project:@wt"))
    }
}
