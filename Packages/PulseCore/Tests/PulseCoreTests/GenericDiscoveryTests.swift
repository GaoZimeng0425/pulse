@testable import PulseCore
import XCTest

/// 通用发现 + 保护名单(p7-cleaner/02;ADR-0013;GLOSSARY「通用发现」「保护名单」)。
/// 接缝 = 扫描树 → 候选清单:手搭家目录下的三处(缓存 / 日志 / 应用数据),已认领路径、
/// 排除目录、运行中应用作为输入注入,零真盘。
final class GenericDiscoveryTests: XCTestCase {
    // MARK: 夹具(手搭 ~/Library 域树)

    private let home = "/Users/me"
    private let now: TimeInterval = 1_700_000_000

    private var cachesPath: String {
        home + "/Library/Caches"
    }

    private var logsPath: String {
        home + "/Library/Logs"
    }

    private var appSupportPath: String {
        home + "/Library/Application Support"
    }

    private func dir(
        _ name: String,
        under parent: String,
        bytes: Int64 = 0,
        newest: Double? = nil,
        ownModified: Double? = nil,
        partial: Bool = false,
        children: [SpaceNode] = []
    ) -> SpaceNode {
        SpaceNode(
            name: name,
            // 根那一层不能拼出「//Users」:扫描树按路径分量下钻,多一个斜杠就定位不到。
            path: parent == "/" ? "/" + name : parent + "/" + name,
            kind: .directory,
            accountedBytes: max(bytes, children.reduce(Int64(0)) { $0 + $1.accountedBytes }),
            isPartial: partial,
            newestChangeEpoch: newest,
            ownModifiedEpoch: ownModified,
            children: children
        )
    }

    /// 家目录树:三个域按需出现(传空的域不建,顺带钉住「域不存在自然不产出」)。
    private func tree(
        caches: [SpaceNode] = [],
        logs: [SpaceNode] = [],
        appSupport: [SpaceNode] = []
    ) -> SpaceNode {
        var library: [SpaceNode] = []
        if !caches.isEmpty {
            library.append(dir("Caches", under: home + "/Library", children: caches))
        }
        if !logs.isEmpty {
            library.append(dir("Logs", under: home + "/Library", children: logs))
        }
        if !appSupport.isEmpty {
            library.append(dir("Application Support", under: home + "/Library", children: appSupport))
        }
        return dir("Users", under: "/", children: [
            dir("me", under: "/Users", children: [dir("Library", under: home, children: library)]),
        ])
    }

    /// 扫描树 → 通用发现的候选(不判「在运行」;那一步见各用例里的 `excludingRunningApps`)。
    private func detect(
        in tree: SpaceNode,
        claimed: [JunkCandidate] = [],
        excluded: [String] = []
    ) -> [JunkCandidate] {
        GenericDiscovery.detect(
            in: [tree],
            home: home,
            claimedBy: claimed,
            excludedPathPrefixes: excluded
        )
    }

    // MARK: 缓存目录

    /// 名单外的缓存目录出现在清单里:「先检查」+「未识别」,归应用缓存组,大小照抄树上的节点。
    func testUnlistedCacheDirectoryIsListedAsUnidentified() throws {
        let tree = tree(caches: [
            dir("SomeTool", under: cachesPath, bytes: 700, newest: now - 5 * 86400),
        ])

        let item = try XCTUnwrap(detect(in: tree).only)

        XCTAssertEqual(item.ruleID, GenericDiscovery.ruleID)
        XCTAssertEqual(item.path, cachesPath + "/SomeTool")
        XCTAssertEqual(item.tier, .checkFirst, "名单外的条目永不进自动勾选")
        XCTAssertEqual(item.flags, [.unidentified])
        XCTAssertEqual(item.group, .appCache, "并入现有分组,不新开")
        XCTAssertEqual(item.bytes, 700)
        XCTAssertEqual(item.title, "SomeTool")
        XCTAssertFalse(item.rationale.isEmpty, "行悬停要有一句说明")
    }

    /// 「按新旧」排序用子树内任何文件的最新变动(与卸载残留同口径),不是目录自己那一层;
    /// 「扫描后动没动过」的复核值照抄目录自身。
    func testNewestChangeComesFromDeepInsideTheSubtree() throws {
        let tool = dir(
            "SomeTool",
            under: cachesPath,
            newest: now - 90 * 86400,
            ownModified: now - 100 * 86400,
            children: [
                dir("deep", under: cachesPath + "/SomeTool", bytes: 100, newest: now - 3600),
            ]
        )

        let item = try XCTUnwrap(detect(in: tree(caches: [tool])).only)

        XCTAssertEqual(item.newestChangeEpoch, now - 3600)
        XCTAssertEqual(item.modifiedAtScan, now - 100 * 86400)
    }

    /// 一级条目里只收目录:文件、符号链接、套接字都不列(链接不跟随,与扫描器同纪律)。
    func testOnlyDirectoriesAreListed() {
        func entry(_ kind: FsEntrySnapshot.Kind, _ name: String) -> SpaceNode {
            SpaceNode(name: name, path: cachesPath + "/" + name, kind: kind, accountedBytes: 100)
        }
        let tree = tree(caches: [
            entry(.file, "SomeTool.log"),
            entry(.symlink, "LinkedTool"),
            entry(.other, "SomeSocket"),
        ])

        XCTAssertTrue(detect(in: tree).isEmpty)
    }

    // MARK: 噪音纪律 / 排除 / 位置范围

    /// 零字节且不是部分扫描的条目不列(没什么可回收);部分扫描的即便 0 字节也列并标「部分」。
    func testZeroByteEntryListedOnlyWhenPartial() throws {
        let tree = tree(caches: [
            dir("EmptyTool", under: cachesPath, bytes: 0),
            dir("UnreadableTool", under: cachesPath, bytes: 0, partial: true),
        ])

        let item = try XCTUnwrap(detect(in: tree).only)

        XCTAssertEqual(item.path, cachesPath + "/UnreadableTool")
        XCTAssertTrue(item.isPartial)
    }

    /// 右键排除只收窄:被排除的条目不出现。
    func testExcludedEntryIsNotListed() {
        let tree = tree(caches: [
            dir("KeptTool", under: cachesPath, bytes: 300),
            dir("ExcludedTool", under: cachesPath, bytes: 500),
        ])

        let out = detect(in: tree, excluded: [cachesPath + "/ExcludedTool"])

        XCTAssertEqual(out.map(\.path), [cachesPath + "/KeptTool"])
    }

    /// 只管三处:家目录下其它位置(文稿、偏好设置、应用容器、临时目录)里有东西也不列。
    func testLocationsOutsideTheThreeRootsAreNeverListed() {
        let tree = dir("Users", under: "/", children: [
            dir("me", under: "/Users", children: [
                dir("Documents", under: home, children: [
                    dir("SomeTool", under: home + "/Documents", bytes: 900),
                ]),
                dir("Library", under: home, children: [
                    dir("Preferences", under: home + "/Library", children: [
                        dir("com.some.tool", under: home + "/Library/Preferences", bytes: 400),
                    ]),
                    dir("Containers", under: home + "/Library", children: [
                        dir("com.some.tool", under: home + "/Library/Containers", bytes: 600),
                    ]),
                ]),
            ]),
        ])

        XCTAssertTrue(detect(in: tree).isEmpty)
    }

    // MARK: 去重让位

    private func claimed(_ path: String) -> JunkCandidate {
        JunkCandidate(
            ruleID: "fixture.rule",
            group: .appCache,
            title: (path as NSString).lastPathComponent,
            path: path,
            tier: .safe,
            bytes: 1,
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: true,
            rationale: "夹具",
            symbolName: "folder"
        )
    }

    /// 已被名单认领的路径不重复产出:清单里只有名单那一条,档位按名单,不带「未识别」。
    func testEntryAlreadyClaimedByAllowlistYieldsToIt() {
        let tree = tree(caches: [
            dir("KnownTool", under: cachesPath, bytes: 500),
            dir("UnknownTool", under: cachesPath, bytes: 200),
        ])

        let out = detect(in: tree, claimed: [claimed(cachesPath + "/KnownTool")])

        XCTAssertEqual(out.map(\.path), [cachesPath + "/UnknownTool"])
        XCTAssertTrue(out.allSatisfy { $0.flags == [.unidentified] })
    }

    /// 让位规则与卸载残留同款:路径相等,或互为祖孙。祖先是名单认领的(规则表把整个
    /// 日志目录认作「应用日志」)、或后代被认领的,都让位。
    func testAncestorOrDescendantClaimedAlsoYields() {
        let tree = tree(
            caches: [dir("WrapTool", under: cachesPath, bytes: 100, children: [
                dir("Inner", under: cachesPath + "/WrapTool", bytes: 80),
            ])],
            logs: [dir("SomeApp", under: logsPath, bytes: 100)]
        )

        let out = detect(
            in: tree,
            claimed: [claimed(logsPath), claimed(cachesPath + "/WrapTool/Inner")]
        )

        XCTAssertTrue(out.isEmpty, "祖先被认领的日志条目、后代被认领的缓存条目都让位")
    }

    // MARK: 保护名单

    /// 保护名单按名字命中就不列。每类给一个现实里的真名;名字旁边的编号是对齐对象
    /// 踩同一个坑的事故记录,只借事实。
    func testProtectedNamesAreNeverListed() {
        let protected = [
            // 密码与密钥类(沿用孤儿检测的敏感名单)
            "com.1password.1password", "com.agilebits.onepassword4", "Bitwarden",
            // 日历缓存(#1508:日历代理常驻,清了崩到重新登录)
            "Calendar Cache",
            // 壁纸缩略图(#1118:清了系统设置里的壁纸封面变成占位图)
            "wallpaper-thumbnails",
            // 接力 / 通用剪贴板的中转缓存(#1178)
            "shared-pasteboard",
            // 编译模型缓存(守护进程在跑时清了,识别功能坏到它重启)
            "E5RT.e5bundlecache",
            // 对齐对象的两个硬跳过:Chrome 运行时的网络缓存;Rust 构建缓存在用的部分
            "Google", "mbx",
            // 端点防护 / 设备管理(本机在场的三家 + 同类别)
            "com.sentinelone.sentinel-agent", "com.northpolesec.santa", "com.volcengine.corplink",
            "CrowdStrike", "Jamf",
            // 企业组网(本机在场的一家 + 同类别)
            "io.tailscale.ipn.macsys", "GlobalProtect",
        ]
        let tree = tree(
            caches: protected.map { dir($0, under: cachesPath, bytes: 100) }
                + [dir("PlainTool", under: cachesPath, bytes: 100)]
        )

        XCTAssertEqual(detect(in: tree).map(\.path), [cachesPath + "/PlainTool"])
    }

    /// 系统所有的条目不进通用发现:带 `com.apple.` 前缀的、名为「Apple」的,以及不带
    /// 前缀的那批守护进程缓存(只认前缀会漏掉它们)。它们的守护进程常年常驻,「在运行就
    /// 跳过」对它们没有可靠信号;认得的苹果缓存走知识库逐条担保。别家的反域名条目照列。
    func testAppleOwnedEntriesAreNotListed() {
        let appleOwned = [
            "com.apple.somethingd", "Apple",
            "CloudKit", "GeoServices", "PassKit", "GameKit", "QuickLook",
            "FamilyCircle", "familycircled", "ThumbnailsCache",
        ]
        let tree = tree(
            caches: appleOwned.map { dir($0, under: cachesPath, bytes: 100) }
                + [dir("com.microsoft.something", under: cachesPath, bytes: 100)]
        )

        XCTAssertEqual(detect(in: tree).map(\.path), [cachesPath + "/com.microsoft.something"])
    }

    // MARK: 正在运行的应用(现查过滤,不在扫描时判)

    /// 正在运行的应用的条目此刻不出现,对应方式各一例:目录名就是 bundle id(不分大小写);
    /// 是 bundle id 的子组件;是应用名;是知识库给这个应用登记的别名——知识库条目
    /// 「Arc」的目录名里有运行中应用的 bundle id,于是它登记的另一个目录名「Arc」也跳过。
    /// 没在跑的照列;只差几个字符的另一个 id(没到段边界)不算它。
    func testRunningAppEntriesAreSkipped() {
        let tree = tree(caches: [
            dir("Com.Running.App", under: cachesPath, bytes: 100),
            dir("com.running.app.helper", under: cachesPath, bytes: 100),
            dir("Running App", under: cachesPath, bytes: 100),
            dir("Arc", under: cachesPath, bytes: 100),
            dir("Stopped App", under: cachesPath, bytes: 100),
            dir("com.running.applicate", under: cachesPath, bytes: 100),
        ])
        let running = [
            RunningAppIdentity(bundleID: "com.running.app", names: ["Running App"]),
            RunningAppIdentity(bundleID: "company.thebrowser.browser", names: ["The Browser"]),
        ]

        let out = GenericDiscovery.excludingRunningApps(detect(in: tree), runningApps: running)

        XCTAssertEqual(Set(out.map(\.path)), [cachesPath + "/Stopped App", cachesPath + "/com.running.applicate"])
    }

    /// 缓存目录只取了应用名的前半截也对得上(本机实案:应用「MyGo Music」,目录叫「MyGo」):
    /// 目录名是运行中应用某段标识的开头一段就算。只认到词边界——连写的「MyGoMusic」不算。
    func testLeadingWordsOfRunningAppNameAreSkipped() {
        let tree = tree(caches: [
            dir("MyGo", under: cachesPath, bytes: 100),
            dir("MyGoMusic", under: cachesPath, bytes: 100),
        ])
        let running = [RunningAppIdentity(bundleID: "com.example.mygo", names: ["MyGo Music"])]

        let out = GenericDiscovery.excludingRunningApps(detect(in: tree), runningApps: running)

        XCTAssertEqual(out.map(\.path), [cachesPath + "/MyGoMusic"])
    }

    /// 过滤只动通用发现自己的条目:规则表认领的目录,哪怕属于正在运行的应用,也照规则表
    /// 担保的档位原样通过(它在不在用由在用保护现查,不归这个过滤管)。没有运行中应用
    /// 时整份清单原样通过。
    func testRunningFilterLeavesOtherCandidatesUntouched() {
        let tree = tree(caches: [dir("com.running.app", under: cachesPath, bytes: 100)])
        let ruleTableEntry = claimed(cachesPath + "/com.running.app")
        let generic = detect(in: tree)
        let running = [RunningAppIdentity(bundleID: "com.running.app", names: [])]

        XCTAssertEqual(
            GenericDiscovery.excludingRunningApps([ruleTableEntry] + generic, runningApps: running).map(\.ruleID),
            ["fixture.rule"]
        )
        XCTAssertEqual(
            GenericDiscovery.excludingRunningApps([ruleTableEntry] + generic, runningApps: []).map(\.ruleID),
            ["fixture.rule", GenericDiscovery.ruleID]
        )
    }

    /// 运行中应用的读数:版本号没变且没过期,重复读只采一次;过期、版本号变了都重采。
    func testRunningAppsReadingReusesOneCollectionWithinFreshness() {
        var reading = RunningAppsReading(freshness: 1)
        var collections = 0
        func collect() -> [RunningAppIdentity] {
            collections += 1
            return [RunningAppIdentity(bundleID: "com.running.app", names: [])]
        }
        let start = Date(timeIntervalSince1970: now)

        _ = reading.value(at: start, revision: 0, collect: collect)
        _ = reading.value(at: start.addingTimeInterval(0.9), revision: 0, collect: collect)
        XCTAssertEqual(collections, 1, "一秒内、版本号没变:共用一份")

        _ = reading.value(at: start.addingTimeInterval(1.1), revision: 0, collect: collect)
        XCTAssertEqual(collections, 2, "过期重采")

        _ = reading.value(at: start.addingTimeInterval(1.2), revision: 1, collect: collect)
        XCTAssertEqual(collections, 3, "版本号变了(应用启动 / 退出)即刻重采,不等过期")
    }

    /// 进了确认清单的通用发现条目带着规则 id 与「未识别」:清理历史按它查得出是哪一轮、哪个来源。
    func testPlannedEntryCarriesRuleIDAndFlag() throws {
        let item = try XCTUnwrap(detect(in: tree(caches: [
            dir("SomeTool", under: cachesPath, bytes: 700, ownModified: now),
        ])).only)
        var selection = JunkSelection()
        selection.set(item, selected: true)

        let plan = CleanPlan.make(selection: selection, candidates: [item], excludedPathPrefixes: [])

        XCTAssertEqual(plan.items.map(\.ruleID), [GenericDiscovery.ruleID])
        XCTAssertEqual(plan.items.map(\.flags), [[.unidentified]])
    }

    // MARK: 日志目录 / 应用数据目录

    /// 日志目录一级条目照列(现实里规则表把整个日志目录认作「应用日志」,那些条目因让位
    /// 不会重复出现;没被认领时由通用发现兜住)。
    func testUnlistedLogDirectoryIsListed() {
        let tree = tree(logs: [dir("SomeApp", under: logsPath, bytes: 300)])

        let out = detect(in: tree)

        XCTAssertEqual(out.map(\.path), [logsPath + "/SomeApp"])
        XCTAssertEqual(out.first?.flags, [.unidentified])
    }

    /// 应用数据目录里只收名字明确的缓存子目录,一个子目录一条;标题写成「应用 · 子目录」
    /// (光写「Cache」分不清是谁的)。登录态、本地库、数据库、工作区状态、备份一律不碰。
    func testAppSupportListsOnlyCacheNamedSubdirectories() {
        let app = appSupportPath + "/SomeEditor"
        let tree = tree(appSupport: [
            dir("SomeEditor", under: appSupportPath, children: [
                dir("Cache", under: app, bytes: 400),
                dir("Code Cache", under: app, bytes: 300),
                dir("GraphiteDawnCache", under: app, bytes: 50),
                dir("IndexedDB", under: app, bytes: 900),
                dir("Local Storage", under: app, bytes: 200),
                dir("databases", under: app, bytes: 700),
                dir("workspaceStorage", under: app, bytes: 100),
                dir("backups", under: app, bytes: 100),
            ]),
        ])

        let out = detect(in: tree)

        XCTAssertEqual(out.map(\.path), [app + "/Cache", app + "/Code Cache", app + "/GraphiteDawnCache"])
        XCTAssertEqual(
            out.map(\.title),
            ["SomeEditor · Cache", "SomeEditor · Code Cache", "SomeEditor · GraphiteDawnCache"]
        )
        XCTAssertEqual(out.map(\.bytes), [400, 300, 50])
    }

    /// 浏览器用户资料目录靠结构进不来:应用目录本身就是资料根(登录态与 Cookie 在这),
    /// 缓存在它下面第二层——通用发现只看应用目录的直接子目录,里面叫 Cache 的也轮不到;
    /// 「User Data」「Profiles」不是缓存名,同样不收。资料根的直接子目录里真叫缓存的照列。
    func testBrowserProfileDirectoriesAreOutOfReach() {
        let profile = appSupportPath + "/SomeBrowser"
        let tree = tree(appSupport: [
            dir("SomeBrowser", under: appSupportPath, children: [
                dir("Default", under: profile, children: [
                    dir("Cache", under: profile + "/Default", bytes: 800),
                    dir("Login Data", under: profile + "/Default", bytes: 10),
                ]),
                dir("User Data", under: profile, children: [
                    dir("Default", under: profile + "/User Data", children: [
                        dir("Cache", under: profile + "/User Data/Default", bytes: 800),
                    ]),
                ]),
                dir("Profiles", under: profile, children: [
                    dir("Cache", under: profile + "/Profiles", bytes: 800),
                ]),
                dir("GPUCache", under: profile, bytes: 20),
            ]),
        ])

        XCTAssertEqual(detect(in: tree).map(\.path), [profile + "/GPUCache"])
    }

    /// 应用数据目录下三道闸照常生效:受保护的应用目录整个跳过(含它下面的缓存子目录——
    /// 邮件数据、端点防护类软件、系统所有);正在运行的应用的目录跳过,按 bundle id 或按
    /// 应用名都对得上;没在跑的照列。
    func testAppSupportHonorsProtectionAndRunningApps() {
        func appDir(_ name: String, children: [SpaceNode] = []) -> SpaceNode {
            // 每个应用目录下都放一个名字明确的缓存子目录:受保护 / 在运行的,它不该被列。
            dir(name, under: appSupportPath, children: [
                dir("Cache", under: appSupportPath + "/" + name, bytes: 100),
            ] + children)
        }
        let tree = tree(appSupport: [
            appDir("Mail"),
            appDir("MobileSync"),
            appDir("com.northpolesec.santa"),
            appDir("com.apple.something"),
            appDir("com.running.app"),
            appDir("Running App"),
            dir("Stopped Editor", under: appSupportPath, children: [
                dir("GPUCache", under: appSupportPath + "/Stopped Editor", bytes: 100),
                dir("IndexedDB", under: appSupportPath + "/Stopped Editor", bytes: 900),
            ]),
        ])
        let running = [RunningAppIdentity(bundleID: "com.running.app", names: ["Running App"])]

        let out = GenericDiscovery.excludingRunningApps(detect(in: tree), runningApps: running)

        XCTAssertEqual(out.map(\.path), [appSupportPath + "/Stopped Editor/GPUCache"])
    }
}

private extension [JunkCandidate] {
    var only: JunkCandidate? {
        count == 1 ? first : nil
    }
}
