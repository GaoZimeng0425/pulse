import XCTest
@testable import Pulse

/// 接缝:SyntheticProcessSource——合成采集源,03/05 工单与 SwiftUI 预览的测试地基。
/// 期望值全部来自注入的字面量夹具,不经实现同源计算。
final class SyntheticProcessSourceTests: XCTestCase {
    /// P0 验收锚点场景的最小核:rustc ← cargo ← node ← Zcode(字段取默认值,够构造进程树)。
    private func zcodeTree() -> [RawProcess] {
        [
            RawProcess(pid: 10, parentPID: 1, executablePath: "/Applications/Zcode.app/Contents/MacOS/Zcode"),
            RawProcess(
                pid: 11,
                parentPID: 10,
                executablePath: "/usr/local/bin/node",
                argv: ["node", "server.js"],
                cwd: "/Users/x/work/octok-client"
            ),
            RawProcess(
                pid: 12,
                parentPID: 11,
                executablePath: "/Users/x/.cargo/bin/cargo",
                argv: ["cargo", "test"],
                cwd: "/Users/x/work/octok-client",
                cpuTimeNanoseconds: 12_000_000_000
            ),
            RawProcess(
                pid: 13,
                parentPID: 12,
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["rustc", "--crate-name", "octok"],
                cwd: "/Users/x/work/octok-client",
                cpuTimeNanoseconds: 445_000_000_000
            ),
        ]
    }

    func testSingleSnapshotSourceRepeatedlyVendsTheInjectedProcesses() {
        let processes = zcodeTree()
        let source = SyntheticProcessSource(processes: processes)

        XCTAssertEqual(source.snapshot().processes, processes)
        XCTAssertEqual(source.snapshot().processes, processes)
    }

    func testInjectedSnapshotSequenceAdvancesOnePerCall() {
        let calm = ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 100), processes: zcodeTree())
        let busy = ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 105), processes: zcodeTree())
        let source = SyntheticProcessSource(snapshots: [calm, busy])

        XCTAssertEqual(source.snapshot().takenAt, calm.takenAt)
        XCTAssertEqual(source.snapshot().takenAt, busy.takenAt)
    }

    func testSequenceClampsAtLastSnapshotOnceExhausted() {
        let first = ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 0), processes: [RawProcess(pid: 1, parentPID: 0)])
        let last = ProcessSnapshot(takenAt: Date(timeIntervalSince1970: 5), processes: [RawProcess(pid: 1, parentPID: 0)])
        let source = SyntheticProcessSource(snapshots: [first, last])

        _ = source.snapshot()
        _ = source.snapshot()
        _ = source.snapshot()

        XCTAssertEqual(source.snapshot(), last)
    }

    func testSnapshotPassesThroughInjectedProcessTreeVerbatim() {
        // 注入顺序原样保留:合成源不做排序/过滤,夹具即世界。
        let reversed = zcodeTree().reversed()
        let source = SyntheticProcessSource(processes: Array(reversed))

        XCTAssertEqual(source.snapshot().processes, Array(reversed))
    }
}
