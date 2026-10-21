@testable import Pulse
@testable import PulseCore
import XCTest

/// 测试进程文件日志隔离(2026-10-19 误报事故的回归钉):
/// 单元测试托管在 app 内(TEST_HOST),夹具告警会走真实 LogService 路径;
/// 判定函数保证测试环境不装文件日志,~/.Pulse/logs 只反映真实运行。
/// 端到端半边(跑测试后生产日志目录无新文件)由 scripts/test.sh +
/// `find ~/.Pulse/logs -newer` 走查覆盖,不在单测内伪造。
final class LogServiceTests: XCTestCase {
    func testXCTestHostEnvironmentIsDetected() {
        XCTAssertTrue(LogService.isRunningTests(
            ["XCTestConfigurationFilePath": "/tmp/something.xctestconfiguration"]
        ))
    }

    func testProductionEnvironmentIsNotDetected() {
        XCTAssertFalse(LogService.isRunningTests([:]))
        XCTAssertFalse(LogService.isRunningTests(["HOME": "/Users/someone"]))
    }

    func testHostProcessNowRunsInsideTestEnvironment() {
        // 宿主自身也须命中判定(本条在 xctest 内跑,天然红绿自证)。
        XCTAssertTrue(LogService.isRunningTests())
    }
}
