import Foundation

// MARK: - 异步等待助手(测试共用)

/// 等异步条件成立:每 10ms 让渡一次,上限默认 2s。等的是**异步链落地**,不是
/// sleep 糊断言——超时不抛,让调用方的 XCTAssertEqual 自己红(带真实读数)。
/// @MainActor:条件闭包留在主 actor 求值(Swift 6 不跨隔离发送)。
/// app-volume/01 起 AppVolumeFeatureTests 与 AlertCenterToastTests 共用;
/// (ub-mode 收批合一;存量各文件私有同款助手暂不强制迁移,新测试一律用这个。)
@MainActor
public func waitUntil(
    _ condition: @autoclosure () -> Bool,
    timeout: TimeInterval = 2
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
