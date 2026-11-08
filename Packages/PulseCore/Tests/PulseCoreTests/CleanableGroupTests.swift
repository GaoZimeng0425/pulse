@testable import PulseCore
import XCTest

/// 轻桥判定(p4-uninstaller/05):白名单命中/子孙域/域外零暗示 + 与可清理清单
/// 清单**同源**(同一规则表同一套组件语义,checklist 明令不许两套口径漂移)。
final class CleanableGroupTests: XCTestCase {
    private let home = "/Users/tester"

    private func node(
        _ path: String,
        name: String? = nil,
        bytes: Int64 = 100,
        children: [SpaceNode] = []
    ) -> SpaceNode {
        SpaceNode(
            name: name ?? (path as NSString).lastPathComponent,
            path: path, kind: .directory, accountedBytes: bytes,
            children: children
        )
    }

    /// 合成家目录树:白名单域(DerivedData / Xcode 缓存 / Homebrew 缓存)+ 干扰目录。
    private var fakeHome: SpaceNode {
        node(home, name: "tester", bytes: 10000, children: [
            node("\(home)/Library", bytes: 5000, children: [
                node("\(home)/Library/Developer", bytes: 3000, children: [
                    node("\(home)/Library/Developer/Xcode", bytes: 2500, children: [
                        node("\(home)/Library/Developer/Xcode/DerivedData", bytes: 2000),
                        node("\(home)/Library/Developer/Xcode/Archives", bytes: 400),
                    ]),
                ]),
                node("\(home)/Library/Caches", bytes: 1500, children: [
                    node("\(home)/Library/Caches/com.apple.dt.Xcode", bytes: 500),
                    node("\(home)/Library/Caches/Homebrew", bytes: 600),
                    node("\(home)/Library/Caches/RandomApp", bytes: 300),
                ]),
            ]),
            node("\(home)/Documents", bytes: 3000, children: [
                node("\(home)/Documents/照片库", bytes: 2800),
            ]),
        ])
    }

    // MARK: 命中与零暗示

    func testWhitelistPathsHitTheirGroup() {
        XCTAssertEqual(
            JunkRuleTable.cleanableGroup(for: "\(home)/Library/Developer/Xcode/DerivedData", home: home),
            .globalToolCache
        )
        XCTAssertEqual(
            JunkRuleTable.cleanableGroup(for: "\(home)/Library/Caches/Homebrew", home: home),
            .globalToolCache
        )
    }

    func testDescendantsOfWhitelistNodeAlsoHit() {
        // 地图下钻进白名单目录里面:子块仍属「这块能清」域(跳转,不做块级删除)。
        let path = "\(home)/Library/Developer/Xcode/DerivedData/MyApp-abc123"
        XCTAssertEqual(JunkRuleTable.cleanableGroup(for: path, home: home), .globalToolCache)
    }

    func testOutsideAndSealedPathsGiveNoHint() {
        XCTAssertNil(JunkRuleTable.cleanableGroup(for: "\(home)/Documents/照片库", home: home), "个人文件零暗示")
        XCTAssertNil(JunkRuleTable.cleanableGroup(for: "\(home)/Library/Caches/RandomApp", home: home), "未识别缓存零暗示")
        XCTAssertNil(JunkRuleTable.cleanableGroup(for: "/System/Library", home: home), "系统域不在家内,天然零暗示")
        XCTAssertNil(JunkRuleTable.cleanableGroup(for: "\(home)/Library", home: home), "家目录浅层不误中(组件数不够)")
    }

    func testPrefixLookalikeDoesNotHit() {
        XCTAssertNil(
            JunkRuleTable.cleanableGroup(for: "\(home)/Library/Caches/Homebrew.bak", home: home),
            "literal 全等:suffix 变体撞名不误中"
        )
    }

    // MARK: 同源(与可清理清单清单)

    func testMatcherCandidatesAllCarryCleanableGroupSameOrigin() {
        let trees = [fakeHome]
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        XCTAssertGreaterThanOrEqual(candidates.count, 3, "夹具应产出多个候选(DerivedData/Xcode 缓存/Homebrew 缓存)")
        for candidate in candidates {
            let group = JunkRuleTable.cleanableGroup(for: candidate.path, home: home)
            XCTAssertNotNil(group, "清单候选路径必须能被轻桥判定命中:\(candidate.path)")
            XCTAssertEqual(
                group,
                candidate.group,
                "口径漂移:\(candidate.path) 清单说 \(candidate.group) 轻桥说 \(String(describing: group))"
            )
        }
    }

    func testMatcherAndBridgeAgreeOnSuffixVariants() {
        // DeviceSupport 是 suffix 分量:清单与轻桥对同一条目录必须同判。
        let deviceSupport = "\(home)/Library/Developer/Xcode/iPhone 17 DeviceSupport"
        let trees = [node(home, name: "tester", bytes: 1000, children: [
            node("\(home)/Library", bytes: 1000, children: [
                node("\(home)/Library/Developer", bytes: 1000, children: [
                    node("\(home)/Library/Developer/Xcode", bytes: 1000, children: [
                        node(deviceSupport, bytes: 500),
                    ]),
                ]),
            ]),
        ])]
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        XCTAssertTrue(candidates.contains { $0.path == deviceSupport }, "夹具确认清单命中 suffix 域")
        XCTAssertEqual(JunkRuleTable.cleanableGroup(for: deviceSupport, home: home), candidates.first?.group)
    }
}
