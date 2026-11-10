@testable import PulseCore
import XCTest

/// 空间地图纯值层(p4-cleaner/07):显示树(firmlink 提升 / 密封折叠 / 裁剪排序)
/// 与两环旭日弧几何。形态先例 = 真机探针(2026-11-01):根目录原始枚举序 System
/// 在 Users 之前,Data firmlink 先到先得,顶层 Users/Applications/private/opt
/// 在扫描树里全埋在 /System/Volumes/Data 之下——不提升的话旭日图没法看。
final class SpaceMapTests: XCTestCase {
    // MARK: 夹具

    private func dir(
        _ name: String,
        under parent: String,
        bytes: Int64 = 0,
        partial: Bool = false,
        children: [SpaceNode] = []
    ) -> SpaceNode {
        // bytes 语义 = 引擎产出的「子树总量」(自有文件 + 子孙;≥ 子孙和)。
        let path: String = if name == "/" {
            "/"
        } else if parent == "/" || parent.isEmpty {
            "/" + name
        } else {
            parent + "/" + name
        }
        return SpaceNode(
            name: name,
            path: path,
            kind: .directory,
            accountedBytes: max(bytes, children.reduce(Int64(0)) { $0 + $1.accountedBytes }),
            isPartial: partial,
            children: children
        )
    }

    /// 真机形状的最小复刻:/ 下 System(含 Volumes/Data 链)+ 被埋的 Users/Applications。
    private func machineLikeTree() -> SpaceNode {
        let users = dir("Users", under: "/System/Volumes/Data", bytes: 200, children: [
            dir("aa00930", under: "/System/Volumes/Data/Users", bytes: 180),
            dir("shared", under: "/System/Volumes/Data/Users", bytes: 20),
        ])
        let applications = dir("Applications", under: "/System/Volumes/Data", bytes: 60)
        let data = dir("Data", under: "/System/Volumes", children: [users, applications])
        let volumes = dir("Volumes", under: "/System", children: [data])
        // System 总量 340 = 自有 SSV 文件 80 + Data 子树 260(引擎 absorb 语义)
        let system = dir("System", under: "/", bytes: 340, children: [volumes])
        return dir("/", under: "", bytes: 370, children: [system])
    }

    // MARK: SpaceMapTree.build——firmlink 提升

    func testBuildHoistsDataChildrenBackToTopLevel() {
        let map = SpaceMapTree.build(from: machineLikeTree())

        let names = map.children.map(\.name)
        XCTAssertTrue(names.contains("Users"), "Users 应被拼回顶层,实际:\(names)")
        XCTAssertTrue(names.contains("Applications"), "Applications 应被拼回顶层,实际:\(names)")
        XCTAssertEqual(map.children.first?.name, "Users", "大到小排序,Users(200) 居首")

        let users = map.children.first { $0.name == "Users" }
        XCTAssertEqual(users?.path, "/Users", "提升后的路径改写为规范名")
        XCTAssertEqual(users?.children.first?.path, "/Users/aa00930", "子孙路径一并规范化(Finder/面包屑用)")
        XCTAssertEqual(users?.isSealed, false)
    }

    func testBuildFoldsSystemRemainderIntoSingleSealedBlock() {
        let map = SpaceMapTree.build(from: machineLikeTree())

        // System 总 340,其中 Data 链 260 → 密封余量 80;原 System/Volumes/Data 链不得再以可下钻形态出现
        let sealed = map.children.first { $0.isSealed }
        XCTAssertEqual(sealed?.name, "系统(密封)")
        XCTAssertEqual(sealed?.path, "/System")
        XCTAssertEqual(sealed?.bytes, 80)
        XCTAssertEqual(sealed?.children.isEmpty, true, "密封块不可下钻 = 无子辈")
        XCTAssertFalse(map.children.contains { !$0.isSealed && $0.name == "System" }, "不可下钻的 System 原树不得残留")
        XCTAssertFalse(map.children.contains { $0.name == "Volumes" || $0.name == "Data" })
    }

    func testBuildRootKeepsTotalBytesAndName() {
        let tree = machineLikeTree()
        let map = SpaceMapTree.build(from: tree)
        XCTAssertEqual(map.bytes, tree.accountedBytes, "根字节 = 整卷实际占用(悬浮百分比分母)")
        XCTAssertEqual(map.name, "整卷")
        XCTAssertEqual(map.path, "/")
    }

    func testBuildSealsReadOnlyTopLevelDirsAndFoldsTheirChildren() {
        let bin = dir("bin", under: "/", bytes: 4, children: [
            dir("nested", under: "/bin", bytes: 4),
        ])
        let root = dir("/", under: "", bytes: 100, children: [
            bin,
            dir("usr", under: "/", bytes: 50, children: [
                dir("local", under: "/usr", bytes: 20),
            ]),
        ])
        let map = SpaceMapTree.build(from: root)

        let sealedBin = map.children.first { $0.name == "bin" }
        XCTAssertEqual(sealedBin?.isSealed, true, "/bin 在密封系统卷上")
        XCTAssertEqual(sealedBin?.children.isEmpty, true, "密封折叠 = 不暴露子辈")
        let usr = map.children.first { $0.name == "usr" }
        XCTAssertEqual(usr?.isSealed, false, "/usr 含 /usr/local(firmlink,用户空间),保持可下钻")
        XCTAssertEqual(usr?.children.first?.name, "local")
    }

    func testBuildDropsZeroByteDirsButKeepsPartialOnes() {
        let root = dir("/", under: "", bytes: 10, children: [
            dir("empty", under: "/"),
            dir("emptyPartial", under: "/", partial: true),
            dir("real", under: "/", bytes: 10),
        ])
        let map = SpaceMapTree.build(from: root)
        let names = map.children.map(\.name)
        XCTAssertFalse(names.contains("empty"), "零字节且非部分扫描 = 零弧,不进显示树")
        XCTAssertTrue(names.contains("emptyPartial"), "部分扫描如实保留(哪怕暂时零字节)")
    }

    func testBuildWithoutDataChainPassesThrough() {
        let root = dir("/", under: "", bytes: 40, children: [
            dir("Users", under: "/", bytes: 30),
            dir("opt", under: "/", bytes: 10),
        ])
        let map = SpaceMapTree.build(from: root)
        XCTAssertEqual(map.children.map(\.name), ["Users", "opt"])
        XCTAssertEqual(map.children.map(\.path), ["/Users", "/opt"])
    }

    // MARK: 方案 A:Data 根树 + 卷级密封注入

    func testBuildFromDataRootRemapsPathsAndInjectsSealedVolumes() {
        // 扫描根本身 = Data 卷:子目录剥前缀即规范路径;只读系统卷以卷级字节进密封块。
        let users = dir("Users", under: "/System/Volumes/Data", bytes: 200)
        let dataRoot = dir("Data", under: "/System/Volumes", children: [users])
        let map = SpaceMapTree.build(
            from: dataRoot,
            sealedVolumes: [
                SpaceMapVolumeSummary(label: "SSV", usedBytes: 80),
                SpaceMapVolumeSummary(label: "Preboot", usedBytes: 20),
            ]
        )
        XCTAssertEqual(map.name, "整卷")
        XCTAssertEqual(map.path, "/")
        XCTAssertEqual(map.bytes, 300, "根账 = 文件级 200 + 卷级密封 100")
        let sealed = map.children.first { $0.isSealed }
        XCTAssertEqual(sealed?.name, "系统(密封)")
        XCTAssertEqual(sealed?.bytes, 100, "卷级摘要合并为单块")
        XCTAssertEqual(map.children.first { $0.name == "Users" }?.path, "/Users", "规范路径,无需提升")
    }

    func testBuildFromDataRootWithoutSummariesOmitsSealedBlock() {
        let dataRoot = dir("Data", under: "/System/Volumes", children: [
            dir("Users", under: "/System/Volumes/Data", bytes: 50),
        ])
        let map = SpaceMapTree.build(from: dataRoot, sealedVolumes: [])
        XCTAssertFalse(map.children.contains { $0.isSealed }, "没有卷级数据就不出密封块,不伪造")
        XCTAssertEqual(map.bytes, 50)
    }

    // MARK: 导航

    func testDescendantAndBreadcrumbWalkCanonicalPaths() {
        let map = SpaceMapTree.build(from: machineLikeTree())
        let home = map.descendant(atPath: "/Users/aa00930")
        XCTAssertEqual(home?.bytes, 180)
        XCTAssertNil(map.descendant(atPath: "/System/Volumes/Data/Users"), "提升后只认规范路径")

        let crumbs = SpaceMapNode.breadcrumb(to: "/Users/aa00930", in: map)
        XCTAssertEqual(crumbs?.map(\.name), ["整卷", "Users", "aa00930"], "面包屑逐级可跳的依据")
        XCTAssertNil(SpaceMapNode.breadcrumb(to: "/nope", in: map))
    }

    // MARK: SunburstLayout——弧几何

    private func layoutRoot() -> SpaceMapNode {
        SpaceMapNode(name: "整卷", path: "/", bytes: 1000, children: [
            SpaceMapNode(name: "a", path: "/a", bytes: 800),
            SpaceMapNode(name: "b", path: "/b", bytes: 200),
        ])
    }

    func testLayoutSpansAreProportionalAndContiguous() {
        let arcs = SunburstLayout.layout(root: layoutRoot())
        let ring1 = arcs.filter { $0.ring == 1 }
        XCTAssertEqual(ring1.count, 2)
        XCTAssertEqual(ring1[0].node.name, "a", "内环按大到小")

        let a = ring1[0], b = ring1[1]
        XCTAssertEqual(a.start, -.pi / 2, accuracy: 1e-9, "0 弧度 = 正上")
        XCTAssertEqual(a.span, 2 * .pi * 0.8, accuracy: 1e-9)
        XCTAssertEqual(b.span, 2 * .pi * 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.start, a.end, accuracy: 1e-9, "弧段首尾相接")
    }

    func testLayoutVolumeFractionUsesWholeVolumeNotRingTotal() {
        // 子辈和 900 < 根 1000(差额 = 根层文件):环内归一化用 900,悬浮占比用 1000。
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 1000, children: [
            SpaceMapNode(name: "a", path: "/a", bytes: 300),
            SpaceMapNode(name: "b", path: "/b", bytes: 600),
        ])
        let a = SunburstLayout.layout(root: root).first { $0.ring == 1 && $0.node.name == "a" }
        XCTAssertEqual(a?.volumeFraction ?? 0, 0.3, accuracy: 1e-9, "占比 = 大小 / 整卷")
        XCTAssertEqual(a?.span ?? 0, 2 * .pi / 3, accuracy: 1e-9, "弧宽 = 份额 / 环内总和")
    }

    func testLayoutLeafAndSealedExtendIntoOuterRing() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 100, children: [
            SpaceMapNode(name: "leaf", path: "/leaf", bytes: 40),
            SpaceMapNode(name: "sys", path: "/sys", bytes: 60, isSealed: true, children: [
                SpaceMapNode(name: "hidden", path: "/sys/hidden", bytes: 60),
            ]),
        ])
        let arcs = SunburstLayout.layout(root: root)

        let leaf1 = arcs.first { $0.ring == 1 && $0.node.name == "leaf" }
        let leaf2 = arcs.first { $0.ring == 2 && $0.node.name == "leaf" }
        XCTAssertEqual(leaf2?.start, leaf1?.start, "叶子延伸占满外环同色")
        XCTAssertEqual(leaf2?.span, leaf1?.span)

        // 密封块:内外两弧、绝不展开孙辈
        XCTAssertEqual(arcs.filter { $0.node.name == "sys" }.count, 2)
        XCTAssertFalse(arcs.contains { $0.node.name == "hidden" }, "密封折叠 = 孙辈不上外环")
    }

    func testLayoutRing2ProportionalWithinParentSpan() {
        let parent = SpaceMapNode(name: "p", path: "/p", bytes: 100, children: [
            SpaceMapNode(name: "c1", path: "/p/c1", bytes: 75),
            SpaceMapNode(name: "c2", path: "/p/c2", bytes: 25),
        ])
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 100, children: [parent])
        let arcs = SunburstLayout.layout(root: root)

        let p = arcs.first { $0.ring == 1 && $0.node.name == "p" }
        let c1 = arcs.first { $0.ring == 2 && $0.node.name == "c1" }
        let c2 = arcs.first { $0.ring == 2 && $0.node.name == "c2" }
        XCTAssertEqual(c1?.span ?? 0, (p?.span ?? 0) * 0.75, accuracy: 1e-9, "外环份额 = 孙辈字节 / 父字节 × 父弧宽")
        XCTAssertEqual(c2?.start ?? 0, c1?.end ?? 0, accuracy: 1e-9)
    }

    func testLayoutMergesTinyTailIntoAggregate() {
        let children = (0 ..< 5).map { SpaceMapNode(name: "big\($0)", path: "/big\($0)", bytes: 100) }
            + (0 ..< 4).map { SpaceMapNode(name: "tiny\($0)", path: "/tiny\($0)", bytes: 1) }
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 504, children: children)
        let ring1 = SunburstLayout.layout(root: root, minArcFraction: 0.01).filter { $0.ring == 1 }

        let others = ring1.first { $0.node.isAggregate }
        XCTAssertEqual(others?.node.name, "其他")
        XCTAssertEqual(others?.node.bytes, 4, "被并入的字节一分不差")
        XCTAssertEqual(others?.node.mergedCount, 4, "合并项数如实(悬浮展示用)")
        XCTAssertFalse(ring1.contains { $0.node.name == "tiny2" }, "低于阈值的尾部不再单独成弧")
        XCTAssertEqual(ring1.count, 6, "5 个大头 + 1 个「其他」")
    }

    func testLayoutCapsChildCount() {
        let children = (0 ..< 15).map { SpaceMapNode(name: "d\($0)", path: "/d\($0)", bytes: 10) }
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 150, children: children)
        let ring1 = SunburstLayout.layout(root: root, maxChildren: 12).filter { $0.ring == 1 }
        XCTAssertEqual(ring1.count, 13, "12 个 + 「其他」")
        XCTAssertEqual(ring1.last?.node.isAggregate, true)
        XCTAssertEqual(ring1.last?.node.bytes, 30)
    }

    func testLayoutSingleChildClampsFullCircle() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 100, children: [
            SpaceMapNode(name: "only", path: "/only", bytes: 100),
        ])
        let ring1 = SunburstLayout.layout(root: root).filter { $0.ring == 1 }
        XCTAssertEqual(ring1.count, 1)
        XCTAssertEqual(ring1[0].span, 2 * .pi - 0.001, accuracy: 1e-9, "满圆留细缝(Path 满圆画不出)")
    }

    func testLayoutEmptyRootsReturnNoArcs() {
        XCTAssertTrue(SunburstLayout.layout(root: SpaceMapNode(name: "整卷", path: "/", bytes: 0)).isEmpty)
        XCTAssertTrue(
            SunburstLayout
                .layout(root: SpaceMapNode(name: "整卷", path: "/", bytes: 10, children: [])).isEmpty
        )
    }

    func testLabelReadabilityAndFlipRules() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 100, children: [
            SpaceMapNode(name: "wide", path: "/wide", bytes: 98),
            SpaceMapNode(name: "thin", path: "/thin", bytes: 2),
        ])
        let ring1 = SunburstLayout.layout(root: root).filter { $0.ring == 1 }
        XCTAssertTrue(ring1[0].isLabelReadable, "宽弧放得下名字")
        XCTAssertFalse(ring1[1].isLabelReadable, "窄弧(2% ≈ 0.126 rad)不放名字(阈值 0.23 rad)")
        // wide 覆盖右半圆,中点 cos > 0 → 文字不翻;
        // thin 的中点在左半圆(cos < 0)→ 翻转 180° 保证外向可读。
        XCTAssertEqual(ring1[0].flipsLabel, false)
        XCTAssertEqual(ring1[1].flipsLabel, true)
    }

    /// 命中判定 = atan2 标准极角直接比对(space-map-forms/05):弧的 start/end 就是
    /// 标准极角,视图层旧命中多加 π/2「换算」,悬停恒偏 90°、落到顺时针下一段。
    func testArcContainsStandardPolarAngle() {
        let root = SpaceMapNode(name: "整卷", path: "/", bytes: 100, children: [
            SpaceMapNode(name: "a", path: "/a", bytes: 40),
            SpaceMapNode(name: "b", path: "/b", bytes: 30),
            SpaceMapNode(name: "c", path: "/c", bytes: 20),
            SpaceMapNode(name: "d", path: "/d", bytes: 10),
        ])
        let ring1 = SunburstLayout.layout(root: root).filter { $0.ring == 1 }
        // 布局从 -π/2(正上)顺时针:a = [-0.5π, 0.3π)、b = [0.3π, 0.9π)、
        // c = [0.9π, 1.3π)、d = [1.3π, 1.5π)——d 是正上偏左的收尾窄段。
        XCTAssertTrue(ring1[0].contains(angle: -.pi / 4), "右上象限中点命中 a")
        XCTAssertTrue(ring1[0].contains(angle: 0.2 * .pi), "a 尾段——旧 +π/2 换算会错判给 b")
        XCTAssertFalse(ring1[1].contains(angle: 0.2 * .pi), "a 上的点不得命中顺时针下一段")
        XCTAssertTrue(ring1[1].contains(angle: .pi / 2), "正下方命中 b")
        XCTAssertTrue(ring1[2].contains(angle: .pi), "正左命中 c")
        // 同一物理位置的不同 2π 周期表示:正上偏左的标准角为负(atan2 口径 ≈ -0.53π),
        // d 的区间却是 [1.3π, 1.5π)——周期折叠必须认出它们是同一点。
        XCTAssertTrue(ring1[3].contains(angle: -.pi / 2 - 0.1), "正上偏左(atan2 负角)命中 d")
        XCTAssertTrue(ring1[3].contains(angle: 1.4 * .pi), "同一点的正角表示")
        XCTAssertFalse(ring1[0].contains(angle: .pi), "正左不属于 a")
    }
}
