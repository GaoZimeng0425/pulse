import Darwin
import XCTest
@testable import Pulse

// 测试宿主隔离(2026-10-19 架构讨论实测的回归钉):
// 单元测试托管在 app 内(TEST_HOST),宿主若走完整 PulseApp 装配,拉起即
// SystemMonitor → HistoryEngine.openDefault() 以读写方式打开生产历史库,
// 菜单栏标签的 .task 还会启动真实采样与落库——测试运行期间与 /Applications
// 里的常驻实例同写一份库。宿主进程本身就是被测对象:枚举自身全部 fd,
// 断言没有任何一个指向生产库(含 -wal / -shm)。
final class TestHostIsolationTests: XCTestCase {
    func testHostProcessHoldsNoProductionHistoryDatabaseHandle() {
        let databasePath = HistoryDatabase.defaultURL.resolvingSymlinksInPath().path
        let leaked = openFilePaths().filter { $0.hasPrefix(databasePath) }
        XCTAssertEqual(leaked, [], "测试宿主持有生产历史库句柄:\(leaked)")
    }

    /// 本进程全部打开文件的路径(F_GETPATH 逐 fd 反查;非文件 fd 跳过)。
    private func openFilePaths() -> [String] {
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<getdtablesize() {
            let found = buffer.withUnsafeMutableBytes { raw in
                fcntl(fd, F_GETPATH, raw.baseAddress!) != -1
            }
            if found {
                paths.append(String(cString: buffer))
            }
        }
        return paths
    }
}
