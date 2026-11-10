@testable import PulseCore
import PulseCoreTestSupport
import XCTest

/// AI 模型域(p6-cleaner/02):Ollama 内容寻址真实可回收 + 在用保护第四路。
/// 口径:manifest 解析只决定「哪些文件计入」,字节一律取扫描树节点(实际占用
/// 口径不变);manifest 不可用 → 整目录兜底并如实标注。全部合成夹具,零真盘。
final class AIModelDomainTests: XCTestCase {
    private let home = "/Users/test"
    private let engine = SpaceScanEngine()
    private let store = "/Users/test/.ollama/models"

    private func scanHome(
        _ directories: [String: Int64],
        patch: ((inout [String: FakeCleanDirectoryEnumerator.Listing]) -> Void)? = nil,
        retainedFilePrefixes: [String] = []
    ) async -> [SpaceNode] {
        var listings = CleanFixture.homeListings(home: home, directories: directories)
        patch?(&listings)
        let fs = FakeCleanDirectoryEnumerator(listings: listings)
        return await engine.scan(
            SpaceScanOptions(
                roots: [home],
                retainFileNodes: false,
                retainedFilePrefixes: retainedFilePrefixes
            ),
            using: fs
        ).trees
    }

    // MARK: 内容寻址记账

    /// 两模型共享一层:可回收 = 私有层之和 + 共享层只计一次;无主 blob(拉取残留)
    /// 不计入。manifest 文件本身计入。
    func testSharedBlobCountedOnceAndOrphanExcluded() async {
        let trees = await scanHome(
            [
                ".ollama/models/blobs": 0,
                ".ollama/models/manifests/registry.ollama.ai/library/llama3": 0,
                ".ollama/models/manifests/registry.ollama.ai/library/mistral": 0,
            ],
            patch: { listings in
                listings[self.store + "/blobs"] = .entries([
                    CleanFixture.file("sha256-a1", allocated: 1000, reclaimable: 1000),
                    CleanFixture.file("sha256-b1", allocated: 2000, reclaimable: 2000),
                    CleanFixture.file("sha256-shared", allocated: 4000, reclaimable: 4000),
                    CleanFixture.file("sha256-orphan", allocated: 999, reclaimable: 999),
                ])
                listings[self.store + "/manifests/registry.ollama.ai/library/llama3"] = .entries([
                    CleanFixture.file("latest", allocated: 100, reclaimable: 100),
                ])
                listings[self.store + "/manifests/registry.ollama.ai/library/mistral"] = .entries([
                    CleanFixture.file("latest", allocated: 100, reclaimable: 100),
                ])
            },
            retainedFilePrefixes: [store]
        )
        let manifests = [
            store + "/manifests/registry.ollama.ai/library/llama3/latest":
                #"{"config":{"digest":"sha256:a1"},"layers":[{"digest":"sha256:shared"},{"digest":"sha256:a1"}]}"#,
            store + "/manifests/registry.ollama.ai/library/mistral/latest":
                #"{"config":{"digest":"sha256:b1"},"layers":[{"digest":"sha256:shared"}]}"#,
        ]
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        let raw = candidates.first { $0.ruleID == "ai.ollama" }
        XCTAssertEqual(raw?.bytes, 8199, "重算前 = 整目录字节(含无主 blob)")
        XCTAssertEqual(raw?.accountingNote, nil)

        let refined = OllamaStoreAccounting.applied(to: candidates, in: trees) { manifests[$0] }
        let ollama = refined.first { $0.ruleID == "ai.ollama" }

        // 计入 = a1(1000)+ b1(2000)+ shared(4000,两个清单引用只计一次)+ 两个 manifest(100×2);
        // 无主 blob(999)不计入。
        XCTAssertEqual(ollama?.bytes, 7200, "共享层只计一次,无主 blob 不计入")
        XCTAssertEqual(ollama?.fileCount, 5)
        XCTAssertNil(ollama?.accountingNote, "manifest 口径无需兜底标注")
        XCTAssertTrue(ollama?.allReclaimableAccounting == true)
        // 其余候选原样透传。
        XCTAssertEqual(
            refined.filter { $0.ruleID != "ai.ollama" }.map(\.bytes),
            candidates.filter { $0.ruleID != "ai.ollama" }.map(\.bytes)
        )
    }

    /// 零 manifest / 清单损坏 / 读不到 → 整目录口径兜底 + 如实标注。
    func testFallbackToWholeDirectoryWhenManifestsUnusable() async {
        // ① 有 blobs 无 manifests 树 → 兜底。
        let noManifests = await scanHome(
            [".ollama/models/blobs": 0],
            patch: { listings in
                listings[self.store + "/blobs"] = .entries([
                    CleanFixture.file("sha256-a1", allocated: 1000, reclaimable: 1000),
                ])
            },
            retainedFilePrefixes: [store]
        )
        assertFallback(
            trees: noManifests,
            reader: { _ in #"{"config":{"digest":"sha256:a1"},"layers":[]}"# },
            expectedBytes: 1000
        )

        // ② manifest 文件在但 JSON 损坏 → 兜底(引用集不完整时宁可整目录)。
        let corrupt = await scanHome(
            [".ollama/models/manifests/registry.ollama.ai/library/llama3": 0],
            patch: { listings in
                listings[self.store + "/manifests/registry.ollama.ai/library/llama3"] = .entries([
                    CleanFixture.file("latest", allocated: 100, reclaimable: 100),
                ])
            },
            retainedFilePrefixes: [store]
        )
        assertFallback(trees: corrupt, reader: { _ in #"{"broken"# }, expectedBytes: 100)

        // ③ manifest 读不到(reader 回 nil)→ 兜底。
        assertFallback(trees: corrupt, reader: { _ in nil }, expectedBytes: 100)

        // ④ manifest 合法但引用零层(零有效清单)→ 兜底。
        assertFallback(
            trees: corrupt,
            reader: { _ in #"{"schemaVersion":2}"# },
            expectedBytes: 100
        )
    }

    /// 没带文件保留前缀的树(旧缓存 / 直接跑匹配器):manifest 文件不在树里 → 兜底,
    /// 数字退整目录口径——绝不按「零引用」给个小数字。
    func testLegacyTreeWithoutFileNodesFallsBack() async {
        let trees = await scanHome([".ollama/models": 5000])
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        let refined = OllamaStoreAccounting.applied(to: candidates, in: trees) { _ in
            #"{"config":{"digest":"sha256:a1"},"layers":[]}"#
        }
        let ollama = refined.first { $0.ruleID == "ai.ollama" }
        XCTAssertEqual(ollama?.bytes, 5000, "兜底 = 整目录,不因缺文件明细而缩水")
        XCTAssertEqual(ollama?.accountingNote, OllamaStoreAccounting.fallbackNote)
    }

    private func assertFallback(
        trees: [SpaceNode],
        reader: @escaping (String) -> String?,
        expectedBytes: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidates = JunkMatcher.candidates(in: trees, home: home)
        let refined = OllamaStoreAccounting.applied(to: candidates, in: trees, readManifest: reader)
        let ollama = refined.first { $0.ruleID == "ai.ollama" }
        XCTAssertEqual(ollama?.bytes, expectedBytes, file: file, line: line)
        XCTAssertEqual(ollama?.accountingNote, OllamaStoreAccounting.fallbackNote, file: file, line: line)
    }

    // MARK: 扫描引擎文件保留(p6-cleaner/02:Ollama 记账需要文件节点)

    /// retainedFilePrefixes 只给前缀下的文件留节点;其余子树维持「只留目录」。
    func testRetainedFilePrefixesKeepFileNodesOnlyUnderPrefix() async {
        let trees = await scanHome(
            [
                ".ollama/models/blobs": 0,
                ".lmstudio/models": 3000,
            ],
            patch: { listings in
                listings[self.store + "/blobs"] = .entries([
                    CleanFixture.file("sha256-a1", allocated: 1000, reclaimable: 1000),
                ])
            },
            retainedFilePrefixes: [store]
        )
        let blobs = trees.first?.descendant(atPath: store + "/blobs")
        XCTAssertEqual(blobs?.children.map(\.name), ["sha256-a1"], "前缀下文件成为节点")
        XCTAssertEqual(blobs?.children.first?.kind, .file)

        let lmstudio = trees.first?.descendant(atPath: "/Users/test/.lmstudio/models")
        XCTAssertEqual(lmstudio?.children.isEmpty, true, "前缀外维持只留目录(payload.bin 只进聚合)")
        XCTAssertEqual(lmstudio?.accountedBytes, 3000, "聚合字节不受保留开关影响")
    }

    // MARK: 在用保护第四路(ollama 服务进程)

    func testOllamaServiceProcessMarksAIGroupInUse() {
        // launchd 直起的服务:cwd = /、argv 无用户路径——路径前缀匹配天然表达不了,
        // 推导层以 home 为锚挂 .aiService 标记(对前缀匹配是惰性条目,不误伤他组)。
        let entries = CleanActivityDerivation.entries(
            from: [
                CleanActivitySample(
                    executablePath: "/opt/homebrew/opt/ollama/bin/ollama",
                    cwd: "/",
                    argv: ["ollama", "serve"]
                ),
                CleanActivitySample(executablePath: "/bin/zsh", cwd: "/Users/test/code/pulse", argv: []),
            ],
            home: "/Users/test"
        )
        XCTAssertTrue(
            entries.contains { $0.path == "/Users/test" && $0.reasons == [.aiService] },
            "服务进程在场 → home 锚上的 .aiService 标记"
        )
        XCTAssertTrue(entries.contains { $0.path == "/Users/test/code/pulse" && $0.reasons == [.terminal] })

        // 可执行路径拿不到(受限)时 argv[0] 兜底。
        let argvOnly = CleanActivityDerivation.entries(
            from: [CleanActivitySample(executablePath: nil, cwd: nil, argv: ["/opt/homebrew/bin/ollama", "serve"])],
            home: "/Users/test"
        )
        XCTAssertTrue(argvOnly.contains { $0.path == "/Users/test" && $0.reasons == [.aiService] })

        // 消费面:AI 组候选在用;他组候选不受标记影响(组作用域,不参与路径匹配)。
        let ai = candidate(group: .aiModels, path: "/Users/test/.ollama/models")
        let tool = candidate(group: .globalToolCache, path: "/Users/test/.cargo/registry")
        XCTAssertEqual(CleanInUse.reasons(for: ai, entries: entries), [.aiService])
        XCTAssertNil(CleanInUse.reasons(for: tool, entries: entries), "标记不越组")
        XCTAssertNil(
            CleanInUse.reasons(protectingPath: tool.path, entries: entries),
            "home 锚条目对路径前缀判定保持惰性(祖先方向本就不匹配)"
        )

        // 服务不在场(AI 组 + 家目录锚上无任何条目)→ 不在用。
        let quiet = CleanActivityDerivation.entries(
            from: [CleanActivitySample(executablePath: "/bin/zsh", cwd: "/Users/test/code/pulse", argv: [])],
            home: "/Users/test"
        )
        XCTAssertNil(CleanInUse.reasons(for: ai, entries: quiet))
        // 家目录锚上有终端活动但无服务 → AI 组不在用(不因祖先活动误伤)。
        let shellAtHome = CleanActivityDerivation.entries(
            from: [CleanActivitySample(executablePath: "/bin/zsh", cwd: "/Users/test", argv: [])],
            home: "/Users/test"
        )
        XCTAssertNil(CleanInUse.reasons(for: ai, entries: shellAtHome))
    }

    /// 活动推导不传 home(卸载器等既有调用方)→ 不发 .aiService 标记,行为不变。
    func testDerivationWithoutHomeEmitsNoServiceMarker() {
        let entries = CleanActivityDerivation.entries(
            from: [CleanActivitySample(executablePath: "/opt/homebrew/bin/ollama", cwd: "/", argv: [])]
        )
        XCTAssertFalse(entries.contains { $0.reasons.contains(.aiService) })
    }

    /// AI 候选既有普通路径活动又有服务标记 → 原因并集,UI 拼人话。
    func testAIReasonsMergeWithReferenced() {
        var entries = CleanActivityDerivation.entries(
            from: [CleanActivitySample(executablePath: "/opt/homebrew/bin/ollama", cwd: "/", argv: [])],
            home: "/Users/test"
        )
        entries.append(CleanActivityEntry(path: "/Users/test/.ollama/models/blobs/x", reasons: [.referenced]))
        let ai = candidate(group: .aiModels, path: "/Users/test/.ollama/models")
        XCTAssertEqual(CleanInUse.reasons(for: ai, entries: entries), [.referenced, .aiService])
        XCTAssertEqual(
            CleanActivityReason([.referenced, .aiService]).title,
            "进程引用其路径与AI 服务"
        )
    }

    private func candidate(group: JunkGroup, path: String) -> JunkCandidate {
        JunkCandidate(
            ruleID: "test",
            group: group,
            title: "t",
            path: path,
            tier: .checkFirst,
            bytes: 1,
            fileCount: 1,
            isPartial: false,
            allReclaimableAccounting: true,
            rationale: "",
            symbolName: "circle"
        )
    }
}
