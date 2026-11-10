import Foundation

// MARK: - Ollama 内容寻址记账(p6-cleaner/02)

//
// Ollama 的模型库是内容寻址存储:manifests/<registry>/<namespace>/<model>/<tag>
// 是 JSON 清单,真正的权重在 blobs/sha256-<hex>(两个模型共享一层 = 共享同一个
// blob 文件)。布局实测见 docs/probes/13(真机 manifest 样本;tag 是路径末段,
// 冒号只存在于 API 层的 model:tag 写法,文件名里没有)。
//
// 记账口径(p6-cleaner/02 拍板):manifest 解析只决定「哪些文件计入」——
// 计入集 = 全部清单引用的 config+layers digest 的并集(去重)+ manifest 文件
// 本身;字节一律取扫描树节点(GLOSSARY 实际占用口径,克隆 / 硬链接不重复计),
// 本类型不另立口径。无主 blob(拉取中断的残留)不计入:删除单元的数字只担保
// 模型本体,不为来源不明的文件背书。
// 失败方向:manifest 缺失 / 损坏 / 零有效清单 → 整目录口径兜底并如实标注
// (候选的 accountingNote)。宁可把数字说全,不按残缺引用集给小数字——那会让
// 用户以为删了没多少可回收。

/// Ollama 模型库的内容寻址记账(纯值;IO 只有注入的 manifest 读取器)。
public enum OllamaStoreAccounting {
    /// 对应 `JunkRuleTable.aiModelRules` 里的 ai.ollama 规则(单一出处,规则表引用它)。
    public static let ruleID = "ai.ollama"

    /// 兜底标注(行副标如实说明口径;措辞不区分「缺失 / 损坏 / 旧缓存无文件明细」
    /// ——对用户这三者是一回事:清单没能用上)。
    public static let fallbackNote = "模型清单不可用,按整目录计"

    /// 扫描引擎需要为其保留文件节点的路径前缀(否则 blob / manifest 只是聚合字节,
    /// 记账无从取数)。CleanerModel 建扫描选项时从这里取,规则改存储位只动一处。
    public static func retainedFilePrefixes(home: String) -> [String] {
        [PathNormalization.normalize(home) + "/.ollama/models"]
    }

    /// 对清单里的 ai.ollama 候选重算计入口径;其余候选原样透传。
    /// - Parameters:
    ///   - candidates: 匹配器产出(候选必须在树上——bytes 本来就来自节点)。
    ///   - trees: 扫描树(文件节点须在场:调用方扫描时带 `retainedFilePrefixes`;
    ///     旧缓存 / 未带前缀的树会走兜底,数字退整目录口径,不会错小)。
    ///   - readManifest: 读一个 manifest 文件的 UTF-8 内容(生产 Live FileManager,
    ///     测试注入字典)。nil = 读不到,按损坏处理。
    public static func applied(
        to candidates: [JunkCandidate],
        in trees: [SpaceNode],
        readManifest: (String) -> String?
    ) -> [JunkCandidate] {
        candidates.map { candidate in
            guard candidate.ruleID == ruleID,
                  let store = SpaceNode.locate(path: candidate.path, in: trees)
            else { return candidate }
            return refined(candidate: candidate, store: store, readManifest: readManifest)
        }
    }

    // MARK: - 单个候选的重算

    private static func refined(
        candidate: JunkCandidate,
        store: SpaceNode,
        readManifest: (String) -> String?
    ) -> JunkCandidate {
        guard let manifests = store.children.first(where: { $0.name == "manifests" && $0.kind == .directory }) else {
            return candidate.fallback()
        }
        // manifest 清单文件:DFS 收集 manifests 子树下的全部文件(层级不拘——
        // registry/namespace/model 深度随 registry 而变,按「子树内的文件」收)。
        let manifestFiles = fileNodes(under: manifests).sorted { $0.path < $1.path }
        guard !manifestFiles.isEmpty else { return candidate.fallback() }

        var counted = Set<String>()
        for file in manifestFiles {
            guard let content = readManifest(file.path),
                  let digests = Self.digests(inManifest: content),
                  !digests.isEmpty
            else {
                // 任一清单读不了 / 不是字典 / 引用零层 → 引用集不完整,整目录兜底。
                return candidate.fallback()
            }
            counted.formUnion(digests)
        }

        var bytes = manifestFiles.reduce(Int64(0)) { $0 + $1.accountedBytes }
        var fileCount = manifestFiles.count
        var allReclaimable = manifestFiles.allSatisfy(\.allReclaimableAccounting)
        if let blobs = store.children.first(where: { $0.name == "blobs" && $0.kind == .directory }) {
            for blob in blobs.children where blob.kind == .file {
                guard counted.contains(Self.digest(ofBlobFileName: blob.name)) else { continue }
                bytes += blob.accountedBytes
                fileCount += 1
                allReclaimable = allReclaimable && blob.allReclaimableAccounting
            }
        }
        return candidate.withAccounting(bytes: bytes, fileCount: fileCount, allReclaimable: allReclaimable)
    }

    /// 子树内全部文件节点(不进目录以外的形态;清单树里出现符号链接等不跟随)。
    private static func fileNodes(under root: SpaceNode) -> [SpaceNode] {
        var out: [SpaceNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            for child in node.children {
                if child.kind == .file {
                    out.append(child)
                } else if child.kind == .directory {
                    stack.append(child)
                }
            }
        }
        return out
    }

    /// manifest JSON → config + layers 的 digest 集(docker distribution v2 形状,
    /// 探针 13 实测)。非字典 / 解析失败 / 零引用 → nil。
    private static func digests(inManifest content: String) -> Set<String>? {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let manifest = object as? [String: Any]
        else { return nil }
        var digests = Set<String>()
        if let config = manifest["config"] as? [String: Any],
           let digest = config["digest"] as? String, !digest.isEmpty {
            digests.insert(digest)
        }
        if let layers = manifest["layers"] as? [[String: Any]] {
            for layer in layers {
                if let digest = layer["digest"] as? String, !digest.isEmpty {
                    digests.insert(digest)
                }
            }
        }
        return digests.isEmpty ? nil : digests
    }

    /// digest("sha256:<hex>") ↔ blob 文件名("sha256-<hex>"):冒号转连字符
    /// (探针 13 同款换算)。非 sha256 前缀的名字原样返回——与 digest 集合自然
    /// 对不上,无害跳过。
    private static func digest(ofBlobFileName name: String) -> String {
        guard name.hasPrefix("sha256-") else { return name }
        return "sha256:" + name.dropFirst("sha256-".count)
    }
}

// MARK: - 候选的口径改写(内部便捷)

extension JunkCandidate {
    /// 整目录兜底:字节 / 计数不动(本来就是节点聚合值),只补标注。
    func fallback() -> JunkCandidate {
        withAccounting(
            bytes: bytes,
            fileCount: fileCount,
            allReclaimable: allReclaimableAccounting,
            note: OllamaStoreAccounting.fallbackNote
        )
    }

    func withAccounting(
        bytes: Int64,
        fileCount: Int,
        allReclaimable: Bool,
        note: String? = nil
    ) -> JunkCandidate {
        JunkCandidate(
            ruleID: ruleID,
            group: group,
            title: title,
            path: path,
            tier: tier,
            bytes: bytes,
            fileCount: fileCount,
            isPartial: isPartial,
            allReclaimableAccounting: allReclaimable,
            rationale: rationale,
            symbolName: symbolName,
            projectName: projectName,
            newestChangeEpoch: newestChangeEpoch,
            modifiedAtScan: modifiedAtScan,
            accountingNote: note
        )
    }
}
