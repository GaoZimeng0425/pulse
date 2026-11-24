@testable import PulseCore
import XCTest

/// 用户域判定(arch-clean/02):决定权限错误是「去授权全盘访问可解」还是「系统保护」。
final class CleanPathDomainTests: XCTestCase {
    func testUserHomePathsInBothVolumeDomains() {
        XCTAssertTrue(CleanPathDomain.isUserDomain("/Users/dev/Library/Mail"))
        XCTAssertTrue(CleanPathDomain.isUserDomain("/System/Volumes/Data/Users/dev/Library/Mail"))
    }

    func testSystemPathsAreNotUserDomain() {
        XCTAssertFalse(CleanPathDomain.isUserDomain("/private/var/db/diagnostics"))
        XCTAssertFalse(CleanPathDomain.isUserDomain("/System/Volumes/Data/private/var/folders"))
        XCTAssertFalse(CleanPathDomain.isUserDomain("/Library/Caches"))
        // 前缀须带分隔符:/Users 本身与 /UsersX 不算家目录之下。
        XCTAssertFalse(CleanPathDomain.isUserDomain("/Users"))
        XCTAssertFalse(CleanPathDomain.isUserDomain("/UsersShared/x"))
    }
}
