@testable import PulseCore
import XCTest

// agent-git-status/01:会话工作目录的 git 状态——分支名 + 未提交标记。全合成
// 夹具(HEAD / 重定向 / porcelain 字符串),零真 git 调用(测试负载最小化规矩);
// Live 子进程路径不进自动化,装配可达性由 MonitorAssemblyTests 钉。

final class GitHeadParserTests: XCTestCase {
    func testRefLineYieldsBranchName() {
        XCTAssertEqual(GitHeadParser.branch(Data("ref: refs/heads/develop\n".utf8)), "develop")
    }

    func testRefLineKeepsNestedBranchSlashes() {
        XCTAssertEqual(
            GitHeadParser.branch(Data("ref: refs/heads/feat/agent-git-status\n".utf8)),
            "feat/agent-git-status"
        )
    }

    func testDetachedShaYieldsShortSha() {
        let sha = String(repeating: "4c8b31ff", count: 5)
        XCTAssertEqual(GitHeadParser.branch(Data("\(sha)\n".utf8)), "4c8b31f")
    }

    func testEmptyYieldsNil() {
        XCTAssertNil(GitHeadParser.branch(Data("".utf8)))
    }

    /// 畸形内容既不是 ref 行也不是 40 位 hex → nil,不猜(不猜纪律)。
    func testGarbageYieldsNil() {
        XCTAssertNil(GitHeadParser.branch(Data("not a head\n".utf8)))
        XCTAssertNil(GitHeadParser.branch(Data("ref: refs/heads/\n".utf8)))
    }
}

final class GitWorktreeRedirectTests: XCTestCase {
    func testParsesGitdirPath() {
        XCTAssertEqual(
            GitWorktreeRedirect.gitdir(Data("gitdir: /a/b/.git/worktrees/slug\n".utf8)),
            "/a/b/.git/worktrees/slug"
        )
    }

    func testRequiresPrefix() {
        XCTAssertNil(GitWorktreeRedirect.gitdir(Data("/a/b/.git/worktrees/slug\n".utf8)))
    }

    func testEmptyPathYieldsNil() {
        XCTAssertNil(GitWorktreeRedirect.gitdir(Data("gitdir: \n".utf8)))
    }
}

final class GitPorcelainTests: XCTestCase {
    func testEmptyIsClean() {
        XCTAssertFalse(GitPorcelain.isDirty(Data("".utf8)))
    }

    func testWhitespaceOnlyIsClean() {
        XCTAssertFalse(GitPorcelain.isDirty(Data("\n\n".utf8)))
    }

    func testModifiedIsDirty() {
        XCTAssertTrue(GitPorcelain.isDirty(Data(" M Pulse/App.swift\n".utf8)))
    }

    /// 拍板③:未跟踪文件(`??`)也算未提交——agent 的活没落盘。
    func testUntrackedIsDirty() {
        XCTAssertTrue(GitPorcelain.isDirty(Data("?? Notes.swift\n".utf8)))
    }

    func testMultipleLinesIsDirty() {
        XCTAssertTrue(GitPorcelain.isDirty(Data(" M a.swift\n?? b\n".utf8)))
    }
}

private struct FakeGitStatusReader: SessionGitStatusReading {
    var heads: [String: Data] = [:]
    var porcelain: [String: Data] = [:]

    func gitHeadFile(cwd: String) -> Data? {
        heads[cwd]
    }

    func gitStatusOutput(cwd: String) -> Data? {
        porcelain[cwd]
    }
}

final class SessionGitStatusFinderTests: XCTestCase {
    func testWorkingDirsDedupesPreservingOrder() {
        XCTAssertEqual(
            SessionGitStatusFinder.workingDirs(claude: ["/a", "/b", "/a"], zcode: ["/b", nil, "/c"]),
            ["/a", "/b", "/c"]
        )
    }

    func testWorkingDirsCapAtLimit() {
        let many = (0 ..< 20).map { "/repo/\($0)" }
        let dirs = SessionGitStatusFinder.workingDirs(claude: many, zcode: [])
        XCTAssertEqual(dirs.count, SessionGitStatusFinder.maxWorkingDirs)
        XCTAssertEqual(dirs.first, "/repo/0")
    }

    func testStatusCombinesBranchAndDirty() {
        var reader = FakeGitStatusReader()
        reader.heads["/w"] = Data("ref: refs/heads/feat/x\n".utf8)
        reader.porcelain["/w"] = Data(" M a.swift\n?? b\n".utf8)
        XCTAssertEqual(
            SessionGitStatusFinder.status(cwd: "/w", reader: reader),
            SessionGitStatus(branch: "feat/x", dirty: true)
        )
    }

    func testStatusCleanRepo() {
        var reader = FakeGitStatusReader()
        reader.heads["/w"] = Data("ref: refs/heads/main\n".utf8)
        reader.porcelain["/w"] = Data("".utf8)
        XCTAssertEqual(
            SessionGitStatusFinder.status(cwd: "/w", reader: reader),
            SessionGitStatus(branch: "main", dirty: false)
        )
    }

    /// 非 git 仓库(HEAD 读不到)整体 nil,UI 安静缺位(拍板⑤)。
    func testStatusNonRepoYieldsNil() {
        XCTAssertNil(SessionGitStatusFinder.status(cwd: "/tmp", reader: FakeGitStatusReader()))
    }

    /// porcelain 跑不动(子进程失败/超时):只缺脏标记,不误报「未提交」——宁缺毋假。
    func testStatusPorcelainFailureReportsClean() {
        var reader = FakeGitStatusReader()
        reader.heads["/w"] = Data("ref: refs/heads/main\n".utf8)
        XCTAssertEqual(
            SessionGitStatusFinder.status(cwd: "/w", reader: reader),
            SessionGitStatus(branch: "main", dirty: false)
        )
    }

    func testStatusDetachedHeadYieldsShortSha() {
        var reader = FakeGitStatusReader()
        reader.heads["/w"] = Data(String(repeating: "4c8b31ff", count: 5).utf8)
        XCTAssertEqual(
            SessionGitStatusFinder.status(cwd: "/w", reader: reader)?.branch,
            "4c8b31f"
        )
    }
}
