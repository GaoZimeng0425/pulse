import Foundation

// MARK: - 在用保护(p4-cleaner/05):活动推导 + 判定(纯值,零 IO)

//
// 三路判定(spec 在用保护):①进程 cwd / argv 命中 ②构建进程特征 ③git 活动。
// 输入 = 采样快照的三元组投影(可执行路径 / cwd / argv)——心跳本就每轮在采,
// 这里只是换视角看同一份数据,零新采集。口径两条钉死:
//   · **活动落在候选之内**才保护:终端 cd 在项目外(哪怕家目录)不保护任何项目;
//   · 判定永不缓存:每次调用重新推导,删除前重查(spec 用户故事 11)。

/// 一个进程的活动三元组投影(在用判定的全部输入)。
public struct CleanActivitySample: Sendable, Equatable {
    public var executablePath: String?
    public var cwd: String?
    public var argv: [String]

    public init(executablePath: String?, cwd: String?, argv: [String]) {
        self.executablePath = executablePath
        self.cwd = cwd
        self.argv = argv
    }
}

/// 三元组 → 活动条目(带原因)。Live 活动源只是它的搬运工。
public enum CleanActivityDerivation {
    /// 终端壳(可执行名):cwd 在哪,哪就有「终端驻留」。
    static let shellExecutables: Set<String> = ["zsh", "bash", "fish", "nu", "sh", "csh", "tcsh"]
    /// 构建工具(可执行名):编译器 / 包管理器 / 任务运行器(purge-app 同族口径)。
    static let buildExecutables: Set<String> = [
        "swiftc", "swift-frontend", "swift-build", "swift-run", "swift-package", "swift-test",
        "xcodebuild", "xctest", "cargo", "rustc", "npm", "pnpm", "yarn", "bun", "node",
        "pod", "cocoapods", "gradle", "mvn", "make", "cmake", "ninja", "go", "dotnet",
        "esbuild", "tsc", "webpack", "vite", "turbo",
    ]
    static let gitExecutables: Set<String> = ["git", "gh"]
    /// AI 服务进程(可执行名,p6-cleaner/02 第四路):在场即 AI 组整组在用。
    /// p_comm 不在三元组里,可执行路径基名是等价信号(proc_pidpath);受限时
    /// argv[0] 基名兜底。子命令不区分(serve / run / pull 都在动模型库,都该保护)。
    public static let aiServiceExecutables: Set<String> = ["ollama"]

    /// - Parameters:
    ///   - home: 用户家目录。AI 服务标记(第四路)需要它做锚——服务进程的
    ///     cwd/argv 里通常没有任何用户路径(launchd 直起,cwd = /),路径前缀
    ///     匹配表达不了「AI 组在用」;标记挂在 home 上,消费按组判定
    ///     (见 `CleanInUse.reasons(for:entries:)`)。对前缀判定它是惰性条目:
    ///     祖先方向本就不匹配,不会误伤其他组。nil = 不判第四路(卸载器等
    ///     既有调用方行为不变)。
    /// - Returns: 去重合并后的活动条目(同路径多进程的原因取并集)。
    /// 只发两类:①已分类进程(终端 / 构建 / git)的 cwd;②argv 里指向用户域
    /// (/Users 下)的绝对路径引用。未分类进程的 cwd 不发——守护进程的家目录
    /// cwd 不该保护整个家目录下的项目。
    public static func entries(
        from samples: [CleanActivitySample],
        home: String? = nil
    ) -> [CleanActivityEntry] {
        var byPath: [String: CleanActivityReason] = [:]

        func add(_ path: String, _ reason: CleanActivityReason) {
            byPath[path, default: []].formUnion(reason)
        }

        for sample in samples {
            let base = sample.executablePath.map { ($0 as NSString).lastPathComponent }
            var reason: CleanActivityReason = []
            if let base {
                if shellExecutables.contains(base) {
                    reason.insert(.terminal)
                } else if buildExecutables.contains(base) {
                    reason.insert(.build)
                } else if gitExecutables.contains(base) {
                    reason.insert(.git)
                }
            }
            // 未分类进程:cwd 不发(见函数注释),但 argv 引用仍然算数。
            if !reason.isEmpty, let cwd = normalizedAbsolute(sample.cwd) {
                add(cwd, reason)
            }
            for token in sample.argv {
                guard token.hasPrefix("/Users/"), token.count > "/Users".count else { continue }
                add(token, .referenced)
            }
            // 第四路(p6-cleaner/02):AI 服务进程在场 → home 锚上的组作用域标记。
            if let home, isAIServiceProcess(sample) {
                add(normalizedAbsolute(home) ?? home, .aiService)
            }
        }
        return byPath
            .map { CleanActivityEntry(path: $0.key, reasons: $0.value) }
            .sorted { $0.path < $1.path }
    }

    /// 可执行路径基名命中,或(路径受限时)argv[0] 基名命中。
    static func isAIServiceProcess(_ sample: CleanActivitySample) -> Bool {
        if let base = sample.executablePath.map({ ($0 as NSString).lastPathComponent }),
           aiServiceExecutables.contains(base) {
            return true
        }
        if let first = sample.argv.first.map({ ($0 as NSString).lastPathComponent }) {
            return aiServiceExecutables.contains(first)
        }
        return false
    }

    private static func normalizedAbsolute(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        var p = path
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p.isEmpty ? nil : p
    }
}

/// 在用判定的消费面:给定候选的保护路径,活动条目里有没有落进来的。
public enum CleanInUse {
    /// 候选的保护路径(mcp-clean/01 提公共:界面组选与 MCP 求交同口径单出处)——
    /// 项目产物按**项目目录**判(产物直接父目录),其余按候选自身路径判。
    public static func protectionPath(for candidate: JunkCandidate) -> String {
        candidate.group == .projectArtifacts
            ? (candidate.path as NSString).deletingLastPathComponent
            : candidate.path
    }

    /// 项目产物传**项目目录**(活动在项目根 = 保护整个项目的全部产物);
    /// 其他候选传自身路径(活动落在候选之内 = 在用)。
    /// - Returns: 命中的原因并集;无活动覆盖返回 nil(不在用)。
    public static func reasons(protectingPath path: String, entries: [CleanActivityEntry]) -> CleanActivityReason? {
        var merged: CleanActivityReason = []
        let base = PathNormalization.normalize(path)
        for entry in entries {
            let target = entry.path
            if target == base || target.hasPrefix(base + "/") {
                merged.formUnion(entry.reasons)
            }
        }
        return merged.isEmpty ? nil : merged
    }

    /// 组感知判定(p6-cleaner/02 起清单侧走这里;MCP 侧沿用上面的路径版,
    /// AI 候选恒「先检查」永不进 MCP,两版口径不漂移):路径前缀判定之上,
    /// AI 组额外吃 `.aiService` 标记(条目挂在 home 锚上,路径不参与匹配——
    /// ollama 服务进程的 cwd/argv 里没有任何用户路径,前缀匹配表达不了)。
    /// - Returns: 命中的原因并集;无活动覆盖返回 nil(不在用)。
    public static func reasons(
        for candidate: JunkCandidate,
        entries: [CleanActivityEntry]
    ) -> CleanActivityReason? {
        var merged = reasons(protectingPath: protectionPath(for: candidate), entries: entries) ?? []
        if candidate.group == .aiModels,
           entries.contains(where: { $0.reasons.contains(.aiService) }) {
            merged.insert(.aiService)
        }
        return merged.isEmpty ? nil : merged
    }
}
