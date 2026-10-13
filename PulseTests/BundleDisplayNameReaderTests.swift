import XCTest
@testable import Pulse

/// bundle 显示名读取器(工单 05 注入归组配置的 CFBundleName 读取实现):
/// 读 `<bundle>/Contents/Info.plist`,按路径缓存,读不到退化为 nil
/// (引擎自行用 bundle 目录名推导)。真实磁盘夹具在临时目录里构造。
final class BundleDisplayNameReaderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-reader-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// 造一个 .app 目录;bundleName 非 nil 时写入含 CFBundleName 的 Info.plist。
    private func makeBundle(directory: String, bundleName: String?) throws -> String {
        let contents = root.appendingPathComponent("\(directory)/Contents")
        try FileManager.default.createDirectory(
            at: contents, withIntermediateDirectories: true
        )
        guard let bundleName else { return root.appendingPathComponent(directory).path }
        let plist = ["CFBundleName": bundleName] as NSDictionary
        plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        return root.appendingPathComponent(directory).path
    }

    func testReadsCFBundleNameFromBundleInfoPlist() throws {
        let bundle = try makeBundle(directory: "Renamed.app", bundleName: "脉冲")

        XCTAssertEqual(BundleDisplayNameReader().displayName(forBundleDirectory: bundle), "脉冲")
    }

    func testMissingInfoPlistDegradesToNil() throws {
        let bundle = try makeBundle(directory: "Bare.app", bundleName: nil)

        XCTAssertNil(BundleDisplayNameReader().displayName(forBundleDirectory: bundle))
    }

    /// 采样每秒跑一次:同一 bundle 路径重复读取应命中缓存——
    /// 首读之后磁盘上改名,读到的仍是首读结果。
    func testReadsAreCachedPerBundlePath() throws {
        let reader = BundleDisplayNameReader()
        let bundle = try makeBundle(directory: "Cached.app", bundleName: "旧名字")
        XCTAssertEqual(reader.displayName(forBundleDirectory: bundle), "旧名字")

        _ = try makeBundle(directory: "Cached.app", bundleName: "新名字")
        XCTAssertEqual(reader.displayName(forBundleDirectory: bundle), "旧名字")
    }
}
