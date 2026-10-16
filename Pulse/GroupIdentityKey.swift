import Foundation

// MARK: - stableKey 逆映射(工单 03,历史库读回侧)

extension GroupIdentity {
    /// 由规范字符串(`stableKey`)重建类型化组身份——历史六表的 group_id
    /// 一律存 stableKey,消费端(历史页/回灌)由此拿回身份,不再拿字符串当 ID。
    ///
    /// 字符串约定本身对含 "@" 的字符串有歧义(P0 前缀约定如此):此处取
    /// **第一个** "@" 拆 worktree——项目根是绝对路径而 worktree 名是短目录名,
    /// 后者含 @ 的形态更常见;根含 @ 属既知限制(与 pid 复用同级)。
    init?(stableKey: String) {
        switch stableKey {
        case "system":
            self = .system
            return
        case "background-service":
            self = .backgroundService
            return
        case "orphan":
            self = .orphan
            return
        default:
            break
        }
        if stableKey.hasPrefix("bundle:") {
            let path = String(stableKey.dropFirst("bundle:".count))
            guard !path.isEmpty else { return nil }
            self = .app(bundlePath: path)
            return
        }
        if stableKey.hasPrefix("project:") {
            let rest = String(stableKey.dropFirst("project:".count))
            guard !rest.isEmpty else { return nil }
            if let atIndex = rest.firstIndex(of: "@") {
                let root = String(rest[..<atIndex])
                let worktree = String(rest[rest.index(after: atIndex)...])
                guard !root.isEmpty, !worktree.isEmpty else { return nil }
                self = .project(root: root, worktreeName: worktree)
            } else {
                self = .project(root: rest, worktreeName: nil)
            }
            return
        }
        return nil
    }
}
