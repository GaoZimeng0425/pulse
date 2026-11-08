@testable import PulseCore
import XCTest

/// 已装 bundle id 全集(p5-cleaner/02):树内 bundle 发现 + 两布局回退 + fail-closed。
/// 定案见 .scratch/p5-cleaner/spec.md §4/§6;并集只往保守走(多认已装 = 少报孤儿)。
final class InstalledAppInventoryTests: XCTestCase {
    private func dir(_ name: String, under parent: String, children: [SpaceNode] = []) -> SpaceNode {
        let path = parent == "/" ? "/" + name : parent + "/" + name
        return SpaceNode(name: name, path: path, kind: .directory, accountedBytes: 0, children: children)
    }

    /// 读取器夹具:路径 → 结果;未登记 = 不存在。记录调用路径供断言。
    private final class FakeReader {
        var table: [String: InfoPlistRead]
        private(set) var calls: [String] = []

        init(_ table: [String: InfoPlistRead]) {
            self.table = table
        }

        func read(_ path: String) -> InfoPlistRead {
            calls.append(path)
            return table[path] ?? .missing
        }
    }

    // MARK: 树内发现

    func testTreeDiscoveryFindsNestedHelpersAndOffStandardLocations() {
        let helper = dir("Helper.app", under: "/Applications/Foo.app/Contents/Library/LoginItems")
        let foo = dir("Foo.app", under: "/Applications", children: [
            dir("Contents", under: "/Applications/Foo.app", children: [
                dir("Library", under: "/Applications/Foo.app/Contents", children: [
                    dir("LoginItems", under: "/Applications/Foo.app/Contents/Library", children: [helper]),
                ]),
                dir("PlugIns", under: "/Applications/Foo.app/Contents", children: [
                    dir("Share.appex", under: "/Applications/Foo.app/Contents/PlugIns"),
                ]),
            ]),
        ])
        let downloads = dir("Downloads", under: "/Users/me", children: [
            dir("Portable.app", under: "/Users/me/Downloads"),
            dir("notes.application", under: "/Users/me/Downloads"), // 扩展名过长:不是 bundle
            dir("Agent.XPC", under: "/Users/me/Downloads"), // 大小写不敏感
        ])
        let root = SpaceNode(name: "/", path: "/", kind: .directory, children: [
            dir("Applications", under: "/", children: [foo]),
            dir("Users", under: "/", children: [dir("me", under: "/Users", children: [downloads])]),
        ])
        XCTAssertEqual(Set(InstalledAppInventory.bundlePaths(in: [root])), [
            "/Applications/Foo.app",
            "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app",
            "/Applications/Foo.app/Contents/PlugIns/Share.appex",
            "/Users/me/Downloads/Portable.app",
            "/Users/me/Downloads/Agent.XPC",
        ], "进 bundle 内部找嵌套件;Downloads 里直接跑的 app 也算主人还在")
    }

    func testBundleNameRecognitionIsBoundedAndCaseInsensitive() {
        XCTAssertTrue(InstalledAppInventory.isBundleDirectoryName("Foo.app"))
        XCTAssertTrue(InstalledAppInventory.isBundleDirectoryName("Foo.APP"))
        XCTAssertTrue(InstalledAppInventory.isBundleDirectoryName("Share.appex"))
        XCTAssertFalse(InstalledAppInventory.isBundleDirectoryName("Foo.application"))
        XCTAssertFalse(InstalledAppInventory.isBundleDirectoryName("Foo."))
        XCTAssertFalse(InstalledAppInventory.isBundleDirectoryName("app"))
        XCTAssertFalse(InstalledAppInventory.isBundleDirectoryName("Foo.framework"))
    }

    // MARK: 判读与汇总

    func testBuildCollectsIDsWithLayoutFallbackAndRunningMerge() {
        let reader = FakeReader([
            "/A/Foo.app/Contents/Info.plist": .parsed(bundleID: "com.foo"),
            // iOS 包装壳内层:根 Info.plist 布局
            "/A/Wrap.app/Wrapper/Inner.app/Info.plist": .parsed(bundleID: "com.wrapped.ios"),
            "/A/NoID.app/Contents/Info.plist": .parsed(bundleID: nil),
            "/A/Empty.app/Contents/Info.plist": .parsed(bundleID: ""),
        ])
        let inventory = InstalledAppInventory.build(
            bundlePaths: [
                "/A/Foo.app", "/A/Wrap.app", "/A/Wrap.app/Wrapper/Inner.app",
                "/A/NoID.app", "/A/Empty.app", "/A/NoPlist.app",
            ],
            runningBundleIDs: ["com.running.only", ""],
            scanCancelled: false,
            read: reader.read
        )
        XCTAssertEqual(
            inventory,
            .complete(["com.foo", "com.wrapped.ios", "com.running.only"]),
            "无 plist 的包装壳 / 无 id / 空 id 跳过不失败;运行中并入"
        )
        XCTAssertNil(inventory.unavailableReason)
    }

    func testUnreadablePlistFailsClosed() {
        let reader = FakeReader([
            "/A/Good.app/Contents/Info.plist": .parsed(bundleID: "com.good"),
            "/A/Broken.app/Contents/Info.plist": .unreadable,
        ])
        let inventory = InstalledAppInventory.build(
            bundlePaths: ["/A/Good.app", "/A/Broken.app"],
            runningBundleIDs: [],
            scanCancelled: false,
            read: reader.read
        )
        XCTAssertEqual(inventory, .unreadablePlist(bundlePath: "/A/Broken.app"))
        XCTAssertNil(inventory.bundleIDs, "清单不完整无权判孤儿:整组不出")
        XCTAssertTrue(inventory.unavailableReason?.contains("/A/Broken.app") == true, "界面如实说是哪个")
    }

    func testUnreadableRootLayoutAlsoFailsClosed() {
        let reader = FakeReader(["/A/Ios.app/Info.plist": .unreadable])
        let inventory = InstalledAppInventory.build(
            bundlePaths: ["/A/Ios.app"], runningBundleIDs: [], scanCancelled: false, read: reader.read
        )
        XCTAssertEqual(inventory, .unreadablePlist(bundlePath: "/A/Ios.app"))
    }

    func testCancelledScanFailsClosedWithoutReading() {
        let reader = FakeReader(["/A/Foo.app/Contents/Info.plist": .parsed(bundleID: "com.foo")])
        let inventory = InstalledAppInventory.build(
            bundlePaths: ["/A/Foo.app"], runningBundleIDs: ["com.x"], scanCancelled: true, read: reader.read
        )
        XCTAssertEqual(inventory, .incompleteScan)
        XCTAssertNil(inventory.bundleIDs)
        XCTAssertTrue(reader.calls.isEmpty, "半棵树不读盘")
    }

    func testDuplicatePathsAreReadOnce() {
        let reader = FakeReader(["/A/Foo.app/Contents/Info.plist": .parsed(bundleID: "com.foo")])
        _ = InstalledAppInventory.build(
            bundlePaths: ["/A/Foo.app", "/A/Foo.app"], // 树内与标准目录补扫重叠
            runningBundleIDs: [],
            scanCancelled: false,
            read: reader.read
        )
        XCTAssertEqual(reader.calls, ["/A/Foo.app/Contents/Info.plist"])
    }

    func testStandardDirectoriesCoverOffApplicationsInstallSites() {
        let dirs = InstalledAppInventory.standardDirectories(home: "/Users/me/")
        for expected in [
            "/Applications", "/System/Applications", "/Users/me/Applications",
            "/Users/me/Library/Application Support/Setapp/Applications",
            "/opt/homebrew/Caskroom", "/usr/local/Caskroom",
            "/Library/Input Methods", "/Users/me/Library/Input Methods",
        ] {
            XCTAssertTrue(dirs.contains(expected), "\(expected) 不在补扫根表(输入法 / Setapp / 系统应用不住 /Applications)")
        }
    }

    // MARK: 并集的意义:树内找到的 app 保护自己的缓存

    func testTreeFoundDevAppProtectsItsLeftovers() throws {
        let home = "/Users/me"
        let now: TimeInterval = 1_700_000_000
        let caches = SpaceNode(
            name: "Caches", path: home + "/Library/Caches", kind: .directory, accountedBytes: 900,
            children: [SpaceNode(
                name: "com.me.devapp", path: home + "/Library/Caches/com.me.devapp", kind: .directory,
                accountedBytes: 900, newestChangeEpoch: now - 90 * 86400
            )]
        )
        let devApp = dir("Dev.app", under: home + "/proj/build/Products/Debug")
        let tree = dir("Users", under: "/", children: [dir("me", under: "/Users", children: [
            SpaceNode(
                name: "Library",
                path: home + "/Library",
                kind: .directory,
                accountedBytes: 900,
                children: [caches]
            ),
            dir("proj", under: home, children: [dir("build", under: home + "/proj", children: [
                dir("Products", under: home + "/proj/build", children: [
                    dir("Debug", under: home + "/proj/build/Products", children: [devApp]),
                ]),
            ])]),
        ])])
        let inventory = InstalledAppInventory.build(
            bundlePaths: InstalledAppInventory.bundlePaths(in: [tree]),
            runningBundleIDs: [],
            scanCancelled: false,
            read: { $0 == devApp.path + "/Contents/Info.plist" ? .parsed(bundleID: "com.me.devapp") : .missing }
        )
        let ids = try XCTUnwrap(inventory.bundleIDs)
        let orphans = OrphanLeftoverDetector.detect(
            in: [tree], home: home, installedBundleIDs: ids, excludedPathPrefixes: [], now: now
        )
        XCTAssertTrue(orphans.isEmpty, "构建产物里的自研 app 不在 /Applications,也不该把它的缓存判成卸载残留")
    }
}
