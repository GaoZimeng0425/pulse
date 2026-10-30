import Observation
@testable import Pulse
import XCTest

/// AppKit 面板观察回路(popover-appkit/01):只在读到的属性变化时重放、同一拍多次
/// 变化合并为一次、停止后不再重放、没读到的属性变化不触发。
@MainActor
final class ObservedUpdaterTests: XCTestCase {
    func testStartRunsOnceImmediately() {
        let source = UpdaterSourceStub()
        var runs = 0
        let updater = ObservedUpdater {
            _ = source.read
            runs += 1
        }
        updater.start()
        XCTAssertEqual(runs, 1)
        updater.start() // 幂等
        XCTAssertEqual(runs, 1)
    }

    func testReplaysAfterTrackedChangeAndCoalesces() async {
        let source = UpdaterSourceStub()
        var seen: [Int] = []
        let updater = ObservedUpdater { seen.append(source.read) }
        updater.start()

        source.read = 1
        source.read = 2
        source.read = 3
        await drainMainActor()
        XCTAssertEqual(seen, [0, 3], "同一拍内三次写入只重放一次,读到最新值")

        source.read = 4
        await drainMainActor()
        XCTAssertEqual(seen, [0, 3, 4])
    }

    func testUntrackedChangeDoesNotReplay() async {
        let source = UpdaterSourceStub()
        var runs = 0
        let updater = ObservedUpdater {
            _ = source.read
            runs += 1
        }
        updater.start()
        source.unread = 9
        await drainMainActor()
        XCTAssertEqual(runs, 1)
    }

    func testStopHaltsReplay() async {
        let source = UpdaterSourceStub()
        var runs = 0
        let updater = ObservedUpdater {
            _ = source.read
            runs += 1
        }
        updater.start()
        updater.stop()
        source.read = 1
        await drainMainActor()
        XCTAssertEqual(runs, 1)

        // 重启后照常追踪,旧追踪轮的迟到回调不会多跑一次。
        updater.start()
        XCTAssertEqual(runs, 2)
        source.read = 2
        await drainMainActor()
        XCTAssertEqual(runs, 3)
    }

    private func drainMainActor(_ iterations: Int = 50) async {
        for _ in 0 ..< iterations {
            await Task.yield()
        }
    }
}

@MainActor
@Observable
private final class UpdaterSourceStub {
    var read = 0
    var unread = 0
}
