@testable import PulseCore
import XCTest

/// 应用缓存知识库完整性(p6-cleaner/01):条目良构 + 跨条目不撞名 +
/// 不与开发工具规则的 Caches 目录撞名(撞名 = 同路径两张卡、重复计数)。
final class AppCacheCatalogTests: XCTestCase {
    func testEntriesAreWellFormed() {
        for entry in AppCacheCatalog.entries {
            XCTAssertFalse(entry.key.isEmpty, "key 不能为空")
            XCTAssertFalse(entry.names.isEmpty, "\(entry.key):至少一个目录名")
            XCTAssertTrue(
                entry.names.allSatisfy { !$0.isEmpty && !$0.contains("/") },
                "\(entry.key):names 是 Caches 一级目录名,不含路径分隔符"
            )
            XCTAssertTrue(entry.group == .browserCache || entry.group == .appCache, "\(entry.key):知识库只进浏览器/应用缓存两组")
            XCTAssertFalse(entry.title.isEmpty, "\(entry.key):标题非空")
            XCTAssertFalse(entry.rationale.isEmpty, "\(entry.key):rationale 非空(确认清单靠它说话)")
        }
    }

    func testNoDuplicateDirectoryNamesAcrossEntries() {
        let names = AppCacheCatalog.entries.flatMap(\.names)
        XCTAssertEqual(names.count, Set(names).count, "目录名跨条目重复:先到的规则吃掉后到的,后条目变死规则")
    }

    func testKeysAreUnique() {
        let keys = AppCacheCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "key 重复会让规则 id 撞车")
    }

    /// 知识库目录名不得与开发工具规则的 `Library/Caches/<名>` 一级名相同
    /// (Homebrew / JetBrains / pnpm / electron 等——撞名 = 一条路径两张卡)。
    func testCatalogNamesDoNotCollideWithToolCacheRules() {
        let toolCachesNames = Set(
            JunkRuleTable.globalToolCacheRules.flatMap { rule in
                rule.patterns.compactMap { pattern -> String? in
                    guard pattern.components.count == 3,
                          case let .literal(first) = pattern.components[0], first == "Library",
                          case let .literal(second) = pattern.components[1], second == "Caches",
                          case let .literal(third) = pattern.components[2]
                    else { return nil }
                    return third
                }
            }
        )
        XCTAssertFalse(toolCachesNames.isEmpty, "解剖 pattern 的写法失效了——护栏在空转")

        for entry in AppCacheCatalog.entries {
            for name in entry.names {
                XCTAssertFalse(
                    toolCachesNames.contains(name),
                    "\(entry.key) 的目录名「\(name)」与开发工具规则撞名,应二选一"
                )
            }
        }
    }

    /// 知识库规则全部指向 ~/Library/Caches 下的字面目录(不越域)。
    func testRulesStayInsideCachesDomain() {
        for rule in AppCacheCatalog.rules {
            XCTAssertTrue(rule.id.hasPrefix("browser.") || rule.id.hasPrefix("appcache."), rule.id)
            for pattern in rule.patterns {
                XCTAssertEqual(pattern.components.count, 3, "\(rule.id):只允许 Library/Caches/<名> 三段")
                guard case let .literal(first) = pattern.components.first else {
                    XCTFail("\(rule.id):首段必须是字面 Library")
                    continue
                }
                XCTAssertEqual(first, "Library", "\(rule.id):只允许 Library 域")
            }
        }
    }
}
