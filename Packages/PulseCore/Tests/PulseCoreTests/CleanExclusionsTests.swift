@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// 排除目录的唯一判定(p4-cleaner/04;GLOSSARY「排除目录」):按路径分量匹配、加入只收窄、
/// 扫描侧与删除侧共用同一函数。
final class CleanExclusionsTests: XCTestCase {
    func testPrefixMatchIsComponentWise() {
        let prefixes = ["/Users/t/Library/Caches"]
        XCTAssertTrue(CleanExclusions.isExcluded("/Users/t/Library/Caches", by: prefixes), "等于前缀本身")
        XCTAssertTrue(CleanExclusions.isExcluded("/Users/t/Library/Caches/Homebrew", by: prefixes))
        XCTAssertTrue(CleanExclusions.isExcluded("/Users/t/Library/Caches/Homebrew/", by: prefixes), "尾斜杠归一")
        XCTAssertFalse(CleanExclusions.isExcluded("/Users/t/Library/CachesBackup", by: prefixes), "字符串前缀 ≠ 路径前缀")
        XCTAssertFalse(CleanExclusions.isExcluded("/Users/t/Library", by: prefixes), "父目录不算")
        XCTAssertFalse(CleanExclusions.isExcluded("/Users/t/Library/Caches", by: []))
        XCTAssertTrue(CleanExclusions.isExcluded("/anything", by: ["/"]), "排除根 = 排除一切")
    }

    func testPrefixesWithTrailingSlashStillMatch() {
        XCTAssertTrue(CleanExclusions.isExcluded("/Users/t/.npm/_cacache", by: ["/Users/t/.npm/"]))
    }

    func testAddingIsIdempotentAndCoveredPrefixesAreNoOps() {
        var list: [String] = []
        list = CleanExclusions.adding("/Users/t/Library/Caches/", to: list)
        XCTAssertEqual(list, ["/Users/t/Library/Caches"])
        list = CleanExclusions.adding("/Users/t/Library/Caches", to: list)
        XCTAssertEqual(list, ["/Users/t/Library/Caches"], "重复加不重复存")
        list = CleanExclusions.adding("/Users/t/Library/Caches/Homebrew", to: list)
        XCTAssertEqual(list, ["/Users/t/Library/Caches"], "已被更宽前缀覆盖 → 不加(判定结果不变)")
        XCTAssertEqual(CleanExclusions.adding("", to: list), list)
    }

    func testWiderPrefixAbsorbsNarrowerOnes() {
        let list = CleanExclusions.adding("/Users/t/Library", to: ["/Users/t/Library/Caches", "/Users/t/.npm", "/Users/t/Library/pnpm"])
        XCTAssertEqual(list, ["/Users/t/.npm", "/Users/t/Library"])
    }

    func testRemoving() {
        let list = CleanExclusions.removing("/Users/t/Library/Caches/", from: ["/Users/t/Library/Caches", "/Users/t/.npm"])
        XCTAssertEqual(list, ["/Users/t/.npm"])
        XCTAssertEqual(CleanExclusions.removing("/nope", from: list), list)
    }

    /// 扫描侧走的就是这同一判定:被排除目录不下潜、不计数、不被请求。
    func testEngineUsesTheSamePredicate() async {
        let fs = FakeCleanDirectoryEnumerator(listings: [
            "/r": .entries([CleanFixture.directory("keep", fileID: 1), CleanFixture.directory("skip", fileID: 2)]),
            "/r/keep": .entries([CleanFixture.file("a", allocated: 100, reclaimable: 100)]),
            "/r/skip": .entries([CleanFixture.file("b", allocated: 100, reclaimable: 100)]),
        ])
        let result = await SpaceScanEngine().scan(
            SpaceScanOptions(roots: ["/r"], excludedPathPrefixes: ["/r/skip/"]),
            using: fs
        )
        XCTAssertEqual(result.trees[0].accountedBytes, 100)
        let skipRequests = await fs.requestedPathCount("/r/skip")
        XCTAssertEqual(skipRequests, 0)
    }
}
