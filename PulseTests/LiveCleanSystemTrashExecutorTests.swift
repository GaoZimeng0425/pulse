@testable import Pulse
import PulseCore
import XCTest

/// 系统级条目移进废纸篓的真实现(p7-cleaner/05;ADR-0012)。
/// 真实提权路径不进自动化测试:这里钉的是清单文件的写法、命令行的拼法、结果行与失败的
/// 解析,外加「不带管理员授权」跑一遍随包分发的真脚本(不弹密码框、不提权)——成功、
/// 脚本级失败、硬链接、改不了归属四条路都走真通道,全在临时目录。
@MainActor
final class LiveCleanSystemTrashExecutorTests: XCTestCase {
    private let day: TimeInterval = 86400
    private var temporaryDirectory: String!

    override func setUp() async throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-system-trash-live-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(atPath: temporaryDirectory)
        }
    }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// 临时目录下搭一套夹具:登记目录(一个放满 10 天的文件 + 一个一小时前的)+ 暂存目录的
    /// 上一级 + 废纸篓根。
    private func makeFixture() throws
        -> (reports: String, old: String, young: String, trashRoot: String, stagingParent: String) {
        let reports = temporaryDirectory + "/reports"
        try makeDirectory(reports)
        let old = reports + "/old.diag"
        let young = reports + "/young.diag"
        for path in [old, young] {
            try Data("report".utf8).write(to: URL(fileURLWithPath: path))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * day)], ofItemAtPath: old
        )
        let trashRoot = temporaryDirectory + "/home/.Trash"
        try makeDirectory(trashRoot)
        let stagingParent = temporaryDirectory + "/staging"
        try makeDirectory(stagingParent)
        return (reports, old, young, trashRoot, stagingParent)
    }

    /// 脚本的自测开关(只在非 root 时生效):登记目录与暂存目录指到夹具,认调用者属主的文件;
    /// 替身命令目录里若有同名的 stat / mv / chown 就用它。
    private func fixtureEnvironment(
        reports: String, stagingParent: String, commandsDirectory: String? = nil
    ) -> [String: String] {
        var environment = [
            "PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR": reports,
            "PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED": "1",
            "PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT": stagingParent,
        ]
        if let commandsDirectory {
            environment["PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR"] = commandsDirectory
        }
        return environment
    }

    /// 生成一个替身命令(放在只有它的目录里),返回目录。
    private func makeStandIn(_ name: String, body: String) throws -> String {
        let directory = temporaryDirectory + "/commands-" + UUID().uuidString
        try makeDirectory(directory)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: URL(fileURLWithPath: directory + "/" + name))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory + "/" + name)
        return directory
    }

    private func run(
        paths: [String],
        environment: [String: String],
        fixture: (reports: String, old: String, young: String, trashRoot: String, stagingParent: String),
        scriptPath: String? = LiveCleanSystemTrashExecutor.bundledScriptPath
    ) async -> SystemTrashOutcome {
        // 收走残留暂存目录时只看夹具里的,不碰真的 /var/tmp。
        await LiveCleanSystemTrashExecutor.run(
            SystemTrashRequest(paths: paths, requesterUID: UInt32(getuid())),
            scriptPath: scriptPath,
            privileged: false,
            environment: environment,
            trashRoot: fixture.trashRoot,
            temporaryDirectory: temporaryDirectory,
            stagingParent: fixture.stagingParent
        )
    }

    private func contentsOfTemporaryDirectory() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)
    }

    // MARK: 结果与失败的解析

    private func outcome(status: Int32, stdout: String = "", stderr: String) -> LiveCleanSystemTrashExecutor
        .ScriptTermination {
        LiveCleanSystemTrashExecutor.outcome(
            for: .init(status: status, stdout: stdout, stderr: stderr)
        )
    }

    /// 用户在密码框点了取消:系统脚本的错误号 -128,通道原样带回。
    func testCancelledAuthorizationIsRecognized() {
        XCTAssertEqual(
            outcome(status: 1, stderr: "0:103: execution error: User canceled. (-128)\n"),
            .authorizationCancelled
        )
    }

    /// 脚本级失败:通道会把脚本的错误输出包一层(前面是位置与「execution error:」,后面是
    /// 退出码),要取出脚本自己说的那一句。格式照不带授权的真通道实测抄。
    func testScriptFailureCarriesItsReason() {
        XCTAssertEqual(
            outcome(status: 1, stderr: "0:212: execution error: channel-unavailable: 登记的目录是符号链接 (2)\n"),
            .channelUnavailable(reason: "登记的目录是符号链接")
        )
    }

    /// 别的失败(系统拒绝运行这条授权通道等):取系统说的第一句,去掉包的那层;一句没有就报退出码。
    func testOtherFailuresAreReportedNotSwallowed() {
        XCTAssertEqual(
            outcome(status: 1, stderr: "error: 不允许请求管理员授权。 (-10004)\n"),
            .channelUnavailable(reason: "error: 不允许请求管理员授权。")
        )
        XCTAssertEqual(
            outcome(status: 1, stderr: "0:7: execution error: Operation not permitted (1)\n"),
            .channelUnavailable(reason: "Operation not permitted")
        )
        XCTAssertEqual(
            outcome(status: 3, stderr: ""),
            .channelUnavailable(reason: "系统脚本退出码 3")
        )
    }

    /// 结果行制表符分隔,换行符是回车也认(系统脚本通道回传的就是回车):SKIPPED 的原因翻成人话,
    /// 路径里的空格与中文原样往返,坏行忽略。
    func testResultLinesAreParsed() {
        let stdout = "SKIPPED\t/Library/Logs/DiagnosticReports/新报告.ips\ttoo-young\r"
            + "SKIPPED\t/Library/Logs/DiagnosticReports/b.diag\tsome-new-code\r"
            + "garbage\r"
            + "STAGING\t/var/tmp/pulse-system-trash.Ab12Cd\r"
            + "MOVED\t/Library/Logs/DiagnosticReports/a.diag\t/var/tmp/pulse-system-trash.Ab12Cd/a.diag\r"

        let handoff = LiveCleanSystemTrashExecutor.parse(stdout)

        XCTAssertEqual(handoff.staging, "/var/tmp/pulse-system-trash.Ab12Cd")
        XCTAssertEqual(
            handoff.receipt.recycled,
            ["/Library/Logs/DiagnosticReports/a.diag": "/var/tmp/pulse-system-trash.Ab12Cd/a.diag"]
        )
        XCTAssertEqual(handoff.receipt.failures, [
            "/Library/Logs/DiagnosticReports/新报告.ips": "还没满 7 天(移动前又核了一次)",
            "/Library/Logs/DiagnosticReports/b.diag": "复核未通过(some-new-code)",
        ])
    }

    // MARK: 清单文件与命令行

    /// 清单文件一行一个路径,从建出来那一刻起就只有本人可读写(0600);已有同名文件时不覆盖。
    func testManifestIsOnePathPerLineAndOwnerOnly() throws {
        let path = temporaryDirectory + "/manifest"
        try LiveCleanSystemTrashExecutor.writeManifest(to: path, paths: ["/a/x.diag", "/b/y.ips"])

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "清单文件仅本人可读写")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "/a/x.diag\n/b/y.ips\n")

        XCTAssertThrowsError(try LiveCleanSystemTrashExecutor.writeManifest(to: path, paths: ["/c"]))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "/a/x.diag\n/b/y.ips\n", "不覆盖已有文件")
    }

    /// 命令行里路径全部严格引用:单引号、双引号、反斜杠、空格、中文都不会把命令拼坏;
    /// 带管理员授权时只在系统脚本那句后面多那一个短语。
    func testPathsAreQuotedForShellAndAppleScript() {
        XCTAssertEqual(
            LiveCleanSystemTrashExecutor.shellQuoted("/Applications/It's Here/x.sh"),
            "'/Applications/It'\\''s Here/x.sh'"
        )
        XCTAssertEqual(
            LiveCleanSystemTrashExecutor.appleScriptString("a \"b\" \\ c"),
            "\"a \\\"b\\\" \\\\ c\""
        )
        XCTAssertEqual(
            LiveCleanSystemTrashExecutor.appleScript("'/bin/sh' '/tmp/m' 501", privileged: true),
            "do shell script \"'/bin/sh' '/tmp/m' 501\" with administrator privileges"
        )
        XCTAssertEqual(
            LiveCleanSystemTrashExecutor.appleScript("'/bin/sh' '/tmp/m' 501", privileged: false),
            "do shell script \"'/bin/sh' '/tmp/m' 501\""
        )
    }

    // MARK: 整条通道(不带管理员授权跑真脚本)

    /// 真脚本 + 真的 osascript:放满 7 天的经暂存目录进了废纸篓子目录,太新的带着原因留在
    /// 原处;清单文件与暂存目录用完都不剩。
    func testRunsTheBundledScriptWithoutElevation() async throws {
        let fixture = try makeFixture()

        let termination = await run(
            paths: [fixture.old, fixture.young],
            environment: fixtureEnvironment(reports: fixture.reports, stagingParent: fixture.stagingParent),
            fixture: fixture
        )

        guard case let .completed(receipt) = termination else {
            return XCTFail("应走完,实际 \(termination)")
        }
        XCTAssertEqual(receipt.failures, [fixture.young: "还没满 7 天(移动前又核了一次)"])
        let destination = try XCTUnwrap(receipt.recycled[fixture.old])
        XCTAssertTrue(destination.hasPrefix(fixture.trashRoot + "/Pulse 系统级/"), "去向是废纸篓的专属子目录:\(destination)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.old), "放满 7 天的离开原处")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.young), "太新的原地不动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination), "进了废纸篓子目录")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingParent), [], "暂存目录用完即收")
        XCTAssertFalse(try contentsOfTemporaryDirectory().contains { $0.hasSuffix(".manifest") }, "清单文件用完即删")
    }

    /// 一个都没移走:废纸篓里不留空文件夹,暂存目录也不剩。
    func testNothingMovedLeavesNothingBehind() async throws {
        let fixture = try makeFixture()

        let termination = await run(
            paths: [fixture.young],
            environment: fixtureEnvironment(reports: fixture.reports, stagingParent: fixture.stagingParent),
            fixture: fixture
        )

        guard case let .completed(receipt) = termination else {
            return XCTFail("应走完,实际 \(termination)")
        }
        XCTAssertEqual(receipt.recycled, [:])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.trashRoot + "/Pulse 系统级"),
            "没移走任何东西时,废纸篓里什么都没多"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingParent), [])
    }

    /// 脚本级失败走真通道:登记目录是符号链接 → 脚本整批没动;通道把原因原样带回,不带包的那层。
    func testScriptFailureThroughTheRealChannel() async throws {
        let fixture = try makeFixture()
        let reportsLink = temporaryDirectory + "/reports-link"
        try FileManager.default.createSymbolicLink(atPath: reportsLink, withDestinationPath: fixture.reports)

        let termination = await run(
            paths: [fixture.old],
            environment: fixtureEnvironment(reports: reportsLink, stagingParent: fixture.stagingParent),
            fixture: fixture
        )

        XCTAssertEqual(termination, .channelUnavailable(reason: "登记的目录是符号链接"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.old), "整批没动")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingParent), [])
    }

    /// 和别的路径是同一个文件的硬链接:不碰(改归属会连那份一起改),两处都留在原地。
    func testHardLinkedReportIsLeftAlone() async throws {
        let fixture = try makeFixture()
        let alias = fixture.reports + "/old-link.diag"
        try FileManager.default.linkItem(atPath: fixture.old, toPath: alias)

        let termination = await run(
            paths: [fixture.old],
            environment: fixtureEnvironment(reports: fixture.reports, stagingParent: fixture.stagingParent),
            fixture: fixture
        )

        guard case let .completed(receipt) = termination else {
            return XCTFail("应走完,实际 \(termination)")
        }
        XCTAssertEqual(receipt.failures, [fixture.old: "和别的路径是同一个文件的硬链接,没动"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingParent), [])
    }

    /// 改不了归属:文件放回原处、内容与归属原样,按跳过报——不留「离开了原处、归属却不对」的状态。
    func testOwnershipFailurePutsTheFileBack() async throws {
        let fixture = try makeFixture()
        let commands = try makeStandIn("chown", body: "exit 1\n")
        let before = try ownership(of: fixture.old)

        let termination = await run(
            paths: [fixture.old],
            environment: fixtureEnvironment(
                reports: fixture.reports,
                stagingParent: fixture.stagingParent,
                commandsDirectory: commands
            ),
            fixture: fixture
        )

        guard case let .completed(receipt) = termination else {
            return XCTFail("应走完,实际 \(termination)")
        }
        XCTAssertEqual(receipt.failures, [fixture.old: "归属改不成当前用户,已放回原处"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.old), "放回了原处")
        XCTAssertEqual(try String(contentsOfFile: fixture.old, encoding: .utf8), "report")
        XCTAssertEqual(try ownership(of: fixture.old), before, "属主与组原样")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingParent), [])
    }

    /// 一个文件的 [属主 uid, 组 gid]。
    private func ownership(of path: String) throws -> [UInt32] {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return [
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0,
            (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0,
        ]
    }

    // MARK: 第二段:进废纸篓(以调用者身份)

    private func makeStagingDirectory(named name: String, files: [String: String]) throws -> String {
        let staging = temporaryDirectory + "/" + name
        try makeDirectory(staging)
        for (file, content) in files {
            try Data(content.utf8).write(to: URL(fileURLWithPath: staging + "/" + file))
        }
        return staging
    }

    /// 目标子目录里已有同名文件:加序号,绝不覆盖;都挪走了才收掉空的暂存目录。
    func testRelocateAddsSequenceNumbersAndNeverOverwrites() throws {
        let staging = try makeStagingDirectory(named: "pulse-system-trash.Stage1", files: ["old.diag": "new"])
        let target = temporaryDirectory + "/Trash/Pulse 系统级/2023-11-14 22.13.20"
        try makeDirectory(target)
        let occupied = target + "/old.diag"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: occupied))

        let outcome = LiveCleanSystemTrashExecutor.relocate(
            .init(staging: staging, receipt: TrashRecycleOutcome(recycled: ["/r/old.diag": staging + "/old.diag"])),
            target: target
        )

        let destination = try XCTUnwrap(outcome.recycled["/r/old.diag"])
        XCTAssertEqual(destination, occupied + ".1")
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOfFile: occupied, encoding: .utf8), "keep", "原有的没被覆盖")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging), "都挪走了,空的暂存目录收掉")
    }

    /// 挪进废纸篓失败(脚本说已移走,暂存目录里那一份却已经不在了):不谎报已进废纸篓,原因里
    /// 写明文件本该在哪;有东西没挪成时暂存目录不收。
    func testRelocateReportsWhereTheFileIsWhenItCannotReachTheTrash() throws {
        let staging = try makeStagingDirectory(named: "pulse-system-trash.Stage2", files: [:])
        let target = temporaryDirectory + "/Trash/Pulse 系统级/2023-11-14 22.13.20"
        try makeDirectory(target)
        let vanished = staging + "/vanished.diag"

        let outcome = LiveCleanSystemTrashExecutor.relocate(
            .init(staging: staging, receipt: TrashRecycleOutcome(recycled: ["/r/vanished.diag": vanished])),
            target: target
        )

        XCTAssertEqual(outcome.recycled, [:])
        let reason = try XCTUnwrap(outcome.failures["/r/vanished.diag"])
        XCTAssertTrue(reason.contains(vanished), "原因里要写明文件本该在哪:\(reason)")
        XCTAssertTrue(reason.contains("没能放进废纸篓"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging), "有东西没挪成,暂存目录不收")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "一条都没进废纸篓,空的目标目录收掉")
    }

    /// 脚本报了「已移走」却没交出暂存目录:不认,按失败报。
    func testMovedWithoutAHandedOffStagingDirectoryIsNotTrusted() {
        let outcome = LiveCleanSystemTrashExecutor.relocate(
            .init(staging: nil, receipt: TrashRecycleOutcome(recycled: ["/r/old.diag": "/nowhere/old.diag"])),
            target: temporaryDirectory + "/Trash/Pulse 系统级/2023-11-14 22.13.20"
        )

        XCTAssertEqual(outcome.recycled, [:])
        XCTAssertEqual(outcome.failures, ["/r/old.diag": "复核脚本说已移走,却没有交出暂存目录"])
    }

    /// 上次没来得及进废纸篓的暂存目录(交接过、归当前用户的):这次运行前收进废纸篓,目录名当
    /// 批次名;别的名字不碰;这一轮自己一条都没进废纸篓时不留空目录。
    func testLeftoverStagingIsCollectedBeforeTheNextRun() async throws {
        let fixture = try makeFixture()
        let leftover = fixture.stagingParent + "/pulse-system-trash.Left0ver"
        try makeDirectory(leftover)
        try Data("a".utf8).write(to: URL(fileURLWithPath: leftover + "/a.diag"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: leftover + "/b.diag"))
        let unrelated = fixture.stagingParent + "/someone-elses-directory"
        try makeDirectory(unrelated)
        try Data("x".utf8).write(to: URL(fileURLWithPath: unrelated + "/x"))

        let termination = await run(
            paths: [fixture.young],
            environment: fixtureEnvironment(reports: fixture.reports, stagingParent: fixture.stagingParent),
            fixture: fixture
        )

        XCTAssertEqual(
            termination,
            .completed(TrashRecycleOutcome(failures: [fixture.young: "还没满 7 天(移动前又核了一次)"]))
        )
        let subdirectory = fixture.trashRoot + "/" + LiveCleanSystemTrashExecutor.trashSubdirectory
        let collected = subdirectory + "/pulse-system-trash.Left0ver"
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: collected).sorted(),
            ["a.diag", "b.diag"],
            "上次的文件补挪进了废纸篓"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover), "收空的暂存目录收掉")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unrelated), ["x"], "别的名字不碰")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: subdirectory),
            ["pulse-system-trash.Left0ver"],
            "这一轮自己一条都没进废纸篓:这一批的专属子目录没留下"
        )
    }

    /// 废纸篓进不去:在要授权**之前**就按通道不可用报,不让用户白输一次密码;脚本根本不跑,
    /// 文件原处不动。
    func testUnreachableTrashIsReportedBeforeAskingForAuthorization() async throws {
        let fixture = try makeFixture()
        let notADirectory = temporaryDirectory + "/Trash-is-a-file"
        try Data("x".utf8).write(to: URL(fileURLWithPath: notADirectory))

        let termination = await LiveCleanSystemTrashExecutor.run(
            SystemTrashRequest(paths: [fixture.old], requesterUID: UInt32(getuid())),
            scriptPath: LiveCleanSystemTrashExecutor.bundledScriptPath,
            privileged: false,
            environment: fixtureEnvironment(reports: fixture.reports, stagingParent: fixture.stagingParent),
            trashRoot: notADirectory,
            temporaryDirectory: temporaryDirectory,
            stagingParent: fixture.stagingParent
        )

        guard case let .channelUnavailable(reason) = termination else {
            return XCTFail("应按通道不可用报,实际 \(termination)")
        }
        XCTAssertTrue(reason.contains("废纸篓"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.old), "脚本根本没跑,文件原处不动")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingParent), [])
    }

    // MARK: 不该发的请求

    /// 复核脚本不在应用包里:按通道不可用报,不静默。
    func testMissingScriptIsReportedUnavailable() async {
        let termination = await LiveCleanSystemTrashExecutor.run(
            SystemTrashRequest(paths: ["/Library/Logs/DiagnosticReports/a.diag"], requesterUID: 501),
            scriptPath: nil, privileged: true, environment: [:],
            trashRoot: temporaryDirectory + "/.Trash", temporaryDirectory: temporaryDirectory
        )

        guard case let .channelUnavailable(reason) = termination else {
            return XCTFail("应按通道不可用报,实际 \(termination)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    /// 没法一行一个写进清单的路径(相对路径、含换行或制表符)在写清单前就拒收,不去跑脚本。
    func testUnencodablePathsAreRefusedBeforeReachingTheScript() async {
        for path in ["relative/a.diag", "/a/x\ny.diag", "/a/x\ty.diag"] {
            let termination = await LiveCleanSystemTrashExecutor.run(
                SystemTrashRequest(paths: [path], requesterUID: 501),
                scriptPath: "/dev/null", privileged: false,
                environment: [:], trashRoot: temporaryDirectory + "/.Trash", temporaryDirectory: temporaryDirectory
            )

            guard case let .channelUnavailable(reason) = termination else {
                return XCTFail("[\(path.debugDescription)] 应拒收,实际 \(termination)")
            }
            XCTAssertTrue(reason.contains("清单"), "[\(path.debugDescription)] 应在写清单前拒收,实际原因:\(reason)")
        }
    }
}
