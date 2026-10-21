@testable import PulseCore
import XCTest

/// launchd 服务清单的纯逻辑(launchd-attribution/01,ADR-0005):单 plist 解析四态、
/// 组装器的两层缓存(密封层只读一次、补缺重试、可变层每轮重读)、字面 ∪ realpath、
/// 健康三态折算,以及状态沿日志。全部不碰磁盘:目录读取走计数假源,realpath 走注入闭包。
final class LaunchdManifestTests: XCTestCase {
    // MARK: 夹具

    /// 计数假源:按目录预设读取结果,并记录每个目录被读了几次。
    final class CountingPlistSource: LaunchdPlistSource, @unchecked Sendable {
        var responses: [String: LaunchdPlistDirectoryRead]
        private(set) var reads: [String: Int] = [:]

        init(_ responses: [String: LaunchdPlistDirectoryRead]) {
            self.responses = responses
        }

        func read(directory: String) -> LaunchdPlistDirectoryRead {
            reads[directory, default: 0] += 1
            return responses[directory] ?? .absent
        }
    }

    private func plist(_ dictionary: [String: Any]) -> Data {
        // 测试夹具:字典字面量序列化不会失败,失败即崩是期望行为
        // swiftlint:disable:next force_try
        try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    private func programPlist(_ path: String) -> Data {
        plist(["Label": "test", "ProgramArguments": [path]])
    }

    private let sealedA = "/System/Library/LaunchDaemons"
    private let sealedB = "/System/Library/LaunchAgents"
    private let mutableA = "/Library/LaunchDaemons"
    private let mutableB = "/Users/x/Library/LaunchAgents"

    private func assembler(
        resolve: @escaping @Sendable (String) -> String = { $0 }
    ) -> LaunchdManifestAssembler {
        LaunchdManifestAssembler(
            sealedDirectories: [sealedA, sealedB],
            mutableDirectories: [mutableA, mutableB],
            resolveSymlinks: resolve
        )
    }

    // MARK: 单 plist 解析

    func testProgramKeyWins() {
        let data = plist(["Program": "/usr/local/corplink/corplink-service"])
        XCTAssertEqual(LaunchdServiceManifest.executablePath(fromPlist: data), "/usr/local/corplink/corplink-service")
    }

    func testProgramArgumentsFirstElementWhenNoProgram() {
        let data = plist(["ProgramArguments": ["/opt/orbit/bin/orbit/orbit", "--verbose"]])
        XCTAssertEqual(LaunchdServiceManifest.executablePath(fromPlist: data), "/opt/orbit/bin/orbit/orbit")
    }

    /// 两者同在时取 Program(launchd 语义:ProgramArguments 只是 argv)。
    func testProgramTakesPrecedenceOverProgramArguments() {
        let data = plist(["Program": "/a/program", "ProgramArguments": ["/b/argv0"]])
        XCTAssertEqual(LaunchdServiceManifest.executablePath(fromPlist: data), "/a/program")
    }

    func testNeitherKeyYieldsNil() {
        XCTAssertNil(LaunchdServiceManifest.executablePath(fromPlist: plist(["Label": "only"])))
    }

    func testEmptyProgramFallsThroughToArgumentsAndEmptyArgumentsYieldNil() {
        XCTAssertEqual(
            LaunchdServiceManifest.executablePath(fromPlist: plist(["Program": "", "ProgramArguments": ["/x"]])),
            "/x"
        )
        XCTAssertNil(LaunchdServiceManifest.executablePath(fromPlist: plist(["ProgramArguments": [String]()])))
    }

    func testMalformedBytesAndNonDictionaryRootYieldNil() throws {
        XCTAssertNil(LaunchdServiceManifest.executablePath(fromPlist: Data("not a plist".utf8)))
        let array = try PropertyListSerialization.data(fromPropertyList: ["/x"], format: .xml, options: 0)
        XCTAssertNil(LaunchdServiceManifest.executablePath(fromPlist: array))
    }

    // MARK: 目录常量

    func testDirectoryConstants() {
        XCTAssertEqual(
            LaunchdServiceManifest.sealedDirectories,
            ["/System/Library/LaunchDaemons", "/System/Library/LaunchAgents"]
        )
        XCTAssertEqual(
            LaunchdServiceManifest.mutableDirectories(homeDirectory: "/Users/x"),
            [
                "/Library/LaunchDaemons",
                "/Library/LaunchAgents",
                "/Library/Apple/System/Library/LaunchDaemons",
                "/Library/Apple/System/Library/LaunchAgents",
                "/Users/x/Library/LaunchAgents",
            ]
        )
    }

    // MARK: 组装器:两层缓存

    /// 票面验收"刷新间隔内重复取用不触发读取"在本设计里真实成立的那一层:密封层两轮只读一次;
    /// 可变层每轮重读。
    func testSealedTierReadOnceMutableTierReadEveryRound() {
        let source = CountingPlistSource([
            sealedA: .plists([programPlist("/usr/libexec/sealed-a")]),
            sealedB: .plists([programPlist("/usr/libexec/sealed-b")]),
            mutableA: .plists([programPlist("/usr/local/corplink/corplink-service")]),
            mutableB: .plists([programPlist("/opt/homebrew/opt/ollama/bin/ollama")]),
        ])
        var assembler = assembler()

        let first = assembler.assemble(using: source)
        let second = assembler.assemble(using: source)

        XCTAssertEqual(source.reads[sealedA], 1)
        XCTAssertEqual(source.reads[sealedB], 1)
        XCTAssertEqual(source.reads[mutableA], 2)
        XCTAssertEqual(source.reads[mutableB], 2)
        XCTAssertTrue(assembler.isSealedTierFrozen)
        XCTAssertEqual(first.health, .healthy)
        XCTAssertEqual(second, first)
        XCTAssertEqual(
            first.paths,
            [
                "/usr/libexec/sealed-a", "/usr/libexec/sealed-b",
                "/usr/local/corplink/corplink-service", "/opt/homebrew/opt/ollama/bin/ollama",
            ]
        )
    }

    /// 密封层只成功一个目录:先并进已有的,报降级,下一轮只补读缺的那个;两个都成功才冻结。
    func testSealedTierPartialSuccessRetriesOnlyTheMissingDirectory() {
        let source = CountingPlistSource([
            sealedA: .plists([programPlist("/usr/libexec/sealed-a")]),
            sealedB: .unreadable,
            mutableA: .plists([]),
        ])
        var assembler = assembler()

        let first = assembler.assemble(using: source)
        XCTAssertEqual(first.health, .degraded(unreadable: [sealedB]))
        XCTAssertEqual(first.paths, ["/usr/libexec/sealed-a"])
        XCTAssertFalse(assembler.isSealedTierFrozen)

        source.responses[sealedB] = .plists([programPlist("/usr/libexec/sealed-b")])
        let second = assembler.assemble(using: source)
        XCTAssertEqual(second.health, .healthy)
        XCTAssertEqual(second.paths, ["/usr/libexec/sealed-a", "/usr/libexec/sealed-b"])
        XCTAssertTrue(assembler.isSealedTierFrozen)

        _ = assembler.assemble(using: source)
        XCTAssertEqual(source.reads[sealedA], 1)
        XCTAssertEqual(source.reads[sealedB], 2)
        XCTAssertEqual(source.reads[mutableA], 3)
    }

    /// 可变层随轮次变化:上一轮有的 plist 这一轮没了,路径随之消失(清单整份替换)。
    func testMutableTierReflectsRemovalNextRound() {
        let source = CountingPlistSource([
            mutableA: .plists([programPlist("/usr/local/corplink/corplink-service")]),
        ])
        var assembler = LaunchdManifestAssembler(
            sealedDirectories: [], mutableDirectories: [mutableA], resolveSymlinks: { $0 }
        )

        XCTAssertEqual(assembler.assemble(using: source).paths, ["/usr/local/corplink/corplink-service"])
        source.responses[mutableA] = .plists([])
        XCTAssertEqual(assembler.assemble(using: source).paths, [])
    }

    // MARK: 组装器:字面 ∪ realpath

    /// 符号链接程序同时收字面与 realpath;非链接程序只收字面(解析结果等于自身不重复)。
    func testRealpathAddedAlongsideLiteralOnlyWhenDifferent() {
        let link = "/opt/homebrew/opt/ollama/bin/ollama"
        let target = "/opt/homebrew/Cellar/ollama/0.40.6/libexec/ollama"
        let plain = "/usr/local/corplink/corplink-service"
        let source = CountingPlistSource([
            mutableA: .plists([programPlist(link), programPlist(plain)]),
        ])
        var assembler = LaunchdManifestAssembler(
            sealedDirectories: [], mutableDirectories: [mutableA],
            resolveSymlinks: { $0 == link ? target : $0 }
        )

        XCTAssertEqual(assembler.assemble(using: source).paths, [link, target, plain])
    }

    func testMalformedPlistSkippedOthersKept() {
        let source = CountingPlistSource([
            mutableA: .plists([
                Data("garbage".utf8),
                programPlist("/usr/local/bin/good"),
                plist(["Label": "no program"]),
            ]),
        ])
        var assembler = LaunchdManifestAssembler(
            sealedDirectories: [], mutableDirectories: [mutableA], resolveSymlinks: { $0 }
        )

        let outcome = assembler.assemble(using: source)
        XCTAssertEqual(outcome.health, .healthy)
        XCTAssertEqual(outcome.paths, ["/usr/local/bin/good"])
    }

    // MARK: 组装器:健康三态

    /// 缺席不是失败(~/Library/LaunchAgents 常见不存在)。
    func testAbsentMutableDirectoryIsHealthy() {
        let source = CountingPlistSource([
            sealedA: .plists([]), sealedB: .plists([]),
            mutableA: .plists([programPlist("/usr/local/bin/x")]),
            mutableB: .absent,
        ])
        var assembler = assembler()

        let outcome = assembler.assemble(using: source)
        XCTAssertEqual(outcome.health, .healthy)
        XCTAssertEqual(outcome.paths, ["/usr/local/bin/x"])
    }

    func testUnreadableMutableDirectoryDegradesButDelivers() {
        let source = CountingPlistSource([
            sealedA: .plists([]), sealedB: .plists([]),
            mutableA: .unreadable,
            mutableB: .plists([programPlist("/usr/local/bin/y")]),
        ])
        var assembler = assembler()

        let outcome = assembler.assemble(using: source)
        XCTAssertEqual(outcome.health, .degraded(unreadable: [mutableA]))
        XCTAssertEqual(outcome.paths, ["/usr/local/bin/y"])
    }

    /// 密封层已冻结、本轮尝试的(可变层)目录全部不可读 → 失败,paths 为 nil(交付方退回 lastGood),
    /// 而不是只剩密封层的半份清单。
    func testAllAttemptedDirectoriesUnreadableFails() {
        let source = CountingPlistSource([
            sealedA: .plists([programPlist("/usr/libexec/a")]), sealedB: .plists([]),
            mutableA: .plists([programPlist("/usr/local/bin/x")]), mutableB: .absent,
        ])
        var assembler = assembler()
        XCTAssertEqual(assembler.assemble(using: source).health, .healthy)

        source.responses[mutableA] = .unreadable
        source.responses[mutableB] = .unreadable
        let outcome = assembler.assemble(using: source)

        XCTAssertEqual(outcome.health, .failed(unreadable: [mutableA, mutableB]))
        XCTAssertNil(outcome.paths)
    }

    func testFirstRoundEverythingUnreadableFailsAndNothingFreezes() {
        let source = CountingPlistSource([
            sealedA: .unreadable, sealedB: .unreadable, mutableA: .unreadable, mutableB: .unreadable,
        ])
        var assembler = assembler()

        let outcome = assembler.assemble(using: source)
        XCTAssertEqual(outcome.health, .failed(unreadable: [sealedA, sealedB, mutableA, mutableB]))
        XCTAssertNil(outcome.paths)
        XCTAssertFalse(assembler.isSealedTierFrozen)
    }

    // MARK: 状态沿日志

    func testHealthLogRecordsOnlyTransitions() {
        var log = LaunchdManifestHealthLog()

        XCTAssertNil(log.transition(to: .healthy), "初态即正常,同态静默")

        let degraded = log.transition(to: .degraded(unreadable: [mutableA]))
        XCTAssertEqual(degraded?.level, .warn)
        XCTAssertTrue(degraded?.message.contains(mutableA) == true)
        XCTAssertNil(log.transition(to: .degraded(unreadable: [mutableA])), "同一组不可读目录不再记")

        let changed = log.transition(to: .degraded(unreadable: [mutableA, mutableB]))
        XCTAssertEqual(changed?.level, .warn, "换一组不可读目录 = 换一种降级,再记一条")

        let failed = log.transition(to: .failed(unreadable: [mutableA, mutableB]))
        XCTAssertEqual(failed?.level, .error)
        XCTAssertNil(log.transition(to: .failed(unreadable: [mutableA, mutableB])))

        let recovered = log.transition(to: .healthy)
        XCTAssertEqual(recovered?.level, .info)
        XCTAssertTrue(recovered?.message.contains("恢复正常") == true)
    }

    func testHealthLogHealthyStraightToFailedIsError() {
        var log = LaunchdManifestHealthLog()
        XCTAssertEqual(log.transition(to: .failed(unreadable: [sealedA]))?.level, .error)
    }
}
