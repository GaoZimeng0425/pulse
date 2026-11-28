@testable import PulseCore
import PulseCoreTestSupport

/// 规则表类测试共用的小家目录:缓存目录下摆几个带字节的目录,扫成树,或直接过一遍规则表。
/// 假家目录(`CleanFixture.homeListings`),零真盘。
enum JunkCacheScanFixture {
    static let home = "/Users/test"

    static func trees(cachesNames: [String]) async -> [SpaceNode] {
        let directories = Dictionary(uniqueKeysWithValues: cachesNames.enumerated().map {
            ("Library/Caches/" + $1, Int64(100 + $0))
        })
        let listings = CleanFixture.homeListings(home: home, directories: directories)
        let scanner = FakeCleanDirectoryEnumerator(listings: listings)
        return await SpaceScanEngine().scan(SpaceScanOptions(roots: [home], retainFileNodes: false), using: scanner)
            .trees
    }

    static func candidates(cachesNames: [String]) async -> [JunkCandidate] {
        let scanned = await trees(cachesNames: cachesNames)
        return JunkMatcher.candidates(in: scanned, home: home)
    }
}
