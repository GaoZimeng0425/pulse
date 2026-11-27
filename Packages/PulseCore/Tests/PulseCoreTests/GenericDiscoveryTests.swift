@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 通用发现 + 保护名单(p7-cleaner/02;ADR-0013;GLOSSARY「通用发现」「保护名单」)。
/// 接缝 = 扫描树 → 候选清单:手搭家目录下的三处(缓存 / 日志 / 应用数据),已认领路径、
/// 排除目录、运行中应用作为输入注入,零真盘;废纸篓执行用 spy,绝不真删。
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
        // 行悬停要说清两件事:清了会怎样、为什么它不会被自动勾。
        XCTAssertTrue(item.rationale.contains("先检查"), "悬停说明要交代它为什么不进自动勾选:\(item.rationale)")
        XCTAssertTrue(item.rationale.contains("重新生成"), "悬停说明要交代清了会怎样:\(item.rationale)")
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

    /// 只管三处:家目录下其它位置(文稿、偏好设置、应用容器)里有东西也不列;系统临时目录
    /// (`/private/tmp` 下放着进行中的工作)与用户临时目录(`/private/var/folders/…/T`)
    /// 哪怕和扫描树一起传进来也不列。
    func testLocationsOutsideTheThreeRootsAreNeverListed() {
        let homeTree = dir("Users", under: "/", children: [
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
        let folders = "/private/var/folders/ab"
        let systemTree = dir("private", under: "/", children: [
            dir("tmp", under: "/private", children: [
                dir("claude-501", under: "/private/tmp", bytes: 500),
            ]),
            dir("var", under: "/private", children: [
                dir("folders", under: "/private/var", children: [
                    dir("ab", under: "/private/var/folders", children: [
                        dir("T", under: folders, children: [
                            dir("SomeTool", under: folders + "/T", bytes: 300),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let out = GenericDiscovery.detect(
            in: [homeTree, systemTree],
            home: home,
            claimedBy: [],
            excludedPathPrefixes: []
        )

        XCTAssertTrue(out.isEmpty)
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
    /// 的 issue,只借事实。
    func testProtectedNamesAreNeverListed() {
        let protected = [
            // 密码与密钥类(沿用孤儿检测的敏感名单)
            "com.1password.1password", "com.agilebits.onepassword4", "Bitwarden",
            // 日历缓存(#1508:缺陷报告,清理后日历启动即崩)
            "Calendar Cache",
            // 壁纸缩略图(#1118:用户报告清理后壁纸封面不见)
            "wallpaper-thumbnails",
            // 接力 / 通用剪贴板的中转缓存:同步到一半的条目不能断
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

    /// 厂商名里短的那些不许撞上长得像的词:ESET 只认反域名里的那一段(`com.eset.*`)与
    /// 词首(`ESET Endpoint Security`);preset、reset 不算它,照列。
    func testShortVendorNameDoesNotMatchLookalikeWords() {
        let tree = tree(caches: [
            dir("com.eset.endpoint", under: cachesPath, bytes: 100),
            dir("ESET Endpoint Security", under: cachesPath, bytes: 100),
            dir("PresetCache", under: cachesPath, bytes: 100),
            dir("com.example.reset", under: cachesPath, bytes: 100),
        ])

        XCTAssertEqual(
            detect(in: tree).map(\.path),
            [cachesPath + "/PresetCache", cachesPath + "/com.example.reset"]
        )
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

    // MARK: 正在运行的应用(读清单时现查,不在扫描时判)

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

    /// 缓存目录只取了应用名的前半截也对得上(应用叫「MyGo Music」,缓存目录起名叫「MyGo」):
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

    /// 运行中应用的读数:版本号没变且没过期,重复读只采一次;过期、版本号变了都重采;
    /// 时钟往回拨(离采集的时间差变成负的)也重采——不知道它要多久才追得上。
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

        _ = reading.value(at: start.addingTimeInterval(0.5), revision: 1, collect: collect)
        XCTAssertEqual(collections, 4, "时钟回拨:时间差为负,不算新鲜")
    }

    /// 清过的通用发现条目在清理历史里查得出是哪个来源、带「未识别」:规则 id 与条目标志
    /// 从候选一路带进计划、战报、落库读回。
    func testCleanedEntryIsTraceableInHistory() async throws {
        let path = cachesPath + "/SomeTool"
        let item = try XCTUnwrap(detect(in: tree(caches: [
            // 与假废纸篓的删前复核快照同一个时刻,条目才放行。
            dir("SomeTool", under: cachesPath, bytes: 700, ownModified: CleanFixture.directoryModified),
        ])).only)
        var selection = JunkSelection()
        selection.set(item, selected: true)
        let plan = CleanPlan.make(selection: selection, candidates: [item], excludedPathPrefixes: [])
        XCTAssertEqual(plan.items.map(\.flags), [[.unidentified]])

        let termination = await CleanRunner.run(
            plan,
            using: FakeCleanTrashExecutor(
                nextRecycleOutcome: TrashRecycleOutcome(recycled: [path: "/Users/me/.Trash/SomeTool"])
            ),
            systemTrash: nil,
            requesterUID: 501
        )
        guard case let .completed(report) = termination else {
            return XCTFail("没有系统级条目的计划不该停下来:\(termination)")
        }
        let store = try CleanHistoryStore(database: HistoryDatabase.openInMemory())
        let runID = try await store.record(report)

        XCTAssertTrue(report.failed.isEmpty, "删前复核放行,战报里是成功项")
        let items = try await store.items(runID: XCTUnwrap(runID))
        XCTAssertEqual(items.map(\.ruleID), [GenericDiscovery.ruleID])
        XCTAssertEqual(items.map(\.flags), [[.unidentified]])
        XCTAssertEqual(items.map(\.tier), [.checkFirst])
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

    /// 应用数据目录下右键排除与零字节两道闸照常生效:排除的缓存子目录不列;零字节且不是
    /// 部分扫描的不列,部分扫描的照列。
    func testAppSupportHonorsExclusionAndZeroByteGates() {
        let app = appSupportPath + "/SomeEditor"
        let tree = tree(appSupport: [
            dir("SomeEditor", under: appSupportPath, children: [
                dir("Cache", under: app, bytes: 400),
                dir("Code Cache", under: app, bytes: 300),
                dir("GPUCache", under: app, bytes: 0),
                dir("DawnCache", under: app, bytes: 0, partial: true),
            ]),
        ])

        let out = detect(in: tree, excluded: [app + "/Code Cache"])

        XCTAssertEqual(out.map(\.path), [app + "/Cache", app + "/DawnCache"])
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

    /// 应用数据目录下保护名单照常生效:受保护的应用目录整个跳过,含它下面的缓存子目录
    /// (邮件数据、设备备份、端点防护类软件、系统所有)。「所属应用在运行」的目录也跳过,
    /// 按 bundle id、按应用名都对得上;没在跑的照列。
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
