import AppKit
import Foundation
import PulseCore

// MARK: - Live 已装 bundle id 全集采集(p5-cleaner/02)

//
// 判孤儿的权威源(纯值规则在 PulseCore `InstalledAppInventory`):树内 bundle ∪ 标准
// 目录补扫(maxdepth 3,Mole 同款根表机制,零搬码)∪ 运行中 app。同步重活(树遍历 +
// 每个 bundle 一次 plist 读),由调用方放进扫描 / 缓存装载的后台任务——随结果一次
// 采集,不进常驻轮询。
//
// plist 直读 PropertyListSerialization,不走 Bundle(url:):Bundle 实例进程级缓存、
// 同路径永不重读(装机后升级的 app 会读到旧 plist),且分不清「没有 plist」与「plist
// 坏了」——fail-closed 纪律需要这两态分开。

enum LiveInstalledAppInventory {
    /// 生产采集。`scanCancelled` = 本次扫描被取消(半棵树 → fail-closed,不读盘)。
    static func collect(trees: [SpaceNode], scanCancelled: Bool, home: String) -> InstalledAppInventory {
        let begin = Date()
        let treeBundles = scanCancelled ? [] : InstalledAppInventory.bundlePaths(in: trees)
        let standardBundles = scanCancelled ? [] : standardBundlePaths(home: home)
        // NSRunningApplication 线程安全(头文件明载;属性原子返回),列表随主 runloop
        // 刷新——后台读到的是最近一轮快照,对「在跑但 .app 挪走」的兜底足够。
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let inventory = InstalledAppInventory.build(
            bundlePaths: treeBundles + standardBundles,
            runningBundleIDs: running,
            scanCancelled: scanCancelled,
            read: readInfoPlist(at:)
        )
        let elapsed = Int(Date().timeIntervalSince(begin) * 1000)
        switch inventory {
        case let .complete(ids):
            LogService.info(
                "已装全集:\(ids.count) 个 bundle id · 树内 bundle \(treeBundles.count) · 标准目录 \(standardBundles.count) · 运行中 \(running.count) · \(elapsed)ms",
                category: "Cleaner"
            )
        case let .unreadablePlist(path):
            LogService.warn("已装全集:Info.plist 读不了 → 卸载残留整组不出(fail-closed):\(path)", category: "Cleaner")
        case .incompleteScan:
            LogService.info("已装全集:扫描被取消 → 卸载残留整组不出(fail-closed)", category: "Cleaner")
        }
        return inventory
    }

    /// 标准安装目录补扫:find -maxdepth 3 -iname '*.app' 同口径(不剪 bundle——
    /// iOS 包装壳 X.app/Wrapper/X.app 在第 3 层);跳过隐藏目录(Caskroom 的 .metadata)。
    /// 跟随符号链接(/Applications 里的链接 app 也算已装);深度封顶防环。
    static func standardBundlePaths(home: String) -> [String] {
        let fileManager = FileManager.default
        var out: [String] = []
        var stack: [(path: String, depth: Int)] = InstalledAppInventory.standardDirectories(home: home)
            .map { ($0, 0) }
        while let (path, depth) = stack.popLast() {
            guard depth < InstalledAppInventory.standardSearchDepth,
                  let entries = try? fileManager.contentsOfDirectory(atPath: path)
            else { continue } // 根不存在(~/Applications、Caskroom 常缺)不是错误
            for name in entries where !name.hasPrefix(".") {
                let child = path + "/" + name
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { continue }
                if InstalledAppInventory.isBundleDirectoryName(name) {
                    out.append(child)
                }
                stack.append((child, depth + 1))
            }
        }
        return out
    }

    /// 读一个 Info.plist 文件:不存在 = missing;在但读不了 / 不是字典 plist = unreadable。
    static func readInfoPlist(at path: String) -> InfoPlistRead {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return .missing }
        guard let data = fileManager.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return .unreadable }
        return .parsed(bundleID: dictionary["CFBundleIdentifier"] as? String)
    }
}
