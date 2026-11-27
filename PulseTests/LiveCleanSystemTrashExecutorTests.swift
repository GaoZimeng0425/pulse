@testable import Pulse
import PulseCore
import XCTest

/// 系统级条目移进废纸篓的真实现(p7-cleaner/05;ADR-0012)。
/// 真实提权路径不进自动化测试:这里钉的是清单文件的写法、命令行的拼法、结果行与失败的
/// 解析,外加「不带管理员授权」跑一遍随包分发的真脚本——不弹密码框、不提权,全在临时目录。
@MainActor
final class LiveCleanSystemTrashExecutorTests: XCTestCase {
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

    /// 临时目录下搭一套夹具:登记目录(一个放满 10 天的文件 + 一个刚写的)+ 废纸篓根。
    private func makeFixture() throws -> (reports: String, old: String, young: String, trashRoot: String) {
        let reports = temporaryDirectory + "/reports"
        try makeDirectory(reports)
        let old = reports + "/old.diag"
        let young = reports + "/young.diag"
        for path in [old, young] {
            try Data("report".utf8).write(to: URL(fileURLWithPath: path))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 86400)], ofItemAtPath: old
        )
        let trashRoot = temporaryDirectory + "/home/.Trash"
        try makeDirectory(trashRoot)
        return (reports, old, young, trashRoot)
    }

    private func fixtureEnvironment(reports: String, trashRoot: String) -> [String: String] {
        [
            "PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR": reports,
            "PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT": trashRoot,
            "PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED": "1",
        ]
    }

    // MARK: 结果与失败的解析

    private func outcome(status: Int32, stdout: String = "", stderr: String) -> SystemTrashOutcome {
        LiveCleanSystemTrashExecutor.outcome(
            for: .init(status: status, stdout: stdout, stderr: stderr)
        )
    }

    /// 用户在密码框点了取消:系统脚本的错误号是 -128。
    func testCancelledAuthorizationIsRecognized() {
        XCTAssertEqual(
            outcome(status: 1, stderr: "execution error: User canceled. (-128)\n"),
            .authorizationCancelled
        )
    }

    /// 脚本级失败:脚本自己说的原因原样带出。
    func testScriptFailureCarriesItsReason() {
        XCTAssertEqual(
            outcome(status: 2, stderr: "channel-unavailable: 登记的目录是符号链接\n"),
            .channelUnavailable(reason: "登记的目录是符号链接")
        )
    }

    /// 别的失败(系统拒绝运行这条授权通道等):留下系统说的第一行;一句没有就报退出码。
    func testOtherFailuresAreReportedNotSwallowed() {
        XCTAssertEqual(
            outcome(status: 1, stderr: "execution error: 不允许请求管理员授权。 (-10004)\n"),
            .channelUnavailable(reason: "execution error: 不允许请求管理员授权。 (-10004)")
        )
        XCTAssertEqual(
            outcome(status: 3, stderr: ""),
            .channelUnavailable(reason: "系统脚本退出码 3")
        )
    }

    /// 结果行三段、制表符分隔:MOVED 原→新,SKIPPED 原→原因(代码翻成人话);坏行忽略;
    /// 路径里的空格与中文原样往返;换行符是回车也认(系统脚本通道回传的就是回车)。
    func testResultLinesAreParsed() {
        let stdout = "MOVED\t/Library/Logs/DiagnosticReports/a.diag\t/Users/t/.Trash/Pulse 系统级/2026-11-27 22.03/a.diag\r"
            + "SKIPPED\t/Library/Logs/DiagnosticReports/新报告.ips\ttoo-young\r"
            + "SKIPPED\t/Library/Logs/DiagnosticReports/b.diag\tsome-new-code\n"
            + "garbage\r"

        let receipt = LiveCleanSystemTrashExecutor.parse(stdout)

        XCTAssertEqual(
            receipt.recycled,
            ["/Library/Logs/DiagnosticReports/a.diag": "/Users/t/.Trash/Pulse 系统级/2026-11-27 22.03/a.diag"]
        )
        XCTAssertEqual(receipt.failures, [
            "/Library/Logs/DiagnosticReports/新报告.ips": "还没满 7 天(移动前又核了一次)",
            "/Library/Logs/DiagnosticReports/b.diag": "复核未通过(some-new-code)",
        ])
    }

    // MARK: 清单文件与命令行

    /// 清单文件一行一个路径,仅本人可读写(0600)。
    func testManifestIsOnePathPerLineAndOwnerOnly() throws {
        let manifest = try LiveCleanSystemTrashExecutor.writeManifest(
            for: ["/a/x.diag", "/b/y.ips"], in: temporaryDirectory
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: manifest)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "清单文件仅本人可读写")
        let content = try String(contentsOfFile: manifest, encoding: .utf8)
        XCTAssertEqual(content, "/a/x.diag\n/b/y.ips\n")
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
            LiveCleanSystemTrashExecutor.appleScript(
                "'/bin/sh' '/tmp/m' 501 '/Users/t/.Trash/Pulse 系统级/x'",
                privileged: true
            ),
            "do shell script \"'/bin/sh' '/tmp/m' 501 '/Users/t/.Trash/Pulse 系统级/x'\" with administrator privileges"
        )
        XCTAssertEqual(
            LiveCleanSystemTrashExecutor.appleScript("'/bin/sh' '/tmp/m' 501 '/t'", privileged: false),
            "do shell script \"'/bin/sh' '/tmp/m' 501 '/t'\""
        )
    }

    // MARK: 整条通道(不带管理员授权跑真脚本)

    /// 随包分发的真脚本 + 真的 osascript,只是不带管理员授权:放满 7 天的被移进废纸篓子目录,
    /// 太新的带着原因留在原处;清单文件用完即删。
    func testRunsTheBundledScriptWithoutElevation() async throws {
        let scriptPath = try XCTUnwrap(LiveCleanSystemTrashExecutor.bundledScriptPath, "复核脚本应随应用包分发")
        let fixture = try makeFixture()

        let termination = await LiveCleanSystemTrashExecutor.run(
            SystemTrashRequest(paths: [fixture.old, fixture.young], requesterUID: UInt32(getuid())),
            scriptPath: scriptPath,
            privileged: false,
            environment: fixtureEnvironment(reports: fixture.reports, trashRoot: fixture.trashRoot),
            trashRoot: fixture.trashRoot,
            temporaryDirectory: temporaryDirectory
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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)
            .filter { $0.hasSuffix(".manifest") }
        XCTAssertTrue(leftovers.isEmpty, "清单文件用完即删")
    }

    /// 一个都没移走:废纸篓里不留空文件夹。
    func testNothingMovedLeavesNoEmptyFolderInTrash() async throws {
        let scriptPath = try XCTUnwrap(LiveCleanSystemTrashExecutor.bundledScriptPath)
        let fixture = try makeFixture()

        let termination = await LiveCleanSystemTrashExecutor.run(
            SystemTrashRequest(paths: [fixture.young], requesterUID: UInt32(getuid())),
            scriptPath: scriptPath,
            privileged: false,
            environment: fixtureEnvironment(reports: fixture.reports, trashRoot: fixture.trashRoot),
            trashRoot: fixture.trashRoot,
            temporaryDirectory: temporaryDirectory
        )

        guard case let .completed(receipt) = termination else {
            return XCTFail("应走完,实际 \(termination)")
        }
        XCTAssertEqual(receipt.recycled, [:])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.trashRoot + "/Pulse 系统级"),
            "没移走任何东西时,专属子目录整个收掉"
        )
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
