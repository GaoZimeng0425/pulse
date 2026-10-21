import Foundation

// MARK: - stableKey 逆映射(工单 03,历史库读回侧)

public extension GroupIdentity {
    /// 由规范字符串(`stableKey`)重建类型化组身份——历史表的 group_id 一律存
    /// stableKey,将来按组的历史视图由此拿回身份,不再拿字符串当 ID。**目前无产品
    /// 调用方**(乙8 注释钉死:预留逆映射,往返一致性由 GroupIdentityKeyTests 钉住)。
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

// MARK: - 改项目根的组身份迁移规则(arch-review-2026-10-18/03 乙3)

/// 项目组身份 = "project:<项目根>[@<worktree>]",根是用户配置的路径——改根即换键,
/// 历史曲线会无声断档(用户拍板 2026-10-19:自动迁移,不文档化断史)。本规则只决定
/// 「哪个旧根的历史迁到哪个新根」;改写在 HistoryEngine.reconcileProjectRoots。
///
/// 只看被删的旧根与新加的新根:两者**相关** = 路径互为前缀(收窄 / 放宽)或末级目录
/// 名相同(整个项目挪了位置)。只有一对一相关才迁;一个旧根对多个新根、或多个旧根
/// 对同一新根都是歧义,保守跳过(只记日志)。无关的增删(换了个项目)不迁也不算歧义。
public enum ProjectRootMigration {
    public struct Move: Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct Plan: Equatable {
        public var moves: [Move] = []
        /// 有相关新根但配不成一对一的旧根(歧义跳过)。
        public var skipped: [String] = []

        public init(moves: [Move] = [], skipped: [String] = []) {
            self.moves = moves
            self.skipped = skipped
        }
    }

    public static func plan(previous: [String], current: [String]) -> Plan {
        let previousRoots = Set(previous.map(PathNormalization.normalize))
        let currentRoots = Set(current.map(PathNormalization.normalize))
        let removed = previousRoots.subtracting(currentRoots).sorted()
        let added = currentRoots.subtracting(previousRoots).sorted()
        var plan = Plan()
        for old in removed {
            let candidates = added.filter { related(old, $0) }
            guard !candidates.isEmpty else { continue }
            if candidates.count == 1, removed.filter({ related($0, candidates[0]) }).count == 1 {
                plan.moves.append(Move(from: old, to: candidates[0]))
            } else {
                plan.skipped.append(old)
            }
        }
        return plan
    }

    private static func related(_ lhs: String, _ rhs: String) -> Bool {
        lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
            || (lhs as NSString).lastPathComponent == (rhs as NSString).lastPathComponent
    }

    /// 组键前缀(不含 worktree 后缀)。
    public static func keyPrefix(ofRoot root: String) -> String {
        GroupIdentity.project(root: root, worktreeName: nil).stableKey
    }
}
