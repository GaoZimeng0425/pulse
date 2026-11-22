import Foundation

// 会话工作目录的 git 状态(工单 agent-git-status/01):分支名 + 有无未提交改动,
// 智能体页会话卡的分支 chip 与「未提交」标记的数据源。纯解析与编排——文件 IO 与
// git 子进程适配器在 app target(SessionGitStatusReader.swift);本文件只吃 Data
// 与缝协议,单测全合成夹具(SessionGitStatusTests)。

/// 单个工作目录的 git 读数。branch = 分支名或 detached 短 SHA;dirty = 工作区有
/// 未提交改动(含未跟踪文件,拍板③)。非 git 仓库整体为 nil(UI 安静缺位,拍板⑤)。
public struct SessionGitStatus: Equatable, Sendable {
    public let branch: String
    public let dirty: Bool

    public init(branch: String, dirty: Bool) {
        self.branch = branch
        self.dirty = dirty
    }
}

/// HEAD 文件内容 → 分支名:"ref: refs/heads/<名>" 取名(斜杠保留,feat/x 全名);
/// detached(40 位 hex)取前 7 位短 SHA;其余(空 / 畸形)nil,不猜。
public enum GitHeadParser {
    public static func branch(_ data: Data) -> String? {
        guard
            let firstLine = String(data: data, encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: true).first
        else { return nil }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ref: refs/heads/") {
            let name = String(trimmed.dropFirst("ref: refs/heads/".count))
            return name.isEmpty ? nil : name
        }
        return isFullSha(trimmed) ? String(trimmed.prefix(7)) : nil
    }

    private static func isFullSha(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }
}

/// worktree 的 `.git` 文件内容("gitdir: <路径>")→ gitdir 路径;非该形态 nil。
/// worktree 的 HEAD 不在 `<cwd>/.git/HEAD`,要经此重定向一步(采集口径,票面记档)。
public enum GitWorktreeRedirect {
    public static func gitdir(_ data: Data) -> String? {
        guard
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            text.hasPrefix("gitdir: ") else { return nil }
        let path = text.dropFirst("gitdir: ".count)
        return path.isEmpty ? nil : String(path)
    }
}

/// `git status --porcelain` 输出 → 有无未提交改动:任一非空行即脏(修改 / 暂存 /
/// 未跟踪 `??` 全算);空输出 = 干净。nil(跑不动)与空串(真干净)由调用方区分。
public enum GitPorcelain {
    public static func isDirty(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - IO 接缝(Live 实现在 app target;单测注入假实现)

public protocol SessionGitStatusReading: Sendable {
    /// 工作目录当前 HEAD 文件内容:主 checkout = `<cwd>/.git/HEAD`;worktree 经
    /// `.git` 文件重定向(`GitWorktreeRedirect`)解析。非 git 仓库 / 不可读 → nil。
    func gitHeadFile(cwd: String) -> Data?
    /// `/usr/bin/git status --porcelain` 的 stdout;进程失败 / 超时 / 非仓库 → nil。
    func gitStatusOutput(cwd: String) -> Data?
}

// MARK: - 编排

/// git 读数编排:cwd 去重上限 + 单目录读数组合。分支与脏标记独立取——HEAD 读不到
/// = 非仓库(nil);porcelain 跑不动只缺脏标记(不误报未提交,宁缺毋假)。
public enum SessionGitStatusFinder {
    /// 上限护栏:防会话风暴把 git 打成排炮(探针 2026-11-22 实测 30ms/仓,16 仓
    /// 一轮 ≈0.5s 的 utility 任务;超出的 cwd 不出分支 chip)。
    public static let maxWorkingDirs = 16

    /// 会话工作目录全集:去重、保序(Claude 行序在前、ZCode 其后,超出上限丢尾部;
    /// nil 项跳过)。
    public static func workingDirs(claude cwds: [String], zcode roots: [String?]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for dir in cwds + roots.compactMap(\.self) {
            guard seen.insert(dir).inserted else { continue }
            result.append(dir)
            if result.count == maxWorkingDirs {
                break
            }
        }
        return result
    }

    /// 单目录读数:HEAD → 分支;porcelain → 脏。非仓库 nil。
    public static func status(cwd: String, reader: any SessionGitStatusReading) -> SessionGitStatus? {
        guard
            let head = reader.gitHeadFile(cwd: cwd),
            let branch = GitHeadParser.branch(head)
        else { return nil }
        let dirty = reader.gitStatusOutput(cwd: cwd).map(GitPorcelain.isDirty) ?? false
        return SessionGitStatus(branch: branch, dirty: dirty)
    }
}
