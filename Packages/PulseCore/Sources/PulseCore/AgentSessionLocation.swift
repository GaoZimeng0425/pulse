import Foundation

/// 会话所在位置(agent-tab/09,用户实报「会话看不出是哪个项目」):工作目录 →
/// 项目名(worktree 折回主仓,与账本 `AgentWorkspaceResolution` 同规则)+
/// worktree 名 + home 缩写为 `~` 的显示路径。纯路径推导,零 IO。
public struct AgentSessionLocation: Equatable, Sendable {
    public let project: String
    /// `.worktrees/<slug>` 或 `.git/worktrees/<name>` 的那一段;主 checkout 为 nil。
    public let worktree: String?
    public let displayPath: String

    public static func resolve(path: String, home: String) -> AgentSessionLocation? {
        let components = path.split(separator: "/").map(String.init)
        guard let project = AgentWorkspaceResolution.projectName(components: components) else { return nil }
        return AgentSessionLocation(
            project: project,
            worktree: worktreeName(components),
            displayPath: abbreviate(path, home: home)
        )
    }

    private static func worktreeName(_ components: [String]) -> String? {
        if let index = components.firstIndex(of: ".worktrees"), index > 0,
           components.indices.contains(index + 1) {
            return components[index + 1]
        }
        if let git = components.firstIndex(of: ".git"), git > 0,
           components.indices.contains(git + 2), components[git + 1] == "worktrees" {
            return components[git + 2]
        }
        return nil
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else { return path }
        if path == trimmedHome {
            return "~"
        }
        if path.hasPrefix(trimmedHome + "/") {
            return "~" + path.dropFirst(trimmedHome.count)
        }
        return path
    }
}
