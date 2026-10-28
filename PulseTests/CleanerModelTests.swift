@testable import Pulse
import PulseCore
import XCTest

/// 清理页状态机(p4-cleaner/03):生命周期 / 结果缓存 / FDA 判据来自台账 /
/// 重扫替换。枚举器走协议注入(TestSupport 假实现)——零真盘、零等待真扫描。
@MainActor
final class CleanerModelTests: XCTestCase {
    func testScanFinishesAndCachesResultWithFDAHint() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([
                CleanFixture.file("a.bin", allocated: 512, reclaimable: 512),
                CleanFixture.directory("sub", fileID: 9),
                CleanFixture.directory("locked", fileID: 10),
            ]),
            "/r/sub": .entries([CleanFixture.file("b.bin", allocated: 256, reclaimable: 256)]),
            "/r/locked": .failure(.permissionDenied),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])

        await waitUntil { !model.isScanning }

        guard case let .finished(result) = model.phase else {
            XCTFail("应到 finished,实际 \(model.phase)")
            return
        }
        XCTAssertEqual(result.stats.files, 2)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(model.permissionDeniedCount, 1)
        XCTAssertTrue(model.permissionHint?.contains("1 个目录") == true, "FDA 判据来自台账,非预探测")
        // 结果缓存:不重扫 phase 不变,重进 tab 沿用
        XCTAssertEqual(model.result?.stats.files, 2)
        XCTAssertNotNil(model.scanFinishedAt)
    }

    func testRescanReplacesResult() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("v1.bin", allocated: 128, reclaimable: 128)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertEqual(model.result?.stats.files, 1)

        await fake.set("/r", .entries([
            CleanFixture.file("v2a.bin", allocated: 128, reclaimable: 128),
            CleanFixture.file("v2b.bin", allocated: 128, reclaimable: 128),
        ]))
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }

        XCTAssertEqual(model.result?.stats.files, 2, "重扫替换旧结果")
    }

    /// 零权限失败 → 无 FDA 横幅(不骚扰)。
    func testNoHintWhenNoPermissionFailures() async {
        let fake = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.file("a.bin", allocated: 64, reclaimable: 64)]),
        ])
        let model = CleanerModel()
        model.startScan(using: fake, roots: ["/r"])
        await waitUntil { !model.isScanning }
        XCTAssertNil(model.permissionHint)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 500 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待条件超时(10s)")
    }
}
