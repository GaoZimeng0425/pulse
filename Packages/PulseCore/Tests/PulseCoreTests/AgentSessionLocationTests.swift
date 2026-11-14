@testable import PulseCore
import XCTest

// MARK: - 会话位置(agent-tab/09:项目名 + worktree + 缩写路径)

final class AgentSessionLocationTests: XCTestCase {
    private let home = "/Users/x"

    func testPlainProjectHasNoWorktree() {
        let location = AgentSessionLocation.resolve(path: "/Users/x/code/pulse", home: home)
        XCTAssertEqual(location?.project, "pulse")
        XCTAssertNil(location?.worktree)
        XCTAssertEqual(location?.displayPath, "~/code/pulse")
    }

    func testDotWorktreesFoldsToProjectAndKeepsSlug() {
        let location = AgentSessionLocation.resolve(path: "/Users/x/code/pulse/.worktrees/agent-tab-08", home: home)
        XCTAssertEqual(location?.project, "pulse")
        XCTAssertEqual(location?.worktree, "agent-tab-08")
        XCTAssertEqual(location?.displayPath, "~/code/pulse/.worktrees/agent-tab-08")
    }

    func testGitWorktreesLayoutAlsoFolds() {
        let location = AgentSessionLocation.resolve(path: "/Users/x/pulse/.git/worktrees/fix-a", home: home)
        XCTAssertEqual(location?.project, "pulse")
        XCTAssertEqual(location?.worktree, "fix-a")
    }

    func testSubdirectoryInsideWorktreeKeepsWorktreeSlug() {
        let location = AgentSessionLocation.resolve(path: "/Users/x/pulse/.worktrees/w1/Packages/Core", home: home)
        XCTAssertEqual(location?.project, "pulse")
        XCTAssertEqual(location?.worktree, "w1")
    }

    func testPathOutsideHomeStaysAbsolute() {
        let location = AgentSessionLocation.resolve(path: "/tmp/scratch", home: home)
        XCTAssertEqual(location?.displayPath, "/tmp/scratch")
        // 前缀相同但不是 home 子目录(/Users/xy)不缩写。
        XCTAssertEqual(AgentSessionLocation.resolve(path: "/Users/xy/a", home: home)?.displayPath, "/Users/xy/a")
    }

    func testDegenerateInputReturnsNil() {
        XCTAssertNil(AgentSessionLocation.resolve(path: "", home: home))
        XCTAssertNil(AgentSessionLocation.resolve(path: "/", home: home))
    }
}
