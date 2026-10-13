import Foundation

/// bundle 显示名读取器(GroupingConfiguration.bundleDisplayName 的 UI 层注入实现):
/// 读 `<bundle>/Contents/Info.plist` 的 `CFBundleName`(spec 实现决策);
/// 缺失 / 空串 / 读失败 → nil,引擎自行退化为 bundle 目录名去掉 .app 后缀。
///
/// 按 bundle 路径缓存(nil 也是有效缓存结果):采样每秒跑一遍归组,
/// 不能让重复的 plist 读盘进热路径。线程安全——归组可能在任意执行器上跑。
final class BundleDisplayNameReader: @unchecked Sendable {
    static let shared = BundleDisplayNameReader()

    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    func displayName(forBundleDirectory bundleDirectory: String) -> String? {
        lock.lock()
        if let cached = cache[bundleDirectory] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let plistPath = (bundleDirectory as NSString)
            .appendingPathComponent("Contents/Info.plist")
        let raw = (NSDictionary(contentsOfFile: plistPath)?["CFBundleName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (raw?.isEmpty == false) ? raw : nil

        lock.lock()
        cache[bundleDirectory] = resolved
        lock.unlock()
        return resolved
    }
}
